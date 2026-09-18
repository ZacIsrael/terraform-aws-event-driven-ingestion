# Terraform AWS Event-Driven Ingestion Pipeline

An event-driven AWS ingestion pipeline built with Terraform and Terragrunt.

The project accepts JSON objects uploaded to Amazon S3, routes S3 object-created events through Amazon EventBridge and Amazon SQS, processes the referenced objects with AWS Lambda, validates their event contract, and persists valid events to Amazon DynamoDB.

The architecture includes idempotent DynamoDB writes, partial SQS batch failure handling, dead-letter queue processing, structured CloudWatch logging, and CloudWatch alarms.

## Architecture

```text
Amazon S3
   │
   │ Object Created
   ▼
Amazon EventBridge
   │
   ▼
Amazon SQS
   │
   ├── repeated processing failure ──► Dead-Letter Queue
   │
   ▼
AWS Lambda
   │
   ├── S3 GetObject
   │
   ├── JSON parsing
   │
   ├── event-contract validation
   │
   └── idempotent conditional write
   │
   ▼
Amazon DynamoDB

AWS Lambda / Amazon SQS
   │
   └──► Amazon CloudWatch
          ├── structured logs
          └── metric alarms
```

## Event Flow

1. A JSON object is uploaded beneath the S3 `incoming/` prefix.
2. Amazon S3 emits an Object Created event to Amazon EventBridge.
3. An EventBridge rule filters the event and forwards it to the ingestion SQS queue.
4. The SQS event-source mapping invokes the processor Lambda with one or more messages.
5. For each SQS record, the Lambda:
   - parses the EventBridge event;
   - extracts the S3 bucket and object key;
   - retrieves the referenced object from S3;
   - enforces the 64 KiB object-size limit;
   - parses the object as JSON;
   - validates the event contract; and
   - performs a conditional write to DynamoDB.
6. Successfully processed SQS records are removed from the queue.
7. Failed records are returned through `ReportBatchItemFailures` so successful records in the same batch are not retried.
8. Records that repeatedly fail processing are eventually moved to the dead-letter queue according to the SQS redrive policy.

## Event Contract

Processed JSON objects must contain the following fields:

```json
{
  "event_id": "customer-123",
  "event_type": "customer.created",
  "occurred_at": "2026-09-17T23:00:00Z",
  "source": "customer-service",
  "payload": {
    "customer_id": "123"
  }
}
```

### Validation Rules

- `event_id`
  - Required string
  - Length: 1–128 characters
- `event_type`
  - Required non-empty string
  - Uses a dot-separated event naming convention such as `customer.created`
- `occurred_at`
  - Required date-time value
- `source`
  - Required non-empty string
- `payload`
  - Required JSON object
  - Cannot be `null` or an array
- S3 object size
  - Maximum supported size: 64 KiB (65,536 bytes)

## Idempotency

The processor uses `event_id` as the DynamoDB partition key and performs an atomic conditional write:

```text
attribute_not_exists(event_id)
```

This prevents duplicate deliveries from overwriting or creating duplicate logical events.

If DynamoDB returns a `ConditionalCheckFailedException`, the Lambda interprets the event as an already-processed duplicate and treats it as a successful no-op.

This behavior is important because event-driven systems commonly provide at-least-once delivery semantics, meaning duplicate delivery must be expected and handled safely.

## Partial Batch Failure Handling

The Lambda event-source mapping enables:

```text
ReportBatchItemFailures
```

Each SQS record is processed independently.

If one record fails while other records in the same batch succeed, the Lambda returns only the failed SQS message identifiers:

```json
{
  "batchItemFailures": [
    {
      "itemIdentifier": "failed-message-id"
    }
  ]
}
```

This prevents successfully processed records from being unnecessarily retried.

## Dead-Letter Queue

The ingestion queue is configured with an SQS dead-letter queue.

The current development configuration uses:

```text
maxReceiveCount = 5
```

A message that repeatedly fails processing is moved to the DLQ after the configured receive threshold is exceeded.

The DLQ provides a location for failed events to be inspected without indefinitely blocking or retrying poison messages in the primary ingestion queue.

## Observability

### Structured Lambda Logging

The processor Lambda uses JSON-formatted CloudWatch logging.

Logs include structured fields such as:

```text
timestamp
level
requestId
message
```

### CloudWatch Alarms

The project provisions four CloudWatch alarms:

| Alarm | Metric | Purpose |
|---|---|---|
| Lambda Errors | `AWS/Lambda - Errors` | Detect processor execution errors |
| Lambda Throttles | `AWS/Lambda - Throttles` | Detect throttled Lambda invocations |
| SQS Oldest Message Age | `AWS/SQS - ApproximateAgeOfOldestMessage` | Detect stalled or growing queue backlogs |
| DLQ Messages Visible | `AWS/SQS - ApproximateNumberOfMessagesVisible` | Detect messages arriving in the dead-letter queue |

The oldest-message alarm currently uses a five-minute threshold.

## Infrastructure as Code

Infrastructure is organized into two reusable Terraform modules.

