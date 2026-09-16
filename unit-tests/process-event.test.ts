import { Buffer } from "node:buffer";
import process from "node:process";

import { describe, it, expect, vi } from "vitest";
import type { SQSEvent } from "aws-lambda";
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
  const actual = await importOriginal<typeof import("@aws-sdk/lib-dynamodb")>();

  return {
    ...actual,
    DynamoDBDocumentClient: {
      from: vi.fn(() => ({
        send: mockDynamoDBSend,
      })),
    },
  };
});

describe("process-event Lambda", () => {
  // Verify the complete successful processing path for one SQS message.
  // A valid event should be stored without producing a batch failure.
  it("returns no batch failures for a valid event", async () => {
    // Arrange

    // Simulate the DynamoDB table name Terraform provides to the Lambda.
    // Unit tests must provide this because no deployed Lambda exists.
    process.env.DYNAMODB_TABLE_NAME = "test-events";

    // Mock the application event stored as JSON inside the S3 ingestion bucket.
    // This is the actual event that the processor retrieves and validates.
    const mockS3Event = {
      event_id: "evt-20260916-0001",
      event_type: "customer.created",
      occurred_at: "2026-09-16T18:00:00Z",
      source: "crm-system",
      payload: {
        customer_id: "cust-12345",
        status: "active",
      },
    };

    // Convert the application event to the JSON string returned from S3.
    // The processor later converts this string back into an object.
    const mockS3ObjectData = JSON.stringify(mockS3Event);

    // Mock a successful S3 GetObject response.
    // Include the byte size and streaming body expected by the processor.
    mockS3Send.mockResolvedValue({
      ContentLength: Buffer.byteLength(mockS3ObjectData, "utf8"),
      Body: {
        transformToString: vi.fn().mockResolvedValue(mockS3ObjectData),
      },
    });

    // Mock a successful DynamoDB conditional write.
    // No response data is required because the processor only needs success.
    mockDynamoDBSend.mockResolvedValue({});

    // Mock the EventBridge notification generated for the new S3 object.
    // Its bucket name and object key tell the processor what to retrieve.
    const mockEventBridgeEvent = {
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
          key: "incoming/valid-event.json",

          // Include realistic EventBridge metadata for the S3 object's size.
          size: Buffer.byteLength(mockS3ObjectData, "utf8"),
        },

        reason: "PutObject",
      },
    };

    // Mock the SQS batch delivered to the Lambda handler.
    // Its message body contains the serialized EventBridge notification.
    const mockSQSEvent: SQSEvent = {
      Records: [
        {
          messageId: "test-message-id",
          receiptHandle: "test-receipt-handle",

          // SQS message bodies are strings, so serialize the EventBridge event.
          body: JSON.stringify(mockEventBridgeEvent),

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
        },
      ],
    };

    // Act

    // Execute the real Lambda handler with the mocked SQS event.
    // Only its external S3 and DynamoDB interactions have been replaced.
    const result = await handler(mockSQSEvent);

    // Assert

    // A successfully processed message should not be reported as failed.
    // An empty array tells Lambda that the entire SQS batch succeeded.
    expect(result.batchItemFailures).toEqual([]);
  });
});
