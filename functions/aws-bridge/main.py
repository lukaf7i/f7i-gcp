"""
aws-bridge Cloud Function (dev/test)
-------------------------------------
Invoked via HTTP. Uploads a small payload to S3 and publishes an event to
EventBridge using temporary AWS credentials obtained via Google OIDC — no
static AWS keys required.

Env vars (set by Terraform):
    AWS_ROLE_ARN         – IAM role to assume
    AWS_S3_BUCKET        – bucket name for test upload
    AWS_EVENTBRIDGE_BUS  – EventBridge bus name
    AWS_REGION           – AWS region (default ap-southeast-2)

Test call:
    curl -X POST <FUNCTION_URL> \
         -H 'Content-Type: application/json' \
         -d '{"message": "hello from GCP"}'
"""

import datetime
import json
import base64
import os
import re
import urllib.parse

import boto3
import functions_framework
import requests


# ── OIDC helpers ──────────────────────────────────────────────────────────────

def _get_google_oidc_token(audience: str) -> str:
    """Return a Google OIDC ID token for this runtime SA (Cloud Run / Cloud Functions).

    Uses google-auth's fetch_id_token, which targets the correct issuance path on GCP.
    Register the same **audience** on `aws_iam_openid_connect_provider` client_id_list and
    in the role trust `accounts.google.com:aud` condition.
    """
    from google.auth.transport.requests import Request
    from google.oauth2 import id_token

    return id_token.fetch_id_token(Request(), audience)


def _sts_xml_field(xml: str, tag: str) -> str | None:
    m = re.search(f"<{tag}>([^<]*)</{tag}>", xml)
    return m.group(1) if m else None


def _assume_aws_role(role_arn: str, region: str) -> dict:
    """Exchange the Google OIDC token for temporary AWS credentials via STS Query API."""
    oidc_token = _get_google_oidc_token("sts.amazonaws.com")
    body = urllib.parse.urlencode({
        "Action": "AssumeRoleWithWebIdentity",
        "Version": "2011-06-15",
        "RoleArn": role_arn,
        "RoleSessionName": "gcp-aws-bridge",
        "WebIdentityToken": oidc_token,
        "DurationSeconds": "900",
    })
    r = requests.post(
        "https://sts.amazonaws.com/",
        data=body.encode("utf-8"),
        headers={"Content-Type": "application/x-www-form-urlencoded; charset=utf-8"},
        timeout=60,
    )
    text = r.text
    err_code = _sts_xml_field(text, "Code")
    err_msg = _sts_xml_field(text, "Message")
    if err_code or "<ErrorResponse" in text:
        try:
            p = oidc_token.split(".")[1]
            p += "=" * (-len(p) % 4)
            claims = json.loads(base64.urlsafe_b64decode(p.encode("ascii")))
            aud_info = f" jwt_aud={claims.get('aud')!r}"
        except Exception:
            aud_info = ""
        raise RuntimeError(
            f"STS AssumeRoleWithWebIdentity failed: {err_code}: {err_msg}{aud_info}\n{text[:1200]}"
        )
    ak = _sts_xml_field(text, "AccessKeyId")
    sk = _sts_xml_field(text, "SecretAccessKey")
    st = _sts_xml_field(text, "SessionToken")
    if not (ak and sk and st):
        raise RuntimeError(f"Unexpected STS response (HTTP {r.status_code}):\n{text[:1200]}")
    return {
        "AccessKeyId": ak,
        "SecretAccessKey": sk,
        "SessionToken": st,
    }


def _aws_clients(creds: dict, region: str) -> tuple:
    """Build boto3 S3 + EventBridge clients from temporary credentials."""
    kwargs = dict(
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
        region_name=region,
    )
    return boto3.client("s3", **kwargs), boto3.client("events", **kwargs)


# ── Main handler ──────────────────────────────────────────────────────────────

@functions_framework.http
def handle(request):
    role_arn   = os.environ["AWS_ROLE_ARN"]
    bucket     = os.environ["AWS_S3_BUCKET"]
    bus_name   = os.environ.get("AWS_EVENTBRIDGE_BUS", "default")
    region     = os.environ.get("AWS_REGION", "ap-southeast-2")

    body = request.get_json(silent=True) or {}
    message = body.get("message", "hello from GCP aws-bridge fn")
    now = datetime.datetime.utcnow().isoformat()

    # 1. Get temporary AWS creds via Google OIDC
    creds = _assume_aws_role(role_arn, region)
    s3, events = _aws_clients(creds, region)

    # 2. Upload a small JSON file to S3
    key = f"bridge-test/{now}.json"
    payload = json.dumps({"message": message, "timestamp": now, "source": "gcp-aws-bridge"})
    s3.put_object(Bucket=bucket, Key=key, Body=payload, ContentType="application/json")

    # 3. Publish an event to EventBridge
    #    (S3 will also fire its own notification via the bucket notification config)
    events.put_events(
        Entries=[{
            "Source":       "gcp.aws-bridge",
            "DetailType":   "BridgeTestEvent",
            "Detail":       json.dumps({"s3_key": key, "message": message}),
            "EventBusName": bus_name,
        }]
    )

    result = {
        "status":  "ok",
        "s3_key":  key,
        "bus":     bus_name,
        "message": message,
    }
    return (json.dumps(result), 200, {"Content-Type": "application/json"})
