# Environment identifier used for resource naming and configuration.
# Expected values include dev, stage, prod, and test.
variable "environment" {
  description = "Deployment environment for the storage resources."
  type        = string
}

# Prefix used when Terraform generates the globally unique S3 bucket name.
# A prefix is preferred over requiring callers to provide a complete bucket name.
variable "s3_bucket_prefix" {
  description = "Prefix used to generate the S3 ingestion bucket name."
  type        = string
}

# Controls whether S3 versioning is enabled for the ingestion bucket.
# Versioning protects uploaded event objects from accidental overwrite or deletion.
variable "s3_versioning_enabled" {
  description = "Whether versioning is enabled for the S3 ingestion bucket."
  type        = bool
  default     = true
}

# Number of days after which ingested S3 objects expire.
# This provides lifecycle-based cleanup for event files that no longer need to be retained.
variable "s3_object_expiration_days" {
  description = "Number of days after which ingested S3 objects expire."
  type        = number
}

# Name assigned to the DynamoDB table used to persist processed events.
variable "dynamodb_table_name" {
  description = "Name of the DynamoDB table used to store processed events."
  type        = string
}

# Attribute used by DynamoDB TTL to identify expired event records.
# The application stores a Unix epoch timestamp in this attribute.
variable "dynamodb_ttl_attribute_name" {
  description = "DynamoDB attribute containing the expiration timestamp used for TTL."
  type        = string
  default     = "expires_at"
}

# Common metadata tags applied to supported AWS resources managed by this module.
# Terragrunt can supply shared tags consistently across environments.
variable "common_tags" {
  description = "Common tags applied to AWS resources managed by this module."
  type        = map(string)
  default     = {}
}
