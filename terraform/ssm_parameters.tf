# Contract surface for f7i-cdk (predict service) to discover the GCP-side
# resources this repo creates. f7i-cdk reads these at synth time via
# `aws_ssm.StringParameter.value_from_lookup(...)` and bakes them into
# Lambda env vars.
#
# Path convention: /f7i/vertex/<key>. No environment suffix — AWS accounts
# are already environment-scoped (one dev account, four prod).

resource "aws_ssm_parameter" "vertex_project_id" {
  name        = "/f7i/vertex/project_id"
  description = "GCP project hosting Vertex AI."
  type        = "String"
  value       = var.project_id
}

resource "aws_ssm_parameter" "vertex_location" {
  name        = "/f7i/vertex/location"
  description = "GCP region for Vertex AI CustomJobs."
  type        = "String"
  value       = var.region
}

resource "aws_ssm_parameter" "vertex_staging_bucket" {
  name        = "/f7i/vertex/staging_bucket"
  description = "GCS bucket where training channels and job outputs are staged."
  type        = "String"
  value       = google_storage_bucket.vertex_trainer_staging.name
}

resource "aws_ssm_parameter" "vertex_sa_email" {
  name        = "/f7i/vertex/sa_email"
  description = "GCP service account Vertex CustomJobs run as (also impersonated by AWS Lambdas via WIF)."
  type        = "String"
  value       = google_service_account.vertex_trainer.email
}

resource "aws_ssm_parameter" "vertex_image_uri" {
  name        = "/f7i/vertex/image_uri"
  description = "Container image for Vertex CustomJob workers."
  type        = "String"
  value       = var.vertex_trainer_image
}

resource "aws_ssm_parameter" "vertex_code_uri" {
  name        = "/f7i/vertex/code_uri"
  description = "GCS URI to the training-code zip (entrypoint.py + sagemaker_rl/*.py). Downloaded by the container at job start."
  type        = "String"
  value       = "gs://${google_storage_bucket.vertex_trainer_staging.name}/${google_storage_bucket_object.vertex_trainer_code.name}"
}

resource "aws_ssm_parameter" "vertex_machine_type" {
  name        = "/f7i/vertex/machine_type"
  description = "Vertex worker machine type."
  type        = "String"
  value       = var.vertex_machine_type
}

resource "aws_ssm_parameter" "vertex_wif_config_json" {
  name        = "/f7i/vertex/wif_config_json"
  description = "External-account credentials config — point GOOGLE_APPLICATION_CREDENTIALS at a file containing this JSON to impersonate the Vertex SA from an AWS Lambda."
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

resource "aws_ssm_parameter" "vertex_eventbridge_bus_name" {
  name        = "/f7i/vertex/eventbridge_bus_name"
  description = "Name of the EventBridge bus the completion bridge publishes VertexTrainingJobStateChange events on."
  type        = "String"
  value       = aws_cloudwatch_event_bus.bridge.name
}

resource "aws_ssm_parameter" "vertex_eventbridge_bus_arn" {
  name        = "/f7i/vertex/eventbridge_bus_arn"
  description = "ARN of the EventBridge bus the completion bridge publishes to."
  type        = "String"
  value       = aws_cloudwatch_event_bus.bridge.arn
}

resource "aws_ssm_parameter" "vertex_model_s3_bucket" {
  name        = "/f7i/vertex/model_s3_bucket"
  description = "Default S3 bucket the completion bridge copies model.tar.gz into when the CustomJob doesn't specify a predict_bucket label. Per-tenant buckets are preferred — set the label instead."
  type        = "String"
  value       = aws_s3_bucket.vertex_models.id
}
