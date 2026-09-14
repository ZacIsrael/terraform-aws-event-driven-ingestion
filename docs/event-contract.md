# JSON Event Contract

## Overview

The Resilient Event-Driven Ingestion Pipeline accepts small JSON event files from authorized external systems.

External producers upload event files to the private Amazon S3 ingestion bucket. Only JSON objects uploaded under the `incoming/` prefix with a `.json` file extension are eligible to trigger processing.

Each event must conform to the common event envelope defined in this document. The envelope provides consistent metadata for identification, classification, timing, and source attribution while allowing the contents of `payload` to vary based on the producing system and event type.

## Event Structure

A valid event follows this structure:

```json
{
  "event_id": "evt-20260914-0001",
  "event_type": "customer.created",
  "occurred_at": "2026-09-14T12:00:00Z",
  "source": "crm-system",
  "payload": {
    "customer_id": "cust-12345",
    "status": "active"
  }
}
```

## Field Requirements

| Field | Type | Required | Requirements |
| --- | --- | --- | --- |
| `event_id` | string | Yes | Must be nonempty, unique to the event, and reasonably length-limited. |
| `event_type` | string | Yes | Must be nonempty and follow the documented event-type naming convention. |
| `occurred_at` | string | Yes | Must contain a valid ISO 8601 timestamp. |
| `source` | string | Yes | Must be nonempty and identify the system that produced the event. |
| `payload` | object | Yes | Must be a JSON object. Its contents may vary according to the producer and `event_type`. |

## `event_id`

`event_id` uniquely identifies an event.

Example:

```json
"event_id": "evt-20260914-0001"
```

The value must:

- be present;
- be a string;
- be nonempty;
- remain within the documented maximum length; and
- uniquely identify the event.

The ingestion pipeline can use this identifier as part of its idempotency strategy so that repeated delivery or processing of the same event does not create duplicate records.

## `event_type`

`event_type` identifies the type of business event represented by the file.

Example:

```json
"event_type": "customer.created"
```

Event types use the following naming convention:

```text
<entity>.<action>
```

Examples include:

```text
customer.created
customer.updated
order.completed
payment.received
```

Event-type names should use lowercase characters and clearly communicate the entity and action represented by the event.

Different producers may submit different event types as long as each event follows the common event envelope defined by this contract.

## `occurred_at`

`occurred_at` identifies when the event occurred in the producing system.

Example:

```json
"occurred_at": "2026-09-14T12:00:00Z"
```

The value must:

- be present;
- be a string; and
- contain a valid ISO 8601 timestamp.

UTC timestamps using the `Z` designator are preferred when producers can provide them.

The event occurrence time is distinct from the time at which the object is uploaded to Amazon S3 or processed by the ingestion pipeline.

## `source`

`source` identifies the external system that produced the event.

Example:

```json
"source": "crm-system"
```

The value must:

- be present;
- be a string; and
- be nonempty.

Different external systems may use different source identifiers. The identifier should remain stable for a given producing system so that downstream consumers can reliably determine an event's origin.

## `payload`

`payload` contains the business data associated with the event.

Example:

```json
"payload": {
  "customer_id": "cust-12345",
  "status": "active"
}
```

The value must:

- be present; and
- be a JSON object.

The contents of `payload` are intentionally event-specific. Different producers and event types may supply different payload fields while continuing to use the same common event envelope.

For example, a `customer.created` event and an `order.completed` event may contain completely different payload structures.

The complete payload must never be written to application logs.

## Object Size Limit

Each uploaded event object must not exceed **64 KB**.

The size restriction keeps the ingestion workload intentionally small and places a clear boundary on the objects accepted by the pipeline.

Objects that exceed the supported size limit must not be processed as valid ingestion events.

## S3 Object Requirements

Event files are uploaded to the private Amazon S3 ingestion bucket.

Only objects matching the following key pattern are eligible to trigger the ingestion pipeline:

```text
incoming/*.json
```

Examples of eligible object keys include:

```text
incoming/event-001.json
incoming/customer-created-001.json
incoming/order-completed-001.json
```

Objects outside the `incoming/` prefix or objects without the `.json` extension must not trigger normal event processing.

Examples that should not trigger processing include:

```text
archive/event-001.json
incoming/event-001.txt
event-001.json
```

## Processing Flow

A valid event moves through the following pipeline:

```text
Authorized Producer
        |
        v
Private S3 Bucket
        |
        | Object Created
        v
EventBridge Rule
        |
        | Matched Event
        v
SQS Ingestion Queue
        |
        | Batch of Messages
        v
Ingestion Lambda
        |
        +----> S3 GetObject
        |
        +----> DynamoDB Conditional PutItem
```

The S3 Object Created event does not contain the application event itself as the authoritative business payload. Instead, the AWS event notification identifies the uploaded S3 object.

The ingestion Lambda uses the object information from the event notification to retrieve the JSON event file from S3 with `GetObject`. The retrieved document is then validated and processed according to this contract.

