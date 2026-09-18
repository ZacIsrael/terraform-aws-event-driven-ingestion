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

## Demo Walkthrough

This walkthrough demonstrates the deployed ingestion pipeline end to end.

The demo verifies three important behaviors:

1. **Happy path** — a valid JSON event is uploaded to S3 and ultimately persisted to DynamoDB.
2. **Idempotency** — the same logical event is delivered again without creating a duplicate DynamoDB item.
3. **Failure handling** — an invalid event is retried and eventually moved to the SQS dead-letter queue.

The end-to-end path being demonstrated is:

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
    ▼
AWS Lambda
    │
    ├── S3 GetObject
    ├── JSON parsing
    ├── event-contract validation
    └── conditional DynamoDB write
    │
    ▼
Amazon DynamoDB
```

> **Important:** This walkthrough creates AWS resources that may incur charges. Destroy the environment after completing the demo.

### Prerequisites

Before starting, ensure the following tools are installed:

- AWS CLI
- Terraform
- Terragrunt
- Node.js and npm
- Git

AWS credentials must also be configured for an account with permission to create the resources used by the project.

Verify the active AWS identity:

```bash
aws sts get-caller-identity
```

**Purpose:** Confirms which AWS account and IAM identity will be used for the deployment.

---

### Step 1 — Clone the Repository

Clone the repository:

```bash
git clone https://github.com/ZacIsrael/terraform-aws-event-driven-ingestion.git
```

Enter the project directory:

```bash
cd terraform-aws-event-driven-ingestion
```

Install the Node.js dependencies:

```bash
npm ci
```

**Purpose:** Creates a local copy of the project and installs the dependencies required to build and test the TypeScript Lambda processor.

---

### Step 2 — Validate the Project Locally

Validate the production TypeScript source:

```bash
npx tsc --noEmit
```

Validate the source and unit tests:

```bash
npx tsc --noEmit -p tsconfig.test.json
```

Run the processor unit tests:

```bash
npm test
```

Check Terraform formatting:

```bash
terraform fmt -check -recursive
```

Check Terragrunt formatting:

```bash
terragrunt hcl fmt --check
```

**Purpose:** Verifies the application code, tests, Terraform configuration, and Terragrunt configuration before any AWS resources are created.

---

### Step 3 — Review the Infrastructure Plan

Move into the development environment:

```bash
cd live/dev
```

Run a Terragrunt plan across the environment:

```bash
terragrunt run --all plan
```

**Purpose:** Shows the AWS resources Terraform intends to create before anything is deployed.

Terragrunt orchestrates the two infrastructure layers:

```text
storage
   │
   │ outputs
   ▼
processor
```

The processor layer depends on outputs from the storage layer, allowing resources such as the S3 bucket and DynamoDB table to be referenced without manually duplicating their identifiers.

Review the plan before continuing.

---

### Step 4 — Deploy the Development Environment

Deploy the infrastructure:

```bash
terragrunt run --all apply
```

Review the proposed changes and approve the apply when prompted.

**Purpose:** Provisions the AWS infrastructure required for the ingestion pipeline, including:

- S3 ingestion bucket
- DynamoDB processed-events table
- EventBridge rule
- SQS ingestion queue
- SQS dead-letter queue
- Lambda processor
- IAM permissions
- CloudWatch log group
- CloudWatch alarms

---

### Step 5 — Inspect the Deployment Outputs

Inspect the storage outputs:

```bash
cd storage
terragrunt output
```

Inspect the processor outputs:

```bash
cd ../processor
terragrunt output
```

Record the deployed resource identifiers needed for the demo, particularly:

- S3 ingestion bucket name
- DynamoDB table name
- SQS queue URL
- SQS dead-letter queue URL
- Lambda function name
- Lambda CloudWatch log group

Return to the repository root:

```bash
cd ../../..
```

**Purpose:** Retrieves the names and URLs of the resources created by Terraform so they can be used during the end-to-end validation.

---

## Happy-Path Demo

### Step 6 — Create a Valid Event

Create a valid event:

```bash
cat > /tmp/valid-event.json <<'EOF'
{
  "event_id": "demo-valid-001",
  "event_type": "customer.created",
  "occurred_at": "2026-09-18T12:00:00Z",
  "source": "demo",
  "payload": {
    "customer_id": "123"
  }
}
EOF
```

Inspect the event:

```bash
cat /tmp/valid-event.json
```

**Purpose:** Creates a JSON object that satisfies the event contract expected by the Lambda processor.

---

### Step 7 — Upload the Valid Event to S3

Upload the event beneath the required `incoming/` prefix:

```bash
aws s3 cp /tmp/valid-event.json s3://<INGESTION_BUCKET>/incoming/demo-valid-001.json
```

Replace `<INGESTION_BUCKET>` with the bucket name returned by the storage outputs.

**Purpose:** Starts the event-driven pipeline.

The upload causes the following sequence:

```text
S3 Object Created
       │
       ▼
