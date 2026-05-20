# Cross-region bridge resources for cohort2's us-east-1 tenant (certarus).
# ---------------------------------------------------------------------------
# Most cohort2 tenants (shared, casinofoodco, stanmore) deploy in ap-southeast-2
# and use the standard f7i-gcp-bridge-prod bus + /f7i/vertex/* SSM params that
# the rest of the codebase manages. certarus is the outlier: its CDK predict
# stack deploys in us-east-1 because its DynamoDB / Timestream data live there.
#
# At CDK synth time the certarus stack calls
#   aws_ssm.StringParameter.value_for_string_parameter(self, "/f7i/vertex/*")
# in the deploy region (us-east-1), so without a mirror those params don't
# resolve and the CFN deploy errors out:
#   "Unable to fetch parameters [/f7i/vertex/code_uri, …] from parameter store
#    for this account."
#
# This file (gated on var.cohort == "cohort2") adds two things:
#   1. A mirror of the EventBridge bus + /f7i/vertex/* SSM params in us-east-1
#      so certarus's CDK deploy resolves them and the bus its rule subscribes
#      to actually exists.
#   2. A rule on the ap-southeast-2 bus that filters events with
#      labels.tenant=certarus and forwards them to the us-east-1 bus.
#      EventBridge handles the cross-region PutEvents natively; the Cloud
#      Function still only publishes once to ap-southeast-2.
#
# The other three cohorts (0, 1, 3) get count=0 on every resource here, so
# this file is a no-op for them and for dev.

locals {
  is_cohort2 = var.cohort == "cohort2"
}

# ── us-east-1: EventBridge bus ────────────────────────────────────────────────

resource "aws_cloudwatch_event_bus" "bridge_use1" {
  count    = local.is_cohort2 ? 1 : 0
  provider = aws.us_east_1
  name     = "f7i-gcp-bridge-${var.environment}"

  tags = {
    Purpose = "cross-region-mirror-for-certarus"
  }
}

# ── us-east-1: SSM mirror of /f7i/vertex/* ────────────────────────────────────
# Same values as ap-southeast-2 except eventbridge_bus_{name,arn} which point
# at the us-east-1 bus above (so certarus's CDK creates its rule on that bus).

resource "aws_ssm_parameter" "vertex_project_id_use1" {
  count       = local.is_cohort2 ? 1 : 0
  provider    = aws.us_east_1
  name        = "/f7i/vertex/project_id"
  description = "GCP project hosting Vertex AI. us-east-1 mirror for certarus."
  type        = "String"
  value       = var.project_id
}

resource "aws_ssm_parameter" "vertex_location_use1" {
  count       = local.is_cohort2 ? 1 : 0
  provider    = aws.us_east_1
  name        = "/f7i/vertex/location"
  description = "GCP region for Vertex AI CustomJobs. us-east-1 mirror."
  type        = "String"
  value       = var.region
}

resource "aws_ssm_parameter" "vertex_staging_bucket_use1" {
  count       = local.is_cohort2 ? 1 : 0
  provider    = aws.us_east_1
  name        = "/f7i/vertex/staging_bucket"
  description = "GCS bucket for training channels and Vertex job outputs. us-east-1 mirror."
  type        = "String"
  value       = google_storage_bucket.vertex_trainer_staging.name
}

resource "aws_ssm_parameter" "vertex_sa_email_use1" {
  count       = local.is_cohort2 ? 1 : 0
  provider    = aws.us_east_1
  name        = "/f7i/vertex/sa_email"
  description = "GCP service account Vertex CustomJobs run as. us-east-1 mirror."
  type        = "String"
  value       = google_service_account.vertex_trainer.email
}

resource "aws_ssm_parameter" "vertex_image_uri_use1" {
  count       = local.is_cohort2 ? 1 : 0
  provider    = aws.us_east_1
  name        = "/f7i/vertex/image_uri"
  description = "Container image for Vertex CustomJob workers. us-east-1 mirror."
  type        = "String"
  value       = var.vertex_trainer_image
}

resource "aws_ssm_parameter" "vertex_code_uri_use1" {
  count       = local.is_cohort2 ? 1 : 0
  provider    = aws.us_east_1
  name        = "/f7i/vertex/code_uri"
  description = "GCS URI to the training-code zip. us-east-1 mirror."
  type        = "String"
  value       = "gs://${google_storage_bucket.vertex_trainer_staging.name}/${google_storage_bucket_object.vertex_trainer_code.name}"
}

