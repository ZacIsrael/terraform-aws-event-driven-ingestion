# Configure the AWS provider used during the Terraform test.
provider "aws" {
  region = "us-east-1"
}

# Supply test-only values for the storage module's required inputs.
variables {
  environment               = "test"
  s3_bucket_prefix          = "test-json-ingestion"
  s3_object_expiration_days = 30
  dynamodb_table_name       = "test-events"
}

run "storage_module_configuration" {
  # Generate a Terraform plan without creating or modifying AWS resources.
  command = plan

  # Evaluate the reusable storage module.
  module {
    source = "./modules/storage"
  }

  # Verify that S3 versioning is enabled for the ingestion bucket.
  # Versioning preserves previous object versions after changes or deletion.
  assert {
    condition     = aws_s3_bucket_versioning.ingestion.versioning_configuration[0].status == "Enabled"
    error_message = "Expected S3 versioning to be enabled for the ingestion bucket."
  }

  # Verify that the ingestion bucket blocks all forms of public access.
  # Uploaded ingestion objects should never be publicly accessible.
  assert {
    condition = (
      aws_s3_bucket_public_access_block.ingestion.block_public_acls == true &&
      aws_s3_bucket_public_access_block.ingestion.ignore_public_acls == true &&
      aws_s3_bucket_public_access_block.ingestion.block_public_policy == true &&
      aws_s3_bucket_public_access_block.ingestion.restrict_public_buckets == true
    )

    error_message = "Expected all S3 public access block settings to be enabled."
  }

  # Verify that the lifecycle rule uses the configured expiration period.
  # This prevents ingestion objects from being retained indefinitely.
  assert {
    condition = (
      aws_s3_bucket_lifecycle_configuration.ingestion
      .rule[0]
      .expiration[0]
      .days == var.s3_object_expiration_days
    )

    error_message = "Expected S3 objects to expire after the configured retention period."
  }

  # Verify that the DynamoDB table uses event_id as its partition key.
  # This key uniquely identifies each processed application event.
  assert {
    condition     = aws_dynamodb_table.processed_events.hash_key == "event_id"
    error_message = "Expected the DynamoDB partition key to be event_id."
  }

  # Verify that DynamoDB uses on-demand capacity instead of provisioned capacity.
  # PAY_PER_REQUEST is appropriate for the variable workload in this project.
  assert {
    condition     = aws_dynamodb_table.processed_events.billing_mode == "PAY_PER_REQUEST"
    error_message = "Expected the DynamoDB table to use PAY_PER_REQUEST billing."
  }

  # Verify that DynamoDB TTL is enabled using the expires_at attribute.
  # TTL allows expired event records to be removed automatically.
  assert {
    condition = (
      aws_dynamodb_table.processed_events.ttl[0].enabled == true &&
      aws_dynamodb_table.processed_events.ttl[0].attribute_name == "expires_at"
    )

    error_message = "Expected DynamoDB TTL to be enabled using the expires_at attribute."
  }
}