EventBridge
       │
       ▼
SQS
       │
       ▼
Lambda
       │
       ├── retrieves the S3 object
       ├── parses the JSON
       ├── validates the event contract
       └── performs a conditional DynamoDB write
       │
       ▼
DynamoDB
```

No Lambda invocation is performed manually. Uploading the object to S3 initiates the workflow.

---

### Step 8 — Verify the DynamoDB Item

Query DynamoDB for the event:

```bash
aws dynamodb get-item \
  --table-name <PROCESSED_EVENTS_TABLE> \
  --key '{"event_id":{"S":"demo-valid-001"}}'
```

Replace `<PROCESSED_EVENTS_TABLE>` with the deployed DynamoDB table name.

**Purpose:** Confirms that the valid event successfully traveled through S3 → EventBridge → SQS → Lambda and was persisted to DynamoDB.

A returned item for `demo-valid-001` confirms successful end-to-end processing.

---

### Step 9 — Inspect the Lambda Logs

Tail the Lambda logs:

```bash
aws logs tail <LAMBDA_LOG_GROUP> --since 10m
```

Replace `<LAMBDA_LOG_GROUP>` with the deployed Lambda log group.

**Purpose:** Provides operational evidence of the Lambda processing the event.

The processor uses structured CloudWatch logging, allowing processing activity and failures to be inspected without modifying the application.

---

## Idempotency Demo

### Step 10 — Deliver the Same Logical Event Again

Upload the same JSON event under a different S3 object key:

```bash
aws s3 cp /tmp/valid-event.json s3://<INGESTION_BUCKET>/incoming/demo-valid-001-duplicate.json
```

**Purpose:** Simulates duplicate delivery.

Although the S3 object key is different, the event still contains:

```text
event_id = demo-valid-001
```

The processor therefore attempts another conditional DynamoDB write using:

```text
attribute_not_exists(event_id)
```

Because `demo-valid-001` already exists, DynamoDB rejects the duplicate conditional write.

The Lambda recognizes the conditional-check failure as an already-processed event and treats it as a successful no-op.

---

### Step 11 — Verify the Duplicate Behavior

Query the event again:

```bash
aws dynamodb get-item \
  --table-name <PROCESSED_EVENTS_TABLE> \
  --key '{"event_id":{"S":"demo-valid-001"}}'
```

**Purpose:** Confirms that duplicate delivery did not create another logical event or overwrite the existing item.

Inspect the Lambda logs:

```bash
aws logs tail <LAMBDA_LOG_GROUP> --since 10m
```

The logs should indicate that the event already exists in DynamoDB and is being treated as a successful no-op.

The expected behavior is:

```text
Duplicate delivery
       │
       ▼
Lambda processes event
       │
       ▼
Conditional PutItem
       │
       ▼
event_id already exists
       │
       ▼
Successful no-op
       │
       ▼
SQS message consumed
```

The duplicate is not retried and is not sent to the DLQ.

---

## Failure and DLQ Demo

### Step 12 — Create an Invalid Event

Create an event that violates the required event contract:

```bash
cat > /tmp/invalid-event.json <<'EOF'
{
  "event_id": "demo-invalid-001",
  "event_type": "customer.created",
  "occurred_at": "2026-09-18T12:05:00Z",
  "source": "demo"
}
EOF
```

Inspect the event:

```bash
cat /tmp/invalid-event.json
```

**Purpose:** Creates an intentionally invalid event by omitting the required `payload` field.

---

### Step 13 — Upload the Invalid Event

Upload the invalid event:

```bash
aws s3 cp /tmp/invalid-event.json s3://<INGESTION_BUCKET>/incoming/demo-invalid-001.json
```

**Purpose:** Demonstrates how the pipeline handles a poison event that reaches the Lambda but fails event-contract validation.

The event still travels through:

```text
S3
 │
 ▼
EventBridge
 │
 ▼
