import { Buffer } from "node:buffer";
import process from "node:process";

import { beforeEach, describe, expect, it, vi } from "vitest";
import type { SQSEvent, SQSRecord } from "aws-lambda";
import { handler } from "../src/process-event/index.js";

// Mock the AWS SDK send methods so tests never contact real AWS services.
// Each test controls what S3 and DynamoDB return through these functions.
const mockS3Send = vi.fn();
const mockDynamoDBSend = vi.fn();

// Replace the real S3 client while preserving exports such as GetObjectCommand.
// Calls to s3Client.send() are redirected to mockS3Send.
vi.mock("@aws-sdk/client-s3", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@aws-sdk/client-s3")>();

  return {
    ...actual,
    S3Client: vi.fn(function () {
      return {
        send: mockS3Send,
      };
    }),
  };
});

// Replace the low-level DynamoDB client so no real AWS client is created.
// The processor will still wrap this client with DynamoDBDocumentClient.
vi.mock("@aws-sdk/client-dynamodb", async (importOriginal) => {
  const actual = await importOriginal<
    typeof import("@aws-sdk/client-dynamodb")
  >();

  return {
    ...actual,
    DynamoDBClient: vi.fn(function () {
      return {};
    }),
  };
});

// Replace DynamoDBDocumentClient with a mock document client.
// Calls to its send() method are redirected to mockDynamoDBSend.
vi.mock("@aws-sdk/lib-dynamodb", async (importOriginal) => {
  const actual =
    await importOriginal<typeof import("@aws-sdk/lib-dynamodb")>();

  return {
    ...actual,
    DynamoDBDocumentClient: {
      from: vi.fn(() => ({
        send: mockDynamoDBSend,
      })),
    },
  };
});

// Create a valid application event matching the project's event contract.
// Individual tests can override fields to create invalid scenarios.
const createApplicationEvent = (overrides = {}) => ({
  event_id: "evt-20260916-0001",
  event_type: "customer.created",
  occurred_at: "2026-09-16T18:00:00Z",
  source: "crm-system",
  payload: {
    customer_id: "cust-12345",
    status: "active",
  },
  ...overrides,
});

// Create the EventBridge notification that identifies an S3 object.
// The processor extracts the bucket name and object key from this structure.
const createEventBridgeEvent = (
  objectKey = "incoming/valid-event.json",
) => ({
  version: "0",
  id: "test-event-id",
  "detail-type": "Object Created",
  source: "aws.s3",
  account: "123456789012",
  time: "2026-09-16T18:00:00Z",
  region: "us-east-1",
  resources: ["arn:aws:s3:::test-ingestion-bucket"],
  detail: {
    bucket: {
      name: "test-ingestion-bucket",
    },
    object: {
      key: objectKey,
      size: 180,
    },
    reason: "PutObject",
  },
});

// Create one SQS record containing a serialized EventBridge notification.
// The message ID can be changed to identify records in batch-response tests.
const createSQSRecord = (
  messageId = "test-message-id",
  objectKey = "incoming/valid-event.json",
): SQSRecord => ({
  messageId,
  receiptHandle: `receipt-${messageId}`,
  body: JSON.stringify(createEventBridgeEvent(objectKey)),
  attributes: {
    ApproximateReceiveCount: "1",
    SentTimestamp: "1758045600000",
    SenderId: "test-sender",
    ApproximateFirstReceiveTimestamp: "1758045600000",
  },
  messageAttributes: {},
  md5OfBody: "test-md5",
  eventSource: "aws:sqs",
  eventSourceARN:
    "arn:aws:sqs:us-east-1:123456789012:event-processing-queue",
  awsRegion: "us-east-1",
});

// Create the S3 GetObject response consumed by the processor.
// ContentLength reflects the UTF-8 byte size of the supplied object data.
const createS3Response = (objectData: string) => ({
  ContentLength: Buffer.byteLength(objectData, "utf8"),
  Body: {
    transformToString: vi.fn().mockResolvedValue(objectData),
  },
});

