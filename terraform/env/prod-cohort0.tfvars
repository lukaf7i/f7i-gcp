# cohort0 = arnotts
# Paired with gcp-prod-cohort0.backend.hcl; targets AWS account 935969326135.
# First apply needed owner on the prod project for the CI SA — granted
# manually 2026-05-19 via gcloud, now terraform-managed (github_terraform_owner).
project_id  = "anomaly-detection-496003"
region      = "australia-southeast1"
environment = "prod"
cohort      = "cohort0"

manage_cloud_function_public_invoker = false

# Leave empty on first apply. After GCP creates the SAs, read the numeric IDs
# from `terraform output` and fill these in, then re-apply so the AWS-side
# OIDC trust policies bind to the correct azp values.
gcp_bridge_sa_id            = ""
gcp_vertex_completion_sa_id = ""