SQS
 │
 ▼
Lambda
```

The Lambda retrieves the referenced S3 object but rejects it during contract validation.

---

### Step 14 — Observe the Failure

Tail the Lambda logs:

```bash
aws logs tail <LAMBDA_LOG_GROUP> --since 10m --follow
```

**Purpose:** Shows the invalid event being rejected during processing.

Stop following the logs when finished:

```bash
Ctrl+C
```

The failed SQS record is returned through the Lambda partial-batch response rather than being acknowledged as successfully processed.

Because the ingestion queue uses:

```text
maxReceiveCount = 5
```

the message can become visible again and be retried.

After repeatedly failing processing, SQS moves the message to the dead-letter queue.

---

### Step 15 — Verify the Dead-Letter Queue

Receive messages from the DLQ:

```bash
aws sqs receive-message \
  --queue-url <DLQ_URL> \
  --max-number-of-messages 10 \
  --attribute-names All \
  --message-attribute-names All
```

Replace `<DLQ_URL>` with the deployed dead-letter queue URL.

**Purpose:** Confirms that a repeatedly failing event is eventually isolated in the DLQ instead of retrying indefinitely in the primary ingestion queue.

The failure path is:

```text
Invalid event
     │
     ▼
Lambda validation failure
     │
     ▼
Failed SQS record returned
     │
     ▼
SQS retry
     │
     ▼
Repeated processing failures
     │
     ▼
Dead-Letter Queue
```

> The message will not appear in the DLQ immediately. It must first exceed the configured receive threshold.

---

## Observability Demo

### Step 16 — Inspect the CloudWatch Alarms

List the CloudWatch alarms:

```bash
aws cloudwatch describe-alarms \
  --query "MetricAlarms[].[AlarmName,StateValue,MetricName]" \
  --output table
```

**Purpose:** Displays the operational alarms provisioned by the project and their current states.

The project monitors:

- Lambda errors
- Lambda throttles
- SQS oldest-message age
- Visible DLQ messages

During DLQ testing, the DLQ message alarm may enter the `ALARM` state after CloudWatch evaluates the corresponding metric.

---

## What the Demo Proves

After completing the walkthrough, the following behaviors have been demonstrated against the deployed AWS environment:

1. An S3 object upload can initiate the pipeline without directly invoking Lambda.
2. EventBridge routes matching S3 Object Created events into SQS.
3. SQS decouples event arrival from Lambda processing.
4. Lambda retrieves the referenced S3 object and validates its event contract.
5. Valid events are persisted to DynamoDB.
6. Conditional DynamoDB writes provide idempotent duplicate handling.
7. Duplicate events are treated as successful no-ops rather than failures.
8. Invalid events remain retryable instead of being acknowledged as successful.
9. Repeatedly failing messages are eventually isolated in the DLQ.
10. CloudWatch logs provide visibility into Lambda processing.
11. CloudWatch alarms provide operational visibility into errors, throttling, queue backlog, and DLQ activity.
12. Terragrunt orchestrates the Terraform modules and passes storage outputs into the processor infrastructure.

---

## Demo Teardown

### Step 17 — Empty the Demo S3 Bucket

Before destroying the infrastructure, remove the demo objects from the ingestion bucket:

```bash
aws s3 rm s3://<INGESTION_BUCKET> --recursive
```

**Purpose:** Ensures objects created during the demo do not prevent Terraform from deleting the S3 bucket.

---

### Step 18 — Review the Destroy Plan

Return to the development environment:

```bash
cd live/dev
```

Review the resources that will be destroyed:

```bash
terragrunt run --all plan -destroy
```

**Purpose:** Shows which Terraform-managed AWS resources will be removed before any destructive action occurs.

Review the plan before continuing.

---

### Step 19 — Destroy the AWS Environment

Destroy the development environment:

```bash
terragrunt run --all destroy
```

Review the proposed changes and confirm the destroy operation when prompted.

**Purpose:** Removes the AWS resources managed by the Terragrunt development environment instead of manually deleting individual Terraform-managed resources.

---

### Step 20 — Verify Teardown

Verify that the ingestion bucket no longer exists:

```bash
aws s3api head-bucket --bucket <INGESTION_BUCKET>
```

After successful teardown, AWS should report that the bucket does not exist or is no longer accessible.

**Purpose:** Provides a final confirmation that the demo environment has been removed.

The end-to-end demonstration is now complete.

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