"""vertex-completion-bridge — Vertex AI CustomJob state-change → AWS EventBridge.

Triggered by Pub/Sub messages from a Cloud Logging sink that filters Vertex
CustomJob state-change log entries. For each event:

  1. Pull the job ID out of the log entry.
  2. Describe the job via Vertex AI (authoritative state, end_time, output).
  3. If state is terminal (SUCCEEDED / FAILED / CANCELLED), mint a Google OIDC
     token, exchange it for temp AWS credentials, and publish an event to
     EventBridge with the same payload shape AWS expects from SageMaker's
     "Training Job State Change" — so the downstream consumer is symmetrical.

Env vars (set by Terraform):
    GCP_PROJECT_ID        – project the function runs in
    VERTEX_LOCATION       – region the Vertex jobs run in
    AWS_ROLE_ARN          – IAM role to assume
    AWS_REGION            – AWS region for EventBridge
    AWS_EVENTBRIDGE_BUS   – EventBridge bus name
"""

from __future__ import annotations

import base64
import json
import logging
import os
from typing import Optional

import boto3
import functions_framework
import google.auth.transport.requests
from google.auth import compute_engine
from google.cloud import aiplatform_v1


logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)


_TERMINAL_STATES = {
    "JOB_STATE_SUCCEEDED",
    "JOB_STATE_FAILED",
    "JOB_STATE_CANCELLED",
    "JOB_STATE_EXPIRED",
}


# ── AWS auth ──────────────────────────────────────────────────────────────────

def _mint_google_oidc_token(audience: str) -> str:
    """Mint a Google ID token via the GCP metadata identity endpoint."""
    request = google.auth.transport.requests.Request()
    credentials = compute_engine.IDTokenCredentials(
        request,
        target_audience=audience,
        use_metadata_identity_endpoint=True,
    )
    credentials.refresh(request)
    return credentials.token


def _aws_eventbridge_client():
    """Return an EventBridge client backed by STS AssumeRoleWithWebIdentity creds."""
    role_arn = os.environ["AWS_ROLE_ARN"]
    region = os.environ.get("AWS_REGION", "ap-southeast-2")

    token = _mint_google_oidc_token("https://sts.amazonaws.com")
    sts = boto3.client("sts", region_name=region)
    resp = sts.assume_role_with_web_identity(
        RoleArn=role_arn,
        RoleSessionName="vertex-completion-bridge",
        WebIdentityToken=token,
        DurationSeconds=3600,
    )
    creds = resp["Credentials"]
    session = boto3.Session(
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
        region_name=region,
    )
    return session.client("events")


# ── Vertex job lookup ─────────────────────────────────────────────────────────

def _extract_job_id(log_entry: dict) -> Optional[str]:
    """Pull the CustomJob numeric ID out of a Cloud Logging entry, however it's shaped."""
    labels = (log_entry.get("resource") or {}).get("labels") or {}
    job_id = labels.get("job_id") or labels.get("resource_id")
    if job_id:
        return str(job_id)

    # Fall back to protoPayload.resourceName (audit-log shape).
    resource_name = (log_entry.get("protoPayload") or {}).get("resourceName") or ""
    if "/customJobs/" in resource_name:
        return resource_name.rsplit("/customJobs/", 1)[1].split("/")[0]
    return None


def _describe_job(project: str, location: str, job_id: str):
    """Call Vertex AI's JobService to get the authoritative job state."""
    client = aiplatform_v1.JobServiceClient(
        client_options={"api_endpoint": f"{location}-aiplatform.googleapis.com"}
    )
    name = f"projects/{project}/locations/{location}/customJobs/{job_id}"
    return client.get_custom_job(name=name)


# ── Handler ───────────────────────────────────────────────────────────────────

@functions_framework.cloud_event
def handle(cloud_event):
    """Cloud Function entry point — receives one Pub/Sub message per fire."""
    # Pub/Sub messages arrive as CloudEvents with base64-encoded data.
    raw = cloud_event.data["message"]["data"]
    decoded = base64.b64decode(raw).decode("utf-8")
    try:
        log_entry = json.loads(decoded)
    except json.JSONDecodeError:
        log.warning("Pub/Sub payload was not JSON: %r", decoded[:200])
        return

    project = os.environ["GCP_PROJECT_ID"]
    location = os.environ.get("VERTEX_LOCATION", "australia-southeast1")

    job_id = _extract_job_id(log_entry)
    if not job_id:
        log.info("No job_id in log entry — ignoring")
        return

    # Always describe via API — single source of truth for state.
    try:
        job = _describe_job(project, location, job_id)
    except Exception as exc:
        log.error("Failed to describe job %s: %s", job_id, exc)
        return

    state = aiplatform_v1.JobState(job.state).name
    if state not in _TERMINAL_STATES:
        log.info("Job %s state=%s is non-terminal — ignoring", job_id, state)
        return

    end_time = job.end_time.isoformat() if job.end_time else None
    create_time = job.create_time.isoformat() if job.create_time else None
    output_uri = (
        job.job_spec.base_output_directory.output_uri_prefix
        if job.job_spec and job.job_spec.base_output_directory
        else None
    )
    error_message = job.error.message if job.error and job.error.message else None

    event_detail = {
        "job_name":      job.display_name,
        "resource_name": job.name,
        "job_id":        job_id,
        "state":         state,
        "create_time":   create_time,
        "end_time":      end_time,
        "output_uri":    output_uri,
        "error":         error_message,
    }

    log.info("Forwarding to EventBridge: %s", json.dumps(event_detail))

    events = _aws_eventbridge_client()
    resp = events.put_events(Entries=[{
        "Source":       "gcp.vertex-ai",
        "DetailType":   "VertexTrainingJobStateChange",
        "Detail":       json.dumps(event_detail),
        "EventBusName": os.environ["AWS_EVENTBRIDGE_BUS"],
    }])

    if resp.get("FailedEntryCount", 0) > 0:
        log.error("EventBridge rejected: %s", resp)
    else:
        log.info("EventBridge accepted (event_id=%s)", resp["Entries"][0].get("EventId"))
