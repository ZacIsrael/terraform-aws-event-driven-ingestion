# Packages the compiled process-event Lambda code into a deployment ZIP archive.
data "archive_file" "process_event_code" {
  # Create a ZIP-formatted Lambda deployment package.
  type = "zip"

  # Include the compiled JavaScript Lambda handler.
  source {
    content  = file("${path.module}/../../dist/process-event/index.js")
    filename = "index.js"
  }

  # Mark JavaScript files in the deployment package as ES modules.
  source {
    content = jsonencode({
      type = "module"
    })

    filename = "package.json"
  }

  # Store the generated deployment archive alongside the compiled function.
  output_path = "${path.module}/../../dist/process-event/function.zip"
}

# Creates the Lambda function that processes ingestion events received from SQS.
resource "aws_lambda_function" "process_event" {
  # Use the caller-provided name for the deployed Lambda function.
  function_name = var.lambda_name

  # Upload the ZIP archive generated from the compiled Lambda code.
  filename = data.archive_file.process_event_code.output_path

  # Redeploy the function whenever the deployment package contents change.
  source_code_hash = data.archive_file.process_event_code.output_base64sha256

  # Attach the least-privilege execution role defined for the processor Lambda.
  role = aws_iam_role.process_event.arn

  # Invoke the exported handler function from the compiled index.js file.
  handler = "index.handler"

  # Execute the function using the Node.js 22.x Lambda runtime.
  runtime = "nodejs22.x"

  # Limit the maximum execution time for each Lambda invocation.
  timeout = var.lambda_timeout_seconds

  # Provide storage resource identifiers required by the Lambda at runtime.
  environment {
    variables = {
      S3_BUCKET_NAME       = var.s3_bucket_name
      DYNAMODB_TABLE_NAME  = var.dynamodb_table_name
    }
  }

  # Combine shared tags with resource-specific metadata.
  tags = merge(
    var.common_tags,
    {
      Name        = var.lambda_name
      Environment = var.environment
    }
  )
}

# Connects the SQS ingestion queue to the process-event Lambda function.
# Lambda polls the queue and invokes the function with batches of messages.
resource "aws_lambda_event_source_mapping" "ingestion_queue" {
  # Consume messages from the processor module's SQS ingestion queue.
  event_source_arn = aws_sqs_queue.ingestion.arn

  # Invoke the process-event Lambda for messages received from the queue.
  function_name = aws_lambda_function.process_event.arn

  # Controls the maximum number of SQS messages delivered in one invocation.
  batch_size = var.lambda_batch_size

  # Report individual failed messages instead of failing an entire batch.
  # This implements the partial-batch behavior documented for the pipeline.
  function_response_types = [
    "ReportBatchItemFailures"
  ]

  # Enable SQS event processing immediately after the mapping is created.
  enabled = true
}