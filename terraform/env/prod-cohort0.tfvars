# cohort0 = arnotts
# Paired with gcp-prod-cohort0.backend.hcl; targets AWS account 935969326135.
# First apply needed owner on the prod project for the CI SA — granted
# manually 2026-05-19 via gcloud, now terraform-managed (github_terraform_owner).
project_id  = "anomaly-detection-496003"
region      = "australia-southeast1"
environment = "prod"
cohort      = "cohort0"

manage_cloud_function_public_invoker = false

# Filled after first apply created the SAs. Second apply binds these into
# the AWS-side OIDC trust conditions (accounts.google.com:aud) so real
# tokens from the GCP functions match.
gcp_bridge_sa_id            = "101338956189147266648"
gcp_vertex_completion_sa_id = "104099614363252033994"
