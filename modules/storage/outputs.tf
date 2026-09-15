# Exposes the generated S3 ingestion bucket name to calling modules
# and Terragrunt configurations that require the bucket identifier.
output "bucket_name" {
  description = "Name of the S3 ingestion bucket."
  value       = aws_s3_bucket.ingestion.id
}

# Exposes the S3 ingestion bucket ARN for IAM policies and other
# AWS resources that require the bucket's Amazon Resource Name.
output "bucket_arn" {
  description = "ARN of the S3 ingestion bucket."
  value       = aws_s3_bucket.ingestion.arn
}

# Exposes the DynamoDB table name to calling modules and Terragrunt
# configurations that need to interact with the processed-events table.
output "dynamodb_table_name" {
  description = "Name of the DynamoDB table used to store processed events."
  value       = aws_dynamodb_table.processed_events.name
}

# Exposes the DynamoDB table ARN for IAM policies and other AWS resources
# that require permission to access the processed-events table.
output "dynamodb_table_arn" {
  description = "ARN of the DynamoDB table used to store processed events."
  value       = aws_dynamodb_table.processed_events.arn
}