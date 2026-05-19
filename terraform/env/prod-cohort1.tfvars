# cohort1
# Paired with gcp-prod-cohort1.backend.hcl; targets AWS account 211125324898.
project_id  = "anomaly-detection-496003"
region      = "australia-southeast1"
environment = "prod"
cohort      = "cohort1"

manage_cloud_function_public_invoker = false

# Filled after first apply created the SAs.
gcp_bridge_sa_id            = "116395674458012624988"
gcp_vertex_completion_sa_id = "114370641915294550665"
