# Exposes the deployed process-event Lambda function name to calling
# configurations that need to identify or reference the processor function.
output "lambda_function_name" {
  description = "Name of the Lambda function that processes ingestion events."
  value       = aws_lambda_function.process_event.function_name
}

# Exposes the process-event Lambda ARN for integrations, IAM policies,
# monitoring, and other infrastructure that requires the function ARN.
output "lambda_function_arn" {
  description = "ARN of the Lambda function that processes ingestion events."
  value       = aws_lambda_function.process_event.arn
}

# Exposes the Lambda execution role ARN for auditing, IAM integration,
# and configurations that need to identify the processor's execution identity.
output "lambda_execution_role_arn" {
  description = "ARN of the IAM execution role assumed by the process-event Lambda function."
  value       = aws_iam_role.process_event.arn
}

# Exposes the SQS ingestion queue name so calling configurations can
# identify the primary queue used to buffer events before Lambda processing.
output "sqs_ingestion_queue_name" {
  description = "Name of the SQS queue that buffers ingestion events for processing."
  value       = aws_sqs_queue.ingestion.name
}

# Exposes the SQS ingestion queue ARN for integrations and IAM policies
# that require the queue's Amazon Resource Name.
output "sqs_ingestion_queue_arn" {
  description = "ARN of the SQS queue that buffers ingestion events for processing."
  value       = aws_sqs_queue.ingestion.arn
}

# Exposes the SQS ingestion queue URL for operations and integrations
# that interact with the queue through the SQS API.
output "sqs_ingestion_queue_url" {
  description = "URL of the SQS queue that buffers ingestion events for processing."
  value       = aws_sqs_queue.ingestion.url
}

# Exposes the dead-letter queue name so failed-message storage can be
# identified for monitoring, troubleshooting, and operational inspection.
output "sqs_dlq_name" {
  description = "Name of the SQS dead-letter queue that stores messages that repeatedly fail processing."
  value       = aws_sqs_queue.ingestion_dlq.name
}

# Exposes the dead-letter queue ARN for integrations, IAM policies,
# and other infrastructure that requires the DLQ resource identifier.
output "sqs_dlq_arn" {
  description = "ARN of the SQS dead-letter queue that stores messages that repeatedly fail processing."
  value       = aws_sqs_queue.ingestion_dlq.arn
}

# Exposes the EventBridge rule name so calling configurations can identify
# the rule responsible for routing matching S3 object-created events to SQS.
output "eventbridge_rule_name" {
  description = "Name of the EventBridge rule that routes matching S3 ingestion events to SQS."
  value       = aws_cloudwatch_event_rule.ingestion.name
}

# Exposes the EventBridge rule ARN for integrations, auditing, and
# configurations that require the rule's Amazon Resource Name.
output "eventbridge_rule_arn" {
  description = "ARN of the EventBridge rule that routes matching S3 ingestion events to SQS."
  value       = aws_cloudwatch_event_rule.ingestion.arn
}

# Exposes the Lambda event source mapping UUID so the SQS-to-Lambda
# integration can be uniquely identified and inspected.
output "lambda_event_source_mapping_uuid" {
  description = "UUID of the event source mapping that connects the SQS ingestion queue to the process-event Lambda."
  value       = aws_lambda_event_source_mapping.ingestion_queue.uuid
}

# Exposes the process-event Lambda CloudWatch log group name for
# troubleshooting, log inspection, and operational tooling.
output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch log group that stores logs from the process-event Lambda."
  value       = aws_cloudwatch_log_group.process_event.name
}

# Exposes the Lambda error alarm name so the processor's invocation-failure
# alarm can be identified by calling configurations and operational tooling.
output "lambda_error_alarm_name" {
  description = "Name of the CloudWatch alarm that detects errors from the process-event Lambda."
  value       = aws_cloudwatch_metric_alarm.process_event_errors.alarm_name
}

# Exposes the DLQ message alarm name so persistent message-processing
# failures can be identified by calling configurations and operational tooling.
output "dlq_message_alarm_name" {
  description = "Name of the CloudWatch alarm that detects visible messages in the ingestion dead-letter queue."
  value       = aws_cloudwatch_metric_alarm.ingestion_dlq_messages.alarm_name
}