resource "aws_ssm_parameter" "vertex_machine_type_use1" {
  count       = local.is_cohort2 ? 1 : 0
  provider    = aws.us_east_1
  name        = "/f7i/vertex/machine_type"
  description = "Vertex worker machine type. us-east-1 mirror."
  type        = "String"
  value       = var.vertex_machine_type
}

resource "aws_ssm_parameter" "vertex_wif_config_json_use1" {
  count       = local.is_cohort2 ? 1 : 0
  provider    = aws.us_east_1
  name        = "/f7i/vertex/wif_config_json"
  description = "External-account WIF credentials config. us-east-1 mirror."
  type        = "SecureString"
  value = jsonencode({
    type                              = "external_account"
    audience                          = "//iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.aws_pool.workload_identity_pool_id}/providers/${google_iam_workload_identity_pool_provider.aws_provider.workload_identity_pool_provider_id}"
    subject_token_type                = "urn:ietf:params:aws:token-type:aws4_request"
    service_account_impersonation_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${google_service_account.vertex_trainer.email}:generateAccessToken"
    token_url                         = "https://sts.googleapis.com/v1/token"
    credential_source = {
      environment_id                 = "aws1"
      regional_cred_verification_url = "https://sts.{region}.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15"
    }
  })
}

resource "aws_ssm_parameter" "vertex_eventbridge_bus_name_use1" {
  count       = local.is_cohort2 ? 1 : 0
  provider    = aws.us_east_1
  name        = "/f7i/vertex/eventbridge_bus_name"
  description = "EventBridge bus name in us-east-1 (mirror for certarus)."
  type        = "String"
  value       = aws_cloudwatch_event_bus.bridge_use1[0].name
}

resource "aws_ssm_parameter" "vertex_eventbridge_bus_arn_use1" {
  count       = local.is_cohort2 ? 1 : 0
  provider    = aws.us_east_1
  name        = "/f7i/vertex/eventbridge_bus_arn"
  description = "EventBridge bus ARN in us-east-1 (mirror for certarus)."
  type        = "String"
  value       = aws_cloudwatch_event_bus.bridge_use1[0].arn
}

# ── Cross-region forwarder: ap-southeast-2 bus → us-east-1 bus ────────────────
# A rule on the primary (ap-southeast-2) bus matches VertexTrainingJobStateChange
# events with labels.tenant=certarus and targets the us-east-1 bus's ARN.
# EventBridge handles the cross-region PutEvents itself — the Cloud Function
# stays single-region (still publishes only to ap-southeast-2).

data "aws_iam_policy_document" "eb_cross_region_assume" {
  count = local.is_cohort2 ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eb_cross_region_forwarder" {
  count              = local.is_cohort2 ? 1 : 0
  name               = "f7i-gcp-bridge-cross-region-forwarder"
  description        = "Assumed by EventBridge to PutEvents on the us-east-1 mirror bus (certarus tenant)."
  assume_role_policy = data.aws_iam_policy_document.eb_cross_region_assume[0].json
}

resource "aws_iam_role_policy" "eb_cross_region_forwarder" {
  count = local.is_cohort2 ? 1 : 0
  name  = "f7i-gcp-bridge-cross-region-forwarder"
  role  = aws_iam_role.eb_cross_region_forwarder[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "PutEventsCrossRegion"
      Effect   = "Allow"
      Action   = ["events:PutEvents"]
      Resource = aws_cloudwatch_event_bus.bridge_use1[0].arn
    }]
  })
}

resource "aws_cloudwatch_event_rule" "forward_certarus_to_use1" {
  count          = local.is_cohort2 ? 1 : 0
  name           = "forward-certarus-to-us-east-1"
  description    = "Forward VertexTrainingJobStateChange events for tenant=certarus to the us-east-1 mirror bus."
  event_bus_name = aws_cloudwatch_event_bus.bridge.name

  event_pattern = jsonencode({
    source        = ["gcp.vertex-ai"]
    "detail-type" = ["VertexTrainingJobStateChange"]
    detail = {
      labels = {
        tenant = ["certarus"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "forward_certarus_to_use1" {
  count          = local.is_cohort2 ? 1 : 0
  rule           = aws_cloudwatch_event_rule.forward_certarus_to_use1[0].name
  event_bus_name = aws_cloudwatch_event_bus.bridge.name
  arn            = aws_cloudwatch_event_bus.bridge_use1[0].arn
  role_arn       = aws_iam_role.eb_cross_region_forwarder[0].arn
}
