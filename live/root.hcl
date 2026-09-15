# Defines configuration shared by all Terragrunt units in the live hierarchy.
locals {
  # AWS region in which all project resources are deployed.
  aws_region = "us-east-1"

  # Human-readable project identifier used for consistent resource tagging.
  project_name = "event-driven-ingestion"

  # Common tags applied to supported AWS resources across all environments.
  common_tags = {
    Project   = local.project_name
    ManagedBy = "Terragrunt"
    Owner     = "ZacIsrael"
  }
}

# Generates the Terraform provider configuration for each Terragrunt unit.
# This avoids duplicating provider and version configuration across the
# storage and processor deployments.
generate "provider" {
  # Write the generated configuration into each Terragrunt working directory.
  path = "provider.tf"

  # Allow Terragrunt to replace provider.tf only when the existing file
  # was previously generated and managed by Terragrunt.
  if_exists = "overwrite_terragrunt"

  # Define the Terraform version, AWS provider dependency, and deployment region.
  contents = <<EOF
terraform {
  required_version = "= 1.16.2"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "${local.aws_region}"
}
EOF
}

# Generates a stable local backend configuration for every Terragrunt unit.
# State is stored outside Terragrunt's disposable cache so deleting
# .terragrunt-cache does not remove the project's Terraform state.
generate "backend" {
  # Generate the backend configuration in each Terragrunt working directory.
  path = "backend.tf"

  # Allow Terragrunt to replace backend.tf only when the existing file
  # was previously generated and managed by Terragrunt.
  if_exists = "overwrite_terragrunt"

  # Generate a local Terraform backend with a deterministic state path.
  # path_relative_to_include() returns the unit's path relative to live/,
  # producing separate state files for units such as dev/storage and
  # dev/processor.
  contents = <<EOF
terraform {
  backend "local" {
    path = "${get_parent_terragrunt_dir()}/.state/${path_relative_to_include()}/terraform.tfstate"
  }
}
EOF
}

# Pass shared resource tags to every Terraform module that includes this
# root configuration. Environment-specific and module-specific values are
# defined by the individual Terragrunt units.
inputs = {
  common_tags = local.common_tags
}