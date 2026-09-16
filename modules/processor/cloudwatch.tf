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

# Alarm that detects when messages remain in the ingestion queue for too long.
# Helps identify a growing or stalled processing backlog.
resource "aws_cloudwatch_metric_alarm" "sqs_oldest_message_age" {
  alarm_name        = "${var.environment}-ingestion-oldest-message-age"
  alarm_description = "Triggers when the oldest message in the ingestion queue exceeds the configured age threshold."

  # Enter the ALARM state when the oldest message exceeds the threshold.
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1

  # Monitor the age, in seconds, of the oldest message in the ingestion queue.
  namespace   = "AWS/SQS"
  metric_name = "ApproximateAgeOfOldestMessage"
  statistic   = "Maximum"

  # Evaluate the oldest message age over one-minute periods.
  period = 60

  # Trigger when the oldest message has remained in the queue for over 5 minutes.
  threshold = 300

  # Treat periods without metric data as healthy rather than triggering the alarm.
  treat_missing_data = "notBreaching"

  # Restrict the metric to this processor module's primary ingestion queue.
  dimensions = {
    QueueName = aws_sqs_queue.ingestion.name
  }

  # Combine shared tags with resource-specific metadata.
  tags = merge(
    var.common_tags,
    {
      Name        = "${var.environment}-ingestion-oldest-message-age"
      Environment = var.environment
    }
  )
}


# Alarm when Lambda wants to process work but AWS is throttling invocations.
resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name        = "${var.environment}-${var.lambda_name}-throttles"
  alarm_description = "Triggers when the Lambda function experiences one or more throttled invocations."

  # Enter the ALARM state when the number of throttled invocations exceeds zero.
  comparison_operator = "GreaterThanThreshold"

  # Evaluate the Lambda throttle count over a single one-minute period.
  evaluation_periods = 1
  period             = 60

  # Monitor the native Lambda Throttles metric.
  namespace   = "AWS/Lambda"
  metric_name = "Throttles"
  statistic   = "Sum"

  # Enter the ALARM state when at least one Lambda invocation is throttled.
  threshold          = 0
  treat_missing_data = "notBreaching"

  # Restrict the metric to this specific Lambda function.
  dimensions = {
    FunctionName = aws_lambda_function.process_event.function_name
  }

  # Combine shared tags with resource-specific metadata.
  tags = merge(
    var.common_tags,
    {
      Name        = "${var.environment}-${var.lambda_name}-throttles"
      Environment = var.environment
    }
  )
}
