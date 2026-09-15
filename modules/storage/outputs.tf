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