## Validation Expectations

Before treating an uploaded document as a valid event, the ingestion application must verify that:

1. The object is within the supported size limit.
2. The object contains valid JSON.
3. The top-level JSON value is an object.
4. `event_id` is present, nonempty, and within the supported length limit.
5. `event_type` is present and follows the documented naming convention.
6. `occurred_at` contains a valid ISO 8601 timestamp.
7. `source` is present and nonempty.
8. `payload` is present and is a JSON object.

An event that violates the contract must not be treated as successfully ingested.

## Idempotency

The pipeline must tolerate duplicate delivery.

`event_id` provides the stable event identifier used by the ingestion process to distinguish an already-processed event from a new event.

DynamoDB conditional writes are used by the ingestion application to prevent duplicate processing from creating duplicate records.

This is necessary because components in an event-driven architecture, including Amazon SQS, can provide at-least-once delivery behavior.

## Retry Behavior

The ingestion Lambda processes messages from the SQS ingestion queue through a Lambda event source mapping.

When a message is processed successfully, the Lambda event source mapping deletes the message from the source queue.

If processing fails, the message is not deleted. After the SQS visibility timeout expires, the message becomes visible in the ingestion queue and is eligible to be received and processed again.

The ingestion queue uses a redrive policy with `maxReceiveCount = 5`. A message may therefore be received from the source queue up to five times: one initial processing attempt and up to four retry attempts.

After five unsuccessful receives, SQS redrives the message from the ingestion queue to the configured dead-letter queue (DLQ) rather than continuing normal processing attempts.

## Partial-Batch Behavior

The ingestion Lambda processes messages from the SQS ingestion queue in batches.

Partial-batch failure handling is enabled so that a failure affecting one message does not require successfully processed messages in the same batch to be retried.

When individual messages fail processing, the Lambda function reports those messages as batch item failures. Successfully processed messages are treated as complete, while only the failed messages are returned to the ingestion queue for retry.

This behavior reduces unnecessary duplicate processing while preserving SQS retry behavior for messages that could not be processed successfully.

An unexpected failure that prevents the Lambda function from correctly processing or reporting the batch is treated as a batch-level invocation failure and must be observable through monitoring and alarms.

## DLQ Behavior

The SQS ingestion queue is configured with a dead-letter queue (DLQ) to isolate messages that repeatedly fail processing.

The ingestion queue uses a redrive policy with `maxReceiveCount = 5`. A failed message may therefore be received from the source queue up to five times before it is redriven to the DLQ.

Messages placed in the DLQ are not treated as successfully processed events. They are retained for investigation and troubleshooting rather than being continuously retried through the normal ingestion path.

Examples of messages that may eventually reach the DLQ include malformed JSON, events that fail schema validation, references to missing S3 objects, and messages affected by failures that persist across all permitted processing attempts.

The DLQ provides an operational boundary for poison messages and persistent failures so that they do not continuously interfere with normal ingestion processing.

## Failure Classification

The ingestion handler distinguishes between the following processing outcomes and failure categories:

| Category | Behavior |
| --- | --- |
| Valid new event | The event is conditionally stored in DynamoDB and processing succeeds. |
| Duplicate event | The existing record is not overwritten. The duplicate is treated as a successful no-op. |
| Malformed JSON or invalid schema | The message fails processing and is eligible for retry. If the failure persists through the configured receive limit, the message is eventually redriven to the DLQ. |
| Missing S3 object | The message fails processing. |
| Transient AWS SDK failure | The message fails processing and is returned to the ingestion queue for retry. |
| Unexpected batch-level failure | The Lambda invocation fails and the failure must be observable through monitoring and an alarm. |

A valid new event and a duplicate event are both successful processing outcomes. The remaining categories represent failures that require retry handling, DLQ handling, or operational visibility depending on the nature and persistence of the failure.

## Logging Requirements

Application logs must never contain the complete event payload.

Logs should contain only the metadata necessary for troubleshooting and observability, such as:

- `event_id`;
- `event_type`;
- `source`;
- processing outcome;
- validation outcome;
- relevant non-sensitive operational metadata.

The application must not log the complete `payload` object.

This restriction reduces the risk of business, confidential, or otherwise sensitive producer data being unnecessarily copied into CloudWatch Logs.

## Producer Responsibilities

An external producer is responsible for:

1. Producing valid JSON.
2. Following the common event envelope.
3. Supplying all required fields.
4. Providing a unique, nonempty `event_id`.
5. Using the documented `event_type` naming convention.
6. Providing a valid ISO 8601 `occurred_at` timestamp.
7. Identifying itself through `source`.
8. Supplying `payload` as a JSON object.
9. Keeping the complete event file within the 64 KB size limit.
10. Uploading the event as an `incoming/*.json` object.

Events that do not satisfy these requirements are outside the supported event contract.