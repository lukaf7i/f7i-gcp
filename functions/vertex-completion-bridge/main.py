"""vertex-completion-bridge — Vertex CustomJob terminal-state → AWS.

For each terminal-state Vertex CustomJob:

  1. Pull the job ID out of the log entry that fired the Pub/Sub trigger.
  2. Describe the job for authoritative state, output URI, labels, hp.
  3. Read metrics.json the training shim wrote into <output_uri>/model/.
  4. Copy model.tar.gz from GCS into the destination S3 bucket. Path matches
     SageMaker's convention: s3://{bucket}/output/{job_name}/output/model.tar.gz
     so deploy_inference can treat Vertex artifacts identically to SageMaker.
     Destination bucket is selected from the CustomJob's `predict_bucket`
     label when present; otherwise falls back to AWS_MODEL_S3_BUCKET env var
     (the f7i-gcp-owned default bucket used by the test harness).
  5. PutEvents to EventBridge with the clean contract documented at the top
     of this module — single denormalised payload, no AWS API round trips
     needed by the deploy_inference Lambda.

EventBridge event contract (Source=gcp.vertex-ai, DetailType=VertexTrainingJobStateChange):

    {
      "job_name":         "argus-{unsup|semi}-{sensor_id}-{ts8}",
      "resource_name":    "projects/.../customJobs/...",
      "job_id":           "...",
      "state":            "JOB_STATE_SUCCEEDED" | "JOB_STATE_FAILED" | ...,
      "create_time":      ISO 8601,
      "end_time":         ISO 8601,
      "model_artifact":   "s3://{bucket}/output/{job_name}/output/model.tar.gz",
      "training_image":   "...",
      "labels":           {"tenant": "arnotts", "sensor_id": "abc", ...},
      "hyperparameters":  {"sensor-id": "abc", "seq-len": "25", ...},
      "metrics": {
        "lstm_vae:best_loss":     ...,
        "lstm_vae:threshold":     ...,
        "lstm_vae:alert_pct":     ...,
        "lstm_vae:mah_mean":      ...,
        "lstm_vae:mah_std":       ...,
        "lstm_vae:mah_threshold": ...
      },
      "config":            { full hyperparams the shim captured from config.json },
      "mahalanobis_stats": { mu_r, sigma_inv, mah_threshold, val_scores_sorted },
      "error":             null | "..."
    }
"""

from __future__ import annotations

import base64
import json
import logging
import os
from typing import Any, Dict, Optional, Tuple
from urllib.parse import urlparse

import boto3
import functions_framework
import google.auth.transport.requests
from google.auth import compute_engine
from google.cloud import aiplatform_v1, storage


logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)


_TERMINAL_STATES = {
    "JOB_STATE_SUCCEEDED",
    "JOB_STATE_FAILED",
    "JOB_STATE_CANCELLED",
    "JOB_STATE_EXPIRED",
}

# Metric keys the training shim emits → keys the f7i-cdk deploy_inference
# handler expects (SageMaker MetricDefinitions-style colon-prefixed names).
_METRIC_KEY_REMAP = {
    "best_loss":     "lstm_vae:best_loss",
    "threshold":     "lstm_vae:threshold",
    "alert_pct":     "lstm_vae:alert_pct",
    "mah_mean":      "lstm_vae:mah_mean",
    "mah_std":       "lstm_vae:mah_std",
    "mah_threshold": "lstm_vae:mah_threshold",
    "f1":            "lstm_vae:f1",
    "f1_pa":         "lstm_vae:f1_pa",
    "precision":     "lstm_vae:precision",
    "recall":        "lstm_vae:recall",
}


# ── AWS auth (OIDC → STS → boto3 Session) ─────────────────────────────────────

def _mint_google_oidc_token(audience: str) -> str:
    request = google.auth.transport.requests.Request()
    credentials = compute_engine.IDTokenCredentials(
        request,
        target_audience=audience,
        use_metadata_identity_endpoint=True,
    )
    credentials.refresh(request)
    return credentials.token


def _aws_session() -> boto3.Session:
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
    return boto3.Session(
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
        region_name=region,
    )


