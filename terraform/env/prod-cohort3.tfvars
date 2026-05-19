# cohort3 = darrel lea
# Paired with gcp-prod-cohort3.backend.hcl; targets AWS account 471112541316.
project_id  = "anomaly-detection-496003"
region      = "australia-southeast1"
environment = "prod"
cohort      = "cohort3"

manage_cloud_function_public_invoker = false

# Fill in after first apply — see prod-cohort0.tfvars for the procedure.
gcp_bridge_sa_id            = ""
gcp_vertex_completion_sa_id = ""
