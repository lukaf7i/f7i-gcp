provider "google" {
  project = var.project_id
  region  = var.region

  # CI deployer SA lives in the prod project, so by default Google bills API
  # calls to *that* project's quota — which requires every API we touch to be
  # enabled there too. user_project_override charges quota to var.project_id
  # instead (the resource's project), where core_apis already enables them.
  user_project_override = true
  billing_project       = var.project_id
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      ManagedBy   = "terraform"
      Environment = var.environment
      Repository  = "f7i-ai/f7i-gcp"
    }
  }
}

# us-east-1 alias — only used by cohort2 to mirror the bridge bus + SSM
# params into the region where certarus (and only certarus) deploys.
# See cohort2_us_east_1.tf for the cohort2-gated resources.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      ManagedBy   = "terraform"
      Environment = var.environment
      Repository  = "f7i-ai/f7i-gcp"
    }
  }
}