describe("process-event Lambda", () => {
  beforeEach(() => {
    // Reset call history and mock behavior so tests remain independent.
    // Also provide the DynamoDB table name normally configured by Terraform.
    vi.clearAllMocks();
    process.env.DYNAMODB_TABLE_NAME = "test-events";
  });

  it("returns no batch failures for a valid event", async () => {
    // Arrange
    // Create a valid S3 application event and successful AWS responses.
    const mockS3ObjectData = JSON.stringify(createApplicationEvent());

    mockS3Send.mockResolvedValue(createS3Response(mockS3ObjectData));
    mockDynamoDBSend.mockResolvedValue({});

    // Mock the SQS batch delivered to the Lambda handler.
    // Its body contains the serialized EventBridge notification.
    const mockSQSEvent: SQSEvent = {
      Records: [createSQSRecord()],
    };

    // Act
    // Execute the real handler while S3 and DynamoDB use mocked responses.
    const result = await handler(mockSQSEvent);

    // Assert
    // A successfully processed record should produce no batch failures.
    expect(result.batchItemFailures).toEqual([]);
  });

  it("returns a batch failure when the S3 object exceeds 64 KiB", async () => {
    // Arrange
    // Simulate S3 metadata reporting an object larger than the 64 KiB limit.
    mockS3Send.mockResolvedValue({
      ContentLength: 64 * 1024 + 1,
      Body: {
        transformToString: vi.fn(),
      },
    });

    const mockSQSEvent: SQSEvent = {
      Records: [createSQSRecord("oversized-message")],
    };

    // Act
    // Execute the handler with the oversized S3 object response.
    const result = await handler(mockSQSEvent);

    // Assert
    // The oversized SQS record should be returned as a partial-batch failure.
    expect(result.batchItemFailures).toEqual([
      {
        itemIdentifier: "oversized-message",
      },
    ]);

    // Processing should stop before DynamoDB because the object is invalid.
    expect(mockDynamoDBSend).not.toHaveBeenCalled();
  });

  it("returns a batch failure when the event contract is invalid", async () => {
    // Arrange
    // Use an invalid event_type that violates the required naming pattern.
    const invalidEvent = createApplicationEvent({
      event_type: "INVALID EVENT TYPE",
    });

    const mockS3ObjectData = JSON.stringify(invalidEvent);

    mockS3Send.mockResolvedValue(createS3Response(mockS3ObjectData));

    const mockSQSEvent: SQSEvent = {
      Records: [createSQSRecord("invalid-contract-message")],
    };

    // Act
    // Execute the handler with an application event that fails validation.
    const result = await handler(mockSQSEvent);

    // Assert
    // Contract validation failure should identify only this SQS message.
    expect(result.batchItemFailures).toEqual([
      {
        itemIdentifier: "invalid-contract-message",
      },
    ]);

    // Invalid application data must never be written to DynamoDB.
    expect(mockDynamoDBSend).not.toHaveBeenCalled();
  });

  it("treats a duplicate DynamoDB event as a successful no-op", async () => {
    // Arrange
    // Provide a valid application event so processing reaches DynamoDB.
    const mockS3ObjectData = JSON.stringify(createApplicationEvent());

    mockS3Send.mockResolvedValue(createS3Response(mockS3ObjectData));

    // Simulate DynamoDB rejecting the conditional PutCommand for a duplicate.
    // The processor should treat this expected exception as idempotent success.
    const duplicateError = new Error("Event already exists");
    duplicateError.name = "ConditionalCheckFailedException";

    mockDynamoDBSend.mockRejectedValue(duplicateError);

    const mockSQSEvent: SQSEvent = {
      Records: [createSQSRecord("duplicate-message")],
    };

    // Act
    // Execute the handler with a duplicate event already stored in DynamoDB.
    const result = await handler(mockSQSEvent);

    // Assert
    // Duplicate delivery is successful because the desired state already exists.
    expect(result.batchItemFailures).toEqual([]);

    // Confirm that the processor actually attempted the DynamoDB operation.
    expect(mockDynamoDBSend).toHaveBeenCalled();
  });

  it("returns only failed message IDs when processing a mixed SQS batch", async () => {
    // Arrange
    // Create valid application data for the first and third SQS messages.
    const validEventOne = JSON.stringify(
      createApplicationEvent({
        event_id: "evt-20260916-0001",
      }),
    );

    const invalidEvent = JSON.stringify(
      createApplicationEvent({
        event_id: "evt-20260916-0002",
        event_type: "INVALID EVENT TYPE",
      }),
    );

    const validEventTwo = JSON.stringify(
      createApplicationEvent({
        event_id: "evt-20260916-0003",
      }),
    );

    // Return a different S3 object for each SQS record in processing order.
    // The middle object is invalid while the first and third are valid.
    mockS3Send
      .mockResolvedValueOnce(createS3Response(validEventOne))
      .mockResolvedValueOnce(createS3Response(invalidEvent))
      .mockResolvedValueOnce(createS3Response(validEventTwo));

    // Both valid records should complete their conditional DynamoDB writes.
    mockDynamoDBSend.mockResolvedValue({});

    const mockSQSEvent: SQSEvent = {
      Records: [
        createSQSRecord(
          "successful-message-1",
          "incoming/valid-event-1.json",
        ),
        createSQSRecord(
          "failed-message",
          "incoming/invalid-event.json",
        ),
        createSQSRecord(
          "successful-message-2",
          "incoming/valid-event-2.json",
        ),
      ],
    };

    // Act
    // Execute all three records through the same Lambda invocation.
    const result = await handler(mockSQSEvent);

    // Assert
    // Partial-batch processing should retry only the invalid SQS record.
    expect(result.batchItemFailures).toEqual([
      {
        itemIdentifier: "failed-message",
      },
    ]);

    // The two valid records should still reach DynamoDB successfully.
    expect(mockDynamoDBSend).toHaveBeenCalledTimes(2);
  });
});