# ── GCS helpers ───────────────────────────────────────────────────────────────

def _parse_gs_uri(uri: str) -> Tuple[str, str]:
    parsed = urlparse(uri)
    if parsed.scheme != "gs":
        raise ValueError(f"Expected gs:// URI, got {uri!r}")
    return parsed.netloc, parsed.path.lstrip("/")


def _read_metrics(gcs: storage.Client, model_dir_uri: str) -> Optional[dict]:
    bucket_name, prefix = _parse_gs_uri(model_dir_uri.rstrip("/"))
    blob = gcs.bucket(bucket_name).blob(f"{prefix}/metrics.json")
    if not blob.exists():
        log.info("No metrics.json at %s/metrics.json", model_dir_uri)
        return None
    return json.loads(blob.download_as_text())


def _copy_model_to_s3(
    gcs: storage.Client,
    s3_client,
    model_dir_uri: str,
    bucket: str,
    s3_key: str,
) -> Optional[str]:
    bucket_name, gcs_prefix = _parse_gs_uri(model_dir_uri.rstrip("/"))
    blob = gcs.bucket(bucket_name).blob(f"{gcs_prefix}/model.tar.gz")
    if not blob.exists():
        log.info("No model.tar.gz at %s/model.tar.gz", model_dir_uri)
        return None
    log.info("Streaming gs://%s/%s/model.tar.gz → s3://%s/%s",
             bucket_name, gcs_prefix, bucket, s3_key)
    data = blob.download_as_bytes()
    s3_client.put_object(Bucket=bucket, Key=s3_key, Body=data,
                         ContentType="application/gzip")
    return f"s3://{bucket}/{s3_key}"


# ── Metric/config shaping ─────────────────────────────────────────────────────

def _shape_metrics(raw_metrics: Optional[dict]) -> dict:
    """Take the shim's metrics.json output and produce SageMaker-shaped keys."""
    if not raw_metrics:
        return {}

    out: Dict[str, Any] = {}
    for src_key, dst_key in _METRIC_KEY_REMAP.items():
        if src_key in raw_metrics:
            out[dst_key] = raw_metrics[src_key]
    return out


def _extract_config(raw_metrics: Optional[dict]) -> Optional[dict]:
    return (raw_metrics or {}).get("config")


def _extract_mahalanobis(raw_metrics: Optional[dict]) -> Optional[dict]:
    return (raw_metrics or {}).get("mahalanobis_stats")


# ── Vertex job lookup ─────────────────────────────────────────────────────────

def _extract_job_id(log_entry: dict) -> Optional[str]:
    labels = (log_entry.get("resource") or {}).get("labels") or {}
    job_id = labels.get("job_id") or labels.get("resource_id")
    if job_id:
        return str(job_id)
    resource_name = (log_entry.get("protoPayload") or {}).get("resourceName") or ""
    if "/customJobs/" in resource_name:
        return resource_name.rsplit("/customJobs/", 1)[1].split("/")[0]
    return None


def _describe_job(project: str, location: str, job_id: str):
    client = aiplatform_v1.JobServiceClient(
        client_options={"api_endpoint": f"{location}-aiplatform.googleapis.com"}
    )
    return client.get_custom_job(
        name=f"projects/{project}/locations/{location}/customJobs/{job_id}"
    )


# ── Handler ───────────────────────────────────────────────────────────────────

