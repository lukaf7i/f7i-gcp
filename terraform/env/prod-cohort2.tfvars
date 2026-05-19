# cohort2
# Paired with gcp-prod-cohort2.backend.hcl; targets AWS account 043309367276.
project_id  = "anomaly-detection-496003"
region      = "australia-southeast1"
environment = "prod"
cohort      = "cohort2"

manage_cloud_function_public_invoker = false

# Filled after first apply created the SAs.
gcp_bridge_sa_id            = "117562300807125625233"
gcp_vertex_completion_sa_id = "113862012676359813236"
