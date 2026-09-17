# Configure the AWS provider used during the Terraform test.
provider "aws" {
  region = "us-east-1"
}

# Supply test-only values for the processor module's required inputs.
variables {
  environment                    = "test"
  sqs_message_retention_seconds  = 60
  sqs_visibility_timeout_seconds = 30
  dlq_message_retention_seconds  = 60
  s3_bucket_name                 = "test-json-ingestion"
  lambda_name                    = "ingestion-function"
  lambda_timeout_seconds         = 30
  lambda_batch_size              = 15
  dynamodb_table_name            = "event-table"
  s3_bucket_arn                  = "arn:aws:s3:::test-json-ingestion"
  dynamodb_table_arn             = "arn:aws:dynamodb:us-east-1:123456789012:table/event-table"
  log_retention_days             = 14
}

run "processor_module_configuration" {
  # Generate a Terraform plan without creating or modifying AWS resources.
  command = plan

  # Evaluate the reusable processor module.
  module {
    source = "./modules/processor"
  }


  # Verify that Lambda receives the configured maximum number of records per batch.
  # This ensures the event-source mapping respects the module's batch-size input.
  assert {
    condition     = aws_lambda_event_source_mapping.ingestion_queue.batch_size == var.lambda_batch_size
    error_message = "Expected the Lambda event-source mapping to use the configured batch size."
  }

  # Verify that Lambda reports individual SQS record failures.
  # This prevents one failed record from causing the entire batch to be retried.
  assert {
    condition = contains(
      aws_lambda_event_source_mapping.ingestion_queue.function_response_types,
      "ReportBatchItemFailures"
    )

    error_message = "Expected ReportBatchItemFailures to be enabled for the Lambda event-source mapping."
  }

  # Verify that the processor Lambda uses structured JSON logging.
  # Structured logs make CloudWatch output easier to search and analyze.
  assert {
    condition     = aws_lambda_function.process_event.logging_config[0].log_format == "JSON"
    error_message = "Expected the processor Lambda to use JSON structured logging."
  }

  # Verify that the Lambda error alarm monitors the native Errors metric.
  # This detects failed processor invocations.
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.process_event_errors.namespace == "AWS/Lambda" &&
      aws_cloudwatch_metric_alarm.process_event_errors.metric_name == "Errors" &&
      aws_cloudwatch_metric_alarm.process_event_errors.dimensions["FunctionName"] == aws_lambda_function.process_event.function_name
    )

    error_message = "Expected the Lambda errors alarm to monitor the processor Lambda Errors metric."
  }

  # Verify that the Lambda throttles alarm monitors the native Throttles metric.
  # This detects invocations rejected because Lambda is being throttled.
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.lambda_throttles.namespace == "AWS/Lambda" &&
      aws_cloudwatch_metric_alarm.lambda_throttles.metric_name == "Throttles" &&
      aws_cloudwatch_metric_alarm.lambda_throttles.dimensions["FunctionName"] == aws_lambda_function.process_event.function_name
    )

    error_message = "Expected the Lambda throttles alarm to monitor the processor Lambda Throttles metric."
  }

  # Verify that the queue-age alarm monitors the oldest ingestion message.
  # This detects a growing or stalled processing backlog.
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.sqs_oldest_message_age.namespace == "AWS/SQS" &&
      aws_cloudwatch_metric_alarm.sqs_oldest_message_age.metric_name == "ApproximateAgeOfOldestMessage" &&
      aws_cloudwatch_metric_alarm.sqs_oldest_message_age.dimensions["QueueName"] == aws_sqs_queue.ingestion.name
    )

    error_message = "Expected the SQS age alarm to monitor the oldest message in the ingestion queue."
  }

  # Verify that the DLQ alarm monitors visible dead-letter messages.
  # Any visible DLQ message indicates that processing repeatedly failed.
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.ingestion_dlq_messages.namespace == "AWS/SQS" &&
      aws_cloudwatch_metric_alarm.ingestion_dlq_messages.metric_name == "ApproximateNumberOfMessagesVisible" &&
      aws_cloudwatch_metric_alarm.ingestion_dlq_messages.dimensions["QueueName"] == aws_sqs_queue.ingestion_dlq.name
    )

    error_message = "Expected the DLQ alarm to monitor visible messages in the ingestion DLQ."
  }
}
