# Environment identifier used for resource naming and configuration.
# Expected values include dev, stage, prod, and test.
variable "environment" {
  description = "Deployment environment for the storage resources."
  type        = string
}

# Number of seconds that unprocessed messages remain in the ingestion queue.
variable "sqs_message_retention_seconds" {
  description = "Number of seconds that messages are retained in the SQS ingestion queue."
  type        = number
}

# Number of seconds that a received message remains invisible to other consumers.
# This must provide sufficient time for the ingestion Lambda to finish processing.
variable "sqs_visibility_timeout_seconds" {
  description = "Visibility timeout in seconds for messages in the SQS ingestion queue."
  type        = number
}

# Number of seconds that failed messages are retained in the dead-letter queue.
variable "dlq_message_retention_seconds" {
  description = "Number of seconds that messages are retained in the SQS dead-letter queue."
  type        = number
}

# Common metadata tags applied to supported resources managed by this module.
variable "common_tags" {
  description = "Common tags applied to AWS resources managed by this module."
  type        = map(string)
  default     = {}
}

# Name of the S3 ingestion bucket managed by the storage module.
# Used by EventBridge to restrict processing to objects from that bucket.
variable "s3_bucket_name" {
  description = "Name of the S3 ingestion bucket monitored by EventBridge."
  type        = string
}


# Name assigned to the Lambda function that processes ingestion events
# received from the SQS ingestion queue.
variable "lambda_name" {
  description = "Name of the Lambda function that processes ingestion events."
  type        = string
}

# Maximum amount of time the process-event Lambda is allowed to run
# before AWS Lambda terminates the invocation.
variable "lambda_timeout_seconds" {
  description = "Maximum execution time in seconds for the process-event Lambda function."
  type        = number
}

# Maximum number of SQS messages that Lambda can receive in a single
# invocation from the ingestion queue.
variable "lambda_batch_size" {
  description = "Maximum number of SQS messages processed by the process-event Lambda in a single batch."
  type        = number
}

# Name of the DynamoDB table managed by the storage module.
# The process-event Lambda uses this table to persist processed events
# and enforce idempotent writes.
variable "dynamodb_table_name" {
  description = "Name of the DynamoDB table used by the process-event Lambda to store processed events."
  type        = string
}
