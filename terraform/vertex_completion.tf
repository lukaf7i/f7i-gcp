# vertex-completion-bridge — Vertex CustomJob → AWS EventBridge
# ---------------------------------------------------------------------------
# Cloud Logging sink filters terminal CustomJob state changes, routes them
# to a Pub/Sub topic that triggers the bridge Cloud Function. The function
# describes the job via Vertex API for authoritative state, mints a Google
# OIDC token, exchanges it for STS creds via the existing accounts.google.com
# IAM OIDC provider, and PutEvents to the shared f7i-gcp-bridge-${env} bus.
#
# AWS-side: a dedicated role (gcp-vertex-completion-${env}) gates events:PutEvents
# on the bus to this one bridge SA via accounts.google.com:aud (azp) match.

# ── GCP: Pub/Sub topic for completion events ─────────────────────────────────

resource "google_pubsub_topic" "vertex_job_completions" {
  project = var.project_id
  name    = "vertex-job-completions-${var.environment}"
  labels  = local.common_labels
}

# ── GCP: Cloud Logging sink — terminal state changes only ────────────────────
# The function calls Vertex API for authoritative state regardless, but the
# log filter narrows the firehose so we don't invoke per running-job log line.

resource "google_logging_project_sink" "vertex_job_completions" {
  project     = var.project_id
  name        = "vertex-job-completions-${var.environment}"
  destination = "pubsub.googleapis.com/${google_pubsub_topic.vertex_job_completions.id}"

  filter = <<-EOT
    resource.type="aiplatform.googleapis.com/CustomJob"
    (jsonPayload.state="JOB_STATE_SUCCEEDED" OR
     jsonPayload.state="JOB_STATE_FAILED" OR
     jsonPayload.state="JOB_STATE_CANCELLED" OR
     jsonPayload.state="JOB_STATE_EXPIRED")
  EOT

  unique_writer_identity = true
}

resource "google_pubsub_topic_iam_member" "vertex_completions_sink_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.vertex_job_completions.id
  role    = "roles/pubsub.publisher"
  member  = google_logging_project_sink.vertex_job_completions.writer_identity
}

# ── GCP: Service account for the bridge function ─────────────────────────────

resource "google_service_account" "vertex_completion_fn" {
  project      = var.project_id
  account_id   = "vertex-completion-fn-${var.environment}"
  display_name = "Vertex Completion Bridge (${var.environment})"
  description  = "Forwards Vertex CustomJob state-change events to AWS EventBridge."
}

# Needed so the function can call get_custom_job for authoritative state.
resource "google_project_iam_member" "vertex_completion_aiplatform_viewer" {
  project = var.project_id
  role    = "roles/aiplatform.viewer"
  member  = "serviceAccount:${google_service_account.vertex_completion_fn.email}"
}

# Self-token-creator: needed for compute_engine.IDTokenCredentials to mint
# OIDC tokens via the metadata endpoint (same as the aws-bridge function).
resource "google_service_account_iam_member" "vertex_completion_token_creator" {
  service_account_id = google_service_account.vertex_completion_fn.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.vertex_completion_fn.email}"
}

# Required for the runtime SA to receive Eventarc-delivered Pub/Sub triggers.
resource "google_project_iam_member" "vertex_completion_eventarc_receiver" {
  project = var.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_service_account.vertex_completion_fn.email}"
}

# ── GCP: Cloud Function (Gen 2, Pub/Sub triggered) ───────────────────────────

data "archive_file" "vertex_completion_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../functions/vertex-completion-bridge"
  output_path = "/tmp/vertex-completion-bridge.zip"
}

resource "google_storage_bucket_object" "vertex_completion_source" {
  name   = "vertex-completion-bridge/${filemd5("${path.module}/../functions/vertex-completion-bridge/main.py")}.zip"
  bucket = google_storage_bucket.fn_source.name
  source = data.archive_file.vertex_completion_zip.output_path
}