@functions_framework.cloud_event
def handle(cloud_event):
    raw = cloud_event.data["message"]["data"]
    decoded = base64.b64decode(raw).decode("utf-8")
    try:
        log_entry = json.loads(decoded)
    except json.JSONDecodeError:
        log.warning("Pub/Sub payload was not JSON: %r", decoded[:200])
        return

    project       = os.environ["GCP_PROJECT_ID"]
    location      = os.environ.get("VERTEX_LOCATION", "australia-southeast1")
    default_s3_bucket = os.environ.get("AWS_MODEL_S3_BUCKET")

    job_id = _extract_job_id(log_entry)
    if not job_id:
        log.info("No job_id in log entry — ignoring")
        return

    try:
        job = _describe_job(project, location, job_id)
    except Exception as exc:
        log.error("Failed to describe job %s: %s", job_id, exc)
        return

    state = aiplatform_v1.JobState(job.state).name
    if state not in _TERMINAL_STATES:
        log.info("Job %s state=%s is non-terminal — ignoring", job_id, state)
        return

    end_time    = job.end_time.isoformat()    if job.end_time    else None
    create_time = job.create_time.isoformat() if job.create_time else None
    output_uri  = (
        job.job_spec.base_output_directory.output_uri_prefix
        if job.job_spec and job.job_spec.base_output_directory
        else None
    )
    error_message = job.error.message if job.error and job.error.message else None

    # Labels carry the per-tenant routing info: predict_bucket, sensor_id, etc.
    job_labels = dict(job.labels or {})

    # Hyperparameters and training image — extracted for the event payload.
    container_spec = (
        job.job_spec.worker_pool_specs[0].container_spec
        if job.job_spec and job.job_spec.worker_pool_specs
        else None
    )
    training_image = container_spec.image_uri if container_spec else None
    hp_args = list(container_spec.args) if container_spec else []
    hyperparameters = _parse_hp_args(hp_args)

    # Vertex writes job outputs to <base_output_dir>/model/ via the shim.
    model_dir_uri = f"{output_uri.rstrip('/')}/model" if output_uri else None

    metrics_shaped: Dict[str, Any] = {}
    config: Optional[dict] = None
    mah_stats: Optional[dict] = None
    model_artifact_s3: Optional[str] = None

    if state == "JOB_STATE_SUCCEEDED" and model_dir_uri:
        gcs = storage.Client(project=project)
        try:
            raw_metrics = _read_metrics(gcs, model_dir_uri)
            metrics_shaped = _shape_metrics(raw_metrics)
            config        = _extract_config(raw_metrics)
            mah_stats     = _extract_mahalanobis(raw_metrics)
        except Exception as exc:
            log.error("Failed to read metrics: %s", exc)

        # Destination: label > env default. SageMaker convention path.
        target_bucket = job_labels.get("predict_bucket") or default_s3_bucket
        if target_bucket:
            s3_key = f"output/{job.display_name}/output/model.tar.gz"
            try:
                s3 = _aws_session().client("s3")
                model_artifact_s3 = _copy_model_to_s3(
                    gcs, s3, model_dir_uri, target_bucket, s3_key,
                )
            except Exception as exc:
                log.error("Failed to copy model to S3: %s", exc)
        else:
            log.warning("No predict_bucket label and no default — skipping S3 copy")

    event_detail = {
        "job_name":          job.display_name,
        "resource_name":     job.name,
        "job_id":            job_id,
        "state":             state,
        "create_time":       create_time,
        "end_time":          end_time,
        "model_artifact":    model_artifact_s3,
        "training_image":    training_image,
        "labels":            job_labels,
        "hyperparameters":   hyperparameters,
        "metrics":           metrics_shaped,
        "config":            config,
        "mahalanobis_stats": mah_stats,
        "error":             error_message,
    }

    log.info("Forwarding to EventBridge: state=%s job=%s artifact=%s",
             state, job.display_name, model_artifact_s3)

    events = _aws_session().client("events")
    resp = events.put_events(Entries=[{
        "Source":       "gcp.vertex-ai",
        "DetailType":   "VertexTrainingJobStateChange",
        "Detail":       json.dumps(event_detail, default=str),
        "EventBusName": os.environ["AWS_EVENTBRIDGE_BUS"],
    }])

    if resp.get("FailedEntryCount", 0) > 0:
        log.error("EventBridge rejected: %s", resp)
    else:
        log.info("EventBridge accepted (event_id=%s)", resp["Entries"][0].get("EventId"))


# ── helpers ───────────────────────────────────────────────────────────────────

def _parse_hp_args(args: list) -> Dict[str, str]:
    """Turn the container args list (['--key', 'value', ...]) back into a dict."""
    out: Dict[str, str] = {}
    i = 0
    while i < len(args) - 1:
        a = args[i]
        if isinstance(a, str) and a.startswith("--"):
            out[a.lstrip("-")] = args[i + 1]
            i += 2
        else:
            i += 1
    return out
