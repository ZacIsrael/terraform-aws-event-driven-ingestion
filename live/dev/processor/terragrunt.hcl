# Configures the dev deployment of the reusable processor Terraform module.
terraform {
  # Reference the processor module relative to this Terragrunt unit.
  source = "../../../modules/processor"
}

# Inherit shared provider configuration and common inputs from live/root.hcl.
include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Declare the dev storage Terragrunt unit as a dependency.
# Real storage outputs are consumed after the storage unit has been applied.
dependency "storage" {
  config_path = "../storage"

  # Provide placeholder values for commands that must evaluate this
  # configuration before the storage infrastructure has been deployed.
  mock_outputs = {
    bucket_name         = "mock-ingestion-bucket"
    bucket_arn          = "arn:aws:s3:::mock-ingestion-bucket"
    dynamodb_table_name = "mock-processed-events"
    dynamodb_table_arn  = "arn:aws:dynamodb:us-east-1:123456789012:table/mock-processed-events"
  }

  # Restrict mock values to commands that do not deploy infrastructure.
  mock_outputs_allowed_terraform_commands = [
    "validate",
    "plan",
  ]
}

# Provide environment-specific inputs required by the processor module.
inputs = {
  # Identify resources created by this unit as part of the dev environment.
  environment = "dev"

  # Configure the Lambda function that processes ingestion events.
  lambda_name            = "dev-process-event"
  lambda_timeout_seconds = 30
  lambda_batch_size      = 10

  # Configure SQS message retention and retry timing.
  sqs_message_retention_seconds  = 345600
  sqs_visibility_timeout_seconds = 180
  dlq_message_retention_seconds  = 1209600

  # Retain process-event Lambda logs in CloudWatch for seven days.
  log_retention_days = 7

  # Consume the S3 bucket identifiers exposed by the storage deployment.
  s3_bucket_name = dependency.storage.outputs.bucket_name
  s3_bucket_arn  = dependency.storage.outputs.bucket_arn

  # Consume the DynamoDB table identifiers exposed by the storage deployment.
  dynamodb_table_name = dependency.storage.outputs.dynamodb_table_name
  dynamodb_table_arn  = dependency.storage.outputs.dynamodb_table_arn
}