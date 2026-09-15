# Creates the CloudWatch Logs log group used by the process-event Lambda.
# Managing the log group explicitly allows Terraform to control log retention
# instead of relying on the Lambda service to create it automatically.
resource "aws_cloudwatch_log_group" "process_event" {
  # Lambda writes logs to a log group using the /aws/lambda/<function-name>
  # naming convention.
  name = "/aws/lambda/${var.lambda_name}"

  # Automatically removes older application logs after the configured
  # retention period to prevent indefinite log storage.
  retention_in_days = var.log_retention_days

  # Combine shared tags with resource-specific metadata.
  tags = merge(
    var.common_tags,
    {
      Name        = "${var.lambda_name}-logs"
      Environment = var.environment
    }
  )
}

# Creates a CloudWatch alarm that detects invocation errors from the
# process-event Lambda function.
resource "aws_cloudwatch_metric_alarm" "process_event_errors" {
  alarm_name          = "${var.environment}-${var.lambda_name}-errors"
  alarm_description   = "Triggers when the process-event Lambda reports one or more invocation errors."
  comparison_operator = "GreaterThanThreshold"

  # Evaluate the Lambda error count over a single one-minute period.
  evaluation_periods = 1
  period             = 60

  # Monitor the native Lambda Errors metric.
  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  statistic   = "Sum"

  # Enter the ALARM state when at least one Lambda error occurs.
  threshold          = 0
  treat_missing_data = "notBreaching"

  # Restrict the metric to this specific Lambda function.
  dimensions = {
    FunctionName = aws_lambda_function.process_event.function_name
  }

  # No alarm_actions are configured because external notification
  # services such as SNS are outside the scope of the core project.

  # Combine shared tags with resource-specific metadata.
  tags = merge(
    var.common_tags,
    {
      Name        = "${var.environment}-${var.lambda_name}-errors"
      Environment = var.environment
    }
  )
}

# Creates a CloudWatch alarm that detects messages waiting in the
# ingestion dead-letter queue.
resource "aws_cloudwatch_metric_alarm" "ingestion_dlq_messages" {
  alarm_name        = "${var.environment}-ingestion-dlq-messages"
  alarm_description = "Triggers when one or more messages are visible in the ingestion dead-letter queue."

  comparison_operator = "GreaterThanThreshold"

  # Evaluate the DLQ message count over a single one-minute period.
  evaluation_periods = 1
  period             = 60

  # Monitor the number of messages currently available in the DLQ.
  namespace   = "AWS/SQS"
  metric_name = "ApproximateNumberOfMessagesVisible"
  statistic   = "Maximum"

  # Enter the ALARM state when at least one message is visible in the DLQ.
  threshold          = 0
  treat_missing_data = "notBreaching"

  # Restrict the metric to this processor module's dead-letter queue.
  dimensions = {
    QueueName = aws_sqs_queue.ingestion_dlq.name
  }

  # No alarm_actions or ok_actions are configured because external
  # notification services such as SNS are outside the scope of the core project.

  # Combine shared tags with resource-specific metadata.
  tags = merge(
    var.common_tags,
    {
      Name        = "${var.environment}-ingestion-dlq-messages"
      Environment = var.environment
    }
  )
}
