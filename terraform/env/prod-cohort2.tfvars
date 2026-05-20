# cohort2
# Paired with gcp-prod-cohort2.backend.hcl; targets AWS account 043309367276.
# Re-apply 2026-05-20: pick up /f7i/predict/consumer_role_arn/* SSM entries
# (app, casinofoodco, stanmore in ap-southeast-2; certarus in us-east-1) so
# the Vertex trainer SA's WIF binding includes the CDK predict consumer Lambdas.
project_id  = "anomaly-detection-496003"
region      = "australia-southeast1"
environment = "prod"
cohort      = "cohort2"

manage_cloud_function_public_invoker = false

# Filled after first apply created the SAs.
gcp_bridge_sa_id            = "117562300807125625233"
gcp_vertex_completion_sa_id = "113862012676359813236"
