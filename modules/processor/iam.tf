# Defines the least-privilege S3 permissions required by the process-event Lambda.
data "aws_iam_policy_document" "process_event_s3" {
  statement {
    # Allow the Lambda to retrieve uploaded event files from the ingestion bucket.
    effect = "Allow"

    actions = [
      "s3:GetObject",
    ]

    # Restrict object reads to the incoming/ prefix of this project's
    # S3 ingestion bucket.
    resources = [
      "${var.s3_bucket_arn}/incoming/*",
    ]
  }
}

# Defines the least-privilege DynamoDB permissions required by the
# process-event Lambda.
data "aws_iam_policy_document" "process_event_dynamodb" {
  statement {
    # Allow the Lambda to persist processed events to DynamoDB.
    effect = "Allow"

    actions = [
      "dynamodb:PutItem",
    ]

    # Restrict writes to the processed-events table managed by
    # the storage module.
    resources = [
      var.dynamodb_table_arn,
    ]
  }
}

# Defines the SQS permissions required for Lambda to consume messages
# from the ingestion queue through its event source mapping.
data "aws_iam_policy_document" "process_event_sqs" {
  statement {
    # Allow the Lambda to consume messages from the ingestion queue.
    effect = "Allow"

    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]

    # Restrict queue operations to this processor module's ingestion queue.
    resources = [
      aws_sqs_queue.ingestion.arn,
    ]
  }
}

# Creates the execution role assumed by the process-event Lambda function.
resource "aws_iam_role" "process_event" {
  # Include the environment so independently deployed environments receive
  # distinct execution roles.
  name = "${var.environment}-process-event-lambda-execution-role"

  # Allow only the AWS Lambda service to assume this execution role.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"

        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(
    var.common_tags,
    {
      Name        = "${var.environment}-process-event-lambda-execution-role"
      Environment = var.environment
    }
  )
}

# Attaches the AWS-managed basic execution policy so the Lambda can
# create log streams and write application logs to CloudWatch Logs.
resource "aws_iam_role_policy_attachment" "process_event_basic_execution" {
  role = aws_iam_role.process_event.name

  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Creates the customer-managed IAM policy that permits the Lambda
# to retrieve incoming event files from S3.
resource "aws_iam_policy" "process_event_s3" {
  name   = "${var.environment}-process-event-s3-access"
  policy = data.aws_iam_policy_document.process_event_s3.json
}

# Attaches the S3 read policy to the process-event Lambda execution role.
resource "aws_iam_role_policy_attachment" "process_event_s3" {
  role       = aws_iam_role.process_event.name
  policy_arn = aws_iam_policy.process_event_s3.arn
}

# Creates the customer-managed IAM policy that permits the Lambda
# to write processed events to DynamoDB.
resource "aws_iam_policy" "process_event_dynamodb" {
  name   = "${var.environment}-process-event-dynamodb-access"
  policy = data.aws_iam_policy_document.process_event_dynamodb.json
}

# Attaches the DynamoDB write policy to the process-event Lambda execution role.
resource "aws_iam_role_policy_attachment" "process_event_dynamodb" {
  role       = aws_iam_role.process_event.name
  policy_arn = aws_iam_policy.process_event_dynamodb.arn
}

# Creates the customer-managed IAM policy containing the permissions
# required for Lambda to consume messages from the ingestion queue.
resource "aws_iam_policy" "process_event_sqs" {
  name   = "${var.environment}-process-event-sqs-consumer"
  policy = data.aws_iam_policy_document.process_event_sqs.json
}

# Attaches the SQS consumer policy to the process-event Lambda execution role.
resource "aws_iam_role_policy_attachment" "process_event_sqs" {
  role       = aws_iam_role.process_event.name
  policy_arn = aws_iam_policy.process_event_sqs.arn
}
