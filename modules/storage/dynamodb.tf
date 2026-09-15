# Creates the DynamoDB table used to persist processed events.
resource "aws_dynamodb_table" "processed_events" {
  # Uses the caller-provided name for the DynamoDB table.
  name = var.dynamodb_table_name

  # Uses on-demand capacity so DynamoDB automatically handles request throughput.
  billing_mode = "PAY_PER_REQUEST"

  # Uses event_id as the partition key to uniquely identify processed events.
  hash_key = "event_id"

  # Defines the string attribute used as the table's partition key.
  attribute {
    name = "event_id"
    type = "S"
  }

  # Enables automatic cleanup of expired records using the configured
  # expiration timestamp attribute.
  ttl {
    attribute_name = var.dynamodb_ttl_attribute_name
    enabled        = true
  }

  # Combines shared tags supplied by Terragrunt with resource-specific tags.
  tags = merge(
    var.common_tags,
    {
      Name        = var.dynamodb_table_name
      Environment = var.environment
    }
  )
}