resource "google_cloudfunctions2_function" "vertex_completion_bridge" {
  project     = var.project_id
  name        = "vertex-completion-bridge-${var.environment}"
  location    = var.region
  description = "Forwards Vertex CustomJob state-change events to AWS EventBridge."
  labels      = local.common_labels

  build_config {
    runtime     = "python312"
    entry_point = "handle"
    source {
      storage_source {
        bucket = google_storage_bucket.fn_source.name
        object = google_storage_bucket_object.vertex_completion_source.name
      }
    }
  }

  service_config {
    service_account_email          = google_service_account.vertex_completion_fn.email
    max_instance_count             = 5
    min_instance_count             = 0
    available_memory               = "256M"
    timeout_seconds                = 60
    all_traffic_on_latest_revision = true

    environment_variables = {
      GCP_PROJECT_ID      = var.project_id
      VERTEX_LOCATION     = var.region
      AWS_ROLE_ARN        = aws_iam_role.gcp_vertex_completion.arn
      AWS_REGION          = var.aws_region
      AWS_EVENTBRIDGE_BUS = aws_cloudwatch_event_bus.bridge.name
    }
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.vertex_job_completions.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }

  depends_on = [google_project_service.core_apis]
}

# ── AWS: dedicated IAM role for this bridge ──────────────────────────────────
# Parallel to gcp-aws-bridge-${env} — separate principal, narrower policy.

data "aws_iam_policy_document" "gcp_vertex_completion_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.google.arn]
    }

    # AWS STS substitutes the JWT `azp` claim for `aud` when Google tokens
    # carry both — same trick as gcp_aws_bridge. The condition value is the
    # bridge function's SA numeric unique ID.
    condition {
      test     = "StringEquals"
      variable = "accounts.google.com:aud"
      values   = [var.gcp_vertex_completion_sa_id]
    }
  }
}

resource "aws_iam_role" "gcp_vertex_completion" {
  name        = "gcp-vertex-completion-${var.environment}"
  description = "Assumed by GCP SA vertex-completion-fn-${var.environment} via Google OIDC."

  assume_role_policy = data.aws_iam_policy_document.gcp_vertex_completion_assume.json
}

resource "aws_iam_role_policy" "gcp_vertex_completion" {
  name = "gcp-vertex-completion-permissions"
  role = aws_iam_role.gcp_vertex_completion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "EventBridgePublish"
      Effect   = "Allow"
      Action   = ["events:PutEvents"]
      Resource = aws_cloudwatch_event_bus.bridge.arn
    }]
  })
}

# ── AWS: EventBridge rule + CloudWatch Log target ────────────────────────────
# Prototype target: just log to CloudWatch so we can confirm events arrive.
# Replace the target with the real handler (deploy-inference Lambda etc.)
# once we have one for the Vertex side.

resource "aws_cloudwatch_event_rule" "vertex_completions" {
  name           = "vertex-training-completions-${var.environment}"
  description    = "Catches VertexTrainingJobStateChange events from the GCP bridge."
  event_bus_name = aws_cloudwatch_event_bus.bridge.name

  event_pattern = jsonencode({
    source        = ["gcp.vertex-ai"]
    "detail-type" = ["VertexTrainingJobStateChange"]
  })
}

resource "aws_cloudwatch_log_group" "vertex_completions" {
  name              = "/aws/events/vertex-completions-${var.environment}"
  retention_in_days = 14
}

resource "aws_cloudwatch_event_target" "vertex_completions_log" {
  rule           = aws_cloudwatch_event_rule.vertex_completions.name
  event_bus_name = aws_cloudwatch_event_bus.bridge.name
  arn            = aws_cloudwatch_log_group.vertex_completions.arn
}

# EventBridge writes to CloudWatch Logs via a resource policy on the log group
# (not via a role) — register one allowing the events service principal.
resource "aws_cloudwatch_log_resource_policy" "vertex_completions" {
  policy_name = "EventBridgeToCloudWatchLogs-vertex-completions-${var.environment}"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = "${aws_cloudwatch_log_group.vertex_completions.arn}:*"
    }]
  })
}
