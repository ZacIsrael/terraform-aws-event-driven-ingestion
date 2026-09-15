# Configures the dev deployment of the reusable storage Terraform module.
terraform {
  # Reference the storage module relative to this Terragrunt unit.
  source = "../../../modules/storage"
}

# Inherit shared provider configuration and common inputs from live/root.hcl.
include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Provide environment-specific inputs required by the storage module.
inputs = {
  # Identify resources created by this unit as part of the dev environment.
  environment = "dev"

  # Prefix used to construct the globally unique S3 ingestion bucket name.
  s3_bucket_prefix = "event-driven-ingestion"

  # Expire current and noncurrent ingestion objects after five days.
  s3_object_expiration_days = 5

  # Name of the DynamoDB table used to persist processed events.
  dynamodb_table_name = "dev-processed-events"
}