#!/usr/bin/env bash
# End-to-end integration test: vertex-trainer Lambda → Vertex CustomJob →
# completion bridge → S3 model.tar.gz + EventBridge VertexTrainingJobStateChange.
#
# Prerequisites:
#   - AWS credentials in repo-root .env (or exported)
#   - vertex-trainer-dev + completion bridge deployed (f7i-gcp terraform apply)
#
# Usage:
#   ./f7i-gcp/scripts/test_vertex_integration.sh
#   ./f7i-gcp/scripts/test_vertex_integration.sh --skip-invoke   # only poll last job

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ROOT}/.env"
REGION="${AWS_REGION:-ap-southeast-2}"
LAMBDA_NAME="${VERTEX_TRAINER_LAMBDA:-vertex-trainer-dev}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
MAX_WAIT_SEC="${MAX_WAIT_SEC:-1800}"
SKIP_INVOKE=false

for arg in "$@"; do
  case "$arg" in
    --skip-invoke) SKIP_INVOKE=true ;;
  esac
done

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a && source "$ENV_FILE" && set +a
fi

die() { echo "ERROR: $*" >&2; exit 1; }

command -v aws >/dev/null || die "aws CLI required"
command -v jq >/dev/null || die "jq required"

echo "=== AWS identity ==="
aws sts get-caller-identity --region "$REGION"

echo ""
echo "=== Vertex SSM contract (/f7i/vertex/*) ==="
SSM_JSON=$(aws ssm get-parameters-by-path \
  --path /f7i/vertex/ \
  --recursive \
  --with-decryption \
  --region "$REGION" \
  --output json)
echo "$SSM_JSON" | jq -r '.Parameters[] | "\(.Name)=\(.Value)"' | grep -v wif_config_json || true

STAGING_BUCKET=$(echo "$SSM_JSON" | jq -r '.Parameters[] | select(.Name=="/f7i/vertex/staging_bucket") | .Value')
EB_BUS=$(echo "$SSM_JSON" | jq -r '.Parameters[] | select(.Name=="/f7i/vertex/eventbridge_bus_name") | .Value')
PROJECT_ID=$(echo "$SSM_JSON" | jq -r '.Parameters[] | select(.Name=="/f7i/vertex/project_id") | .Value')
VERTEX_LOCATION=$(echo "$SSM_JSON" | jq -r '.Parameters[] | select(.Name=="/f7i/vertex/location") | .Value')

[[ -n "$STAGING_BUCKET" && "$STAGING_BUCKET" != "null" ]] || die "missing /f7i/vertex/staging_bucket"
# MODEL_BUCKET is the per-tenant predict bucket the bridge copies model.tar.gz
# into. The dev cdk creates one (e.g. dev-f7i-anomalies-models); the test
# stamps it as the job's predict_bucket label so the bridge picks it up.
[[ -n "${MODEL_BUCKET:-}" ]] || die "MODEL_BUCKET env var required (e.g. MODEL_BUCKET=dev-f7i-anomalies-models)"

OUT_FILE="/tmp/vertex-trainer-invoke.json"
JOB_NAME=""
VERTEX_JOB=""

if [[ "$SKIP_INVOKE" != "true" ]]; then
  SENSOR_ID="integration-test-$(date +%s)"
  PAYLOAD=$(jq -n \
    --arg sid "$SENSOR_ID" \
    --arg bucket "$MODEL_BUCKET" \
    '{sensor_id: $sid, n_rows: 250, hyperparameters: {epochs: "5", patience: "3"}, predict_bucket: $bucket, tenant: "integration-test"}')

  echo ""
  echo "=== Invoking $LAMBDA_NAME (sensor_id=$SENSOR_ID) ==="
  aws lambda invoke \
    --function-name "$LAMBDA_NAME" \
    --region "$REGION" \
    --payload "$PAYLOAD" \
    --cli-binary-format raw-in-base64-out \
    "$OUT_FILE" >/tmp/vertex-trainer-invoke-meta.json

  cat /tmp/vertex-trainer-invoke-meta.json | jq .
  cat "$OUT_FILE" | jq .

  STATUS=$(jq -r '.status // empty' "$OUT_FILE")
  [[ "$STATUS" == "submitted" ]] || die "Lambda did not return status=submitted"

  JOB_NAME=$(jq -r '.job_name' "$OUT_FILE")
  VERTEX_JOB=$(jq -r '.vertex_job' "$OUT_FILE")
  echo "Submitted: job_name=$JOB_NAME"
  echo "Vertex resource: $VERTEX_JOB"
else
  echo ""
  echo "=== --skip-invoke: enter job_name to poll ==="
  read -r -p "job_name (e.g. vertex-trainer-proto-sensor-12345678): " JOB_NAME
  [[ -n "$JOB_NAME" ]] || die "job_name required"
fi

S3_KEY="output/${JOB_NAME}/output/model.tar.gz"
echo ""
echo "=== Polling S3 for model artifact (max ${MAX_WAIT_SEC}s) ==="
echo "    s3://${MODEL_BUCKET}/${S3_KEY}"

elapsed=0
while (( elapsed < MAX_WAIT_SEC )); do
  if aws s3api head-object --bucket "$MODEL_BUCKET" --key "$S3_KEY" --region "$REGION" 2>/dev/null; then
    echo "OK: model.tar.gz present in S3"
    aws s3api head-object --bucket "$MODEL_BUCKET" --key "$S3_KEY" --region "$REGION" \
      --query '{Size:ContentLength,LastModified:LastModified}' --output json | jq .
    break
  fi
  echo "  … not yet (${elapsed}s)"
  sleep "$POLL_INTERVAL"
  elapsed=$((elapsed + POLL_INTERVAL))
done

if (( elapsed >= MAX_WAIT_SEC )); then
  die "Timed out waiting for s3://${MODEL_BUCKET}/${S3_KEY}"
fi

echo ""
echo "=== Printer Lambda logs (last 15 min) ==="
PRINTER_LOG="/aws/lambda/vertex-completion-printer-dev"
START_MS=$(($(date +%s) * 1000 - 15 * 60 * 1000))
aws logs filter-log-events \
  --log-group-name "$PRINTER_LOG" \
  --start-time "$START_MS" \
  --region "$REGION" \
  --filter-pattern "$JOB_NAME" \
  --max-items 5 \
  --output json 2>/dev/null | jq -r '.events[]?.message // empty' || \
  echo "(no matching printer logs — check $PRINTER_LOG manually)"

echo ""
echo "=== Integration test PASSED ==="
echo "  Vertex job:     ${VERTEX_JOB:-n/a}"
echo "  Model artifact: s3://${MODEL_BUCKET}/${S3_KEY}"
echo "  EventBridge bus: ${EB_BUS:-n/a}"
echo "  GCS staging:    gs://${STAGING_BUCKET}/output/${JOB_NAME}/"
