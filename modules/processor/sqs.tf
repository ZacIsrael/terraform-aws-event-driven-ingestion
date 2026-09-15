# Creates the dead-letter queue used to isolate messages that repeatedly
# fail processing in the ingestion pipeline.
resource "aws_sqs_queue" "ingestion_dlq" {
  name = "${var.environment}-ingestion-dlq"

  # Retains failed messages long enough for investigation and troubleshooting.
  message_retention_seconds = var.dlq_message_retention_seconds

  # Combines shared tags with resource-specific metadata.
  tags = merge(
    var.common_tags,
    {
      Name        = "${var.environment}-ingestion-dlq"
      Environment = var.environment
    }
  )
}

# Creates the primary SQS queue that buffers ingestion events before
# they are processed by the ingestion Lambda.
resource "aws_sqs_queue" "ingestion" {
  name = "${var.environment}-ingestion-queue"

  # Keeps messages immediately available for processing when they arrive.
  delay_seconds = 0

  # Retains unprocessed messages for the configured retention period.
  message_retention_seconds = var.sqs_message_retention_seconds

  # Enables SQS long polling to reduce empty receives and unnecessary API calls.
  receive_wait_time_seconds = 20

  # Controls how long a received message remains hidden while Lambda processes it.
  # This value must be coordinated with the Lambda function timeout.
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds

  # Moves a message to the DLQ after five unsuccessful receives.
  # This represents one initial attempt plus up to four retry attempts.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ingestion_dlq.arn
    maxReceiveCount     = 5
  })

  # Combines shared tags with resource-specific metadata.
  tags = merge(
    var.common_tags,
    {
      Name        = "${var.environment}-ingestion-queue"
      Environment = var.environment
    }
  )
}

# Restricts the DLQ so that only this module's ingestion queue is
# authorized to use it as a dead-letter queue.
resource "aws_sqs_queue_redrive_allow_policy" "ingestion_dlq" {
  queue_url = aws_sqs_queue.ingestion_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.ingestion.arn]
  })
}