```text
modules/
├── storage/
└── processor/
```

### Storage Module

The storage module provisions resources including:

- S3 ingestion bucket
- S3 versioning
- S3 lifecycle configuration
- S3 encryption
- DynamoDB processed-events table
- DynamoDB TTL configuration

### Processor Module

The processor module provisions resources including:

- EventBridge rule and SQS target
- SQS ingestion queue
- SQS dead-letter queue
- SQS redrive configuration
- EventBridge-to-SQS queue policy
- Lambda processor
- Lambda IAM permissions
- SQS-to-Lambda event-source mapping
- CloudWatch log group
- CloudWatch alarms

## Terragrunt

Terragrunt orchestrates the Terraform modules and passes outputs between infrastructure layers.

The development environment is organized under:

```text
live/
└── dev/
    ├── storage/
    └── processor/
```

The processor configuration depends on outputs produced by the storage configuration, allowing resources such as the S3 bucket and DynamoDB table to be referenced without manually duplicating their values.

## Repository Structure

```text
.
├── docs/
├── live/
│   ├── root.hcl
│   └── dev/
│       ├── storage/
│       └── processor/
├── modules/
│   ├── storage/
│   └── processor/
├── samples/
│   └── validation/
├── src/
│   └── process-event/
├── unit-tests/
│   └── process-event.test.ts
├── package.json
├── tsconfig.json
└── tsconfig.test.json
```

## Testing

### TypeScript

Validate the production Lambda source:

```bash
npx tsc --noEmit
```

Validate the source and unit tests:

```bash
npx tsc --noEmit -p tsconfig.test.json
```

### Unit Tests

Run the Vitest suite:

```bash
npm test
```

The processor test suite covers:

1. successful processing of a valid event;
2. rejection of S3 objects larger than 64 KiB;
3. rejection of an invalid event contract;
4. idempotent handling of duplicate DynamoDB events; and
5. partial failure behavior for a mixed SQS batch.

### Terraform

Check formatting:

```bash
terraform fmt -check -recursive
```

Run module validation and native Terraform tests:

```bash
cd modules/storage
terraform validate
terraform test

cd ../processor
terraform validate
terraform test
```

### Terragrunt

Check Terragrunt formatting:

```bash
terragrunt hcl fmt --check
```

A final plan can be run from the development environment to detect configuration drift:

```bash
cd live/dev
terragrunt run --all plan
```

## Live AWS Validation

The deployed development environment was validated against AWS using several end-to-end scenarios.

### Valid Event

A valid S3-backed event was processed successfully and persisted to DynamoDB.

### Mixed Valid and Invalid Processing

Valid and invalid records were processed through the deployed SQS/Lambda integration.

The valid event was persisted successfully while the invalid event was independently retried and ultimately moved to the DLQ.

This validated the `ReportBatchItemFailures` implementation and demonstrated that one bad record does not force successful records in the same batch to be retried.

### Duplicate Event

An event with an `event_id` already stored in DynamoDB was delivered again.

The conditional DynamoDB write rejected the duplicate, and the Lambda logged:

```text
Event validation-mixed-valid-001 already exists in DynamoDB; treating duplicate as successful no-op.
```

The SQS message was successfully consumed rather than retried or sent to the DLQ.

### Monitoring

The deployed CloudWatch alarms were inspected after validation.

During DLQ testing, the DLQ message alarm entered the `ALARM` state while the remaining alarms stayed healthy, providing live validation of the monitoring configuration.

## Design Decisions

### Why SQS Between EventBridge and Lambda?

SQS decouples event production from processing. It provides buffering, retries, visibility timeouts, batch processing, and dead-letter handling instead of requiring Lambda to process every event immediately as it arrives.

### Why Conditional DynamoDB Writes?

Checking whether an item exists before writing it would introduce a race condition between the read and write.

Using a conditional `PutItem` makes the idempotency decision atomic.

### Why Partial Batch Responses?

Without partial batch responses, one failed record can cause successfully processed records from the same SQS batch to be retried.

Returning only failed message identifiers reduces unnecessary work while preserving retry behavior for actual failures.

### Why Terragrunt?

Terragrunt provides an environment-oriented orchestration layer around reusable Terraform modules. In this project it manages the development environment and wires storage outputs into the processor infrastructure without duplicating resource identifiers manually.

## Cost Considerations

The project intentionally uses serverless and usage-based AWS services suitable for a small learning and portfolio workload.

The core architecture avoids additional infrastructure such as NAT Gateways, VPC endpoints, dashboards, SNS topics, and X-Ray.

AWS resources may still incur charges while deployed. Destroy resources when they are no longer needed.

## Cleanup

When the deployed environment is no longer required, destroy the Terragrunt-managed development infrastructure rather than manually deleting individual Terraform-managed resources.

Review the destroy plan before confirming removal.

## Key Technologies

- AWS S3
- Amazon EventBridge
- Amazon SQS
- AWS Lambda
- Amazon DynamoDB
- Amazon CloudWatch
- AWS IAM
- Terraform
- Terragrunt
- TypeScript
- Node.js 22
- Vitest