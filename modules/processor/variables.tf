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
