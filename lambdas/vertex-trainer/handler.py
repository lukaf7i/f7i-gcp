"""vertex-trainer Lambda — prototype.

Generates a tiny mock CSV, uploads it to GCS, and submits a Vertex AI
CustomJob that just echoes the channel env vars. Proves the end-to-end
AWS → GCP wiring (Workload Identity Federation, GCS write, Vertex submit)
without depending on any real training image or AWS data sources.
"""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Any, Dict


# ── GCP Workload Identity Federation bootstrap ────────────────────────────────
_WIF_PATH = "/tmp/gcp_wif_config.json"
if "GCP_WIF_CONFIG_JSON" in os.environ and not os.path.exists(_WIF_PATH):
    with open(_WIF_PATH, "w") as _f:
        _f.write(os.environ["GCP_WIF_CONFIG_JSON"])
    os.environ.setdefault("GOOGLE_APPLICATION_CREDENTIALS", _WIF_PATH)

from google.cloud import aiplatform, storage  # noqa: E402


logging.getLogger().setLevel(logging.INFO)
log = logging.getLogger(__name__)


_MOCK_CSV = (
    "timestamp,temperature,velocity_total_crest,velocity_x_rms,velocity_y_rms,velocity_z_rms\n"
    + "\n".join(
        f"2026-01-01T00:{m:02d}:00Z,{20 + m * 0.1:.2f},1.5,0.3,0.4,0.5"
        for m in range(60)
    )
    + "\n"
)


def handler(event: Dict[str, Any], _context: Any) -> Dict[str, Any]:
    log.info("Received event: %s", json.dumps(event))

    project        = os.environ["GCP_PROJECT_ID"]
    location       = os.environ["VERTEX_LOCATION"]
    staging_bucket = os.environ["GCS_STAGING_BUCKET"]
    service_account = os.environ["VERTEX_TRAINER_SA"]
    image_uri      = os.environ["VERTEX_TRAINER_IMAGE"]
    machine_type   = os.environ.get("VERTEX_MACHINE_TYPE", "n1-standard-4")

    run_id  = str(int(time.time()))
    csv_key = f"mock/mock_data_{run_id}.csv"

    # ── 1. Upload mock CSV to GCS ─────────────────────────────────────────────
    storage.Client(project=project).bucket(staging_bucket).blob(csv_key).upload_from_string(
        _MOCK_CSV, content_type="text/csv",
    )
    csv_uri = f"gs://{staging_bucket}/{csv_key}"
    log.info("Uploaded mock dataset to %s", csv_uri)

    # ── 2. Submit Vertex AI CustomJob ─────────────────────────────────────────
    aiplatform.init(
        project=project,
        location=location,
        staging_bucket=f"gs://{staging_bucket}",
    )

    job_name = f"vertex-trainer-proto-{run_id}"
    base_output = f"gs://{staging_bucket}/output/{job_name}/"

    job = aiplatform.CustomJob(
        display_name=job_name,
        worker_pool_specs=[{
            "machine_spec":  {"machine_type": machine_type},
            "replica_count": 1,
            "container_spec": {
                "image_uri": image_uri,
                "command":   ["python", "-c"],
                "args": [
                    "import os; "
                    "print('vertex-trainer proto running'); "
                    "print('INPUT_TRAIN_URI =', os.environ.get('INPUT_TRAIN_URI')); "
                    "print('AIP_MODEL_DIR =',   os.environ.get('AIP_MODEL_DIR'))"
                ],
                "env": [
                    {"name": "INPUT_TRAIN_URI", "value": csv_uri},
                ],
            },
        }],
        base_output_dir=base_output,
        staging_bucket=f"gs://{staging_bucket}",
    )
    job.submit(service_account=service_account)
    log.info("Submitted Vertex CustomJob %s (resource=%s)", job_name, job.resource_name)

    return {
        "status":     "submitted",
        "job_name":   job_name,
        "vertex_job": job.resource_name,
        "csv_uri":    csv_uri,
        "output_uri": base_output,
    }
