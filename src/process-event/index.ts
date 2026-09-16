import type {
  SQSEvent,
  SQSBatchResponse,
  SQSBatchItemFailure,
} from "aws-lambda";
import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";

import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";

export const handler = async (event: SQSEvent): Promise<SQSBatchResponse> => {
  // Log the incoming SQS event for debugging.
  console.log("event = ", event);

  // Track SQS messages that fail processing so only those messages are retried.
  const batchItemFailures: SQSBatchItemFailure[] = [];

  // Return an empty failure list if the event contains no Records array.
  if (!event.Records) {
    return {
      batchItemFailures,
    };
  }

  // Retrieve the SQS messages from the incoming event.
  let sqsMessages = await event.Records;

  for (let i = 0; i < sqsMessages.length; i++) {
    const message = sqsMessages[i]!;

    // Parse the SQS message body.
    // Note to self: Refer to the docs/schema directory to review the expected structure.

    // Parse the EventBridge event describing what happened in S3.
    // https://docs.aws.amazon.com/en_br/AmazonS3/latest/userguide/ev-events.html?
    const eventBridgeEvent = JSON.parse(message.body)!;

    // Verify that the EventBridge event contains a valid detail object.
    if (
      typeof eventBridgeEvent.detail !== "object" ||
      eventBridgeEvent.detail === null
    ) {
      batchItemFailures.push({
        itemIdentifier: message.messageId,
      });
      continue;
    }

    // Extract the S3 bucket and object metadata from the EventBridge event.
    const { bucket, object } = eventBridgeEvent.detail;

    // Retrieve the name of the S3 bucket where the event occurred.
    let bucketName = bucket.name;

    // Treat a missing bucket name as a processing failure.
    if (!bucketName) {
      // Add the failed SQS message to the partial-batch failure response.
      console.error("Missing bucket name in eventBridgeEvent.detail.bucket");
      batchItemFailures.push({
        itemIdentifier: message.messageId,
      });
      continue;
    }

    // Verify that the S3 bucket name is a string.
    if (typeof bucketName !== "string") {
      batchItemFailures.push({
        itemIdentifier: message.messageId,
      });
      continue;
    }

    // Retrieve the S3 object key from the EventBridge event.
    let objectKey = object.key;

    // Treat a missing object key as a processing failure.
    if (!objectKey) {
      // Add the failed SQS message to the partial-batch failure response.
      console.error("Missing object key in eventBridgeEvent.detail.object");
      batchItemFailures.push({
        itemIdentifier: message.messageId,
      });
      continue;
    }

    // Verify that the S3 object key is a string.
    if (typeof objectKey !== "string") {
      // Add the failed SQS message to the partial-batch failure response.
      batchItemFailures.push({
        itemIdentifier: message.messageId,
      });
      continue;
    }

    // Decode the S3 object key in case it contains spaces or special characters.
    objectKey = decodeURIComponent(objectKey.replace(/\+/g, " "));

    // Initialize the S3 client used to retrieve the event object.
    const s3Client = new S3Client({});

    // Define the maximum allowed S3 event object size: 64 KiB (65,536 bytes).
    const MAX_OBJECT_SIZE_BYTES = 64 * 1024;

    try {
      // Create the command used to retrieve the event object from S3.
      const getObjectCommand = new GetObjectCommand({
        Bucket: bucketName,
        Key: objectKey,
      });

      const response = await s3Client.send(getObjectCommand);

      // Reject S3 objects that exceed the 64 KiB event-size limit.
      if (
        response.ContentLength &&
        response.ContentLength > MAX_OBJECT_SIZE_BYTES
      ) {
        // Add the failed SQS message to the partial-batch failure response.
        batchItemFailures.push({
          itemIdentifier: message.messageId,
        });
        continue;
      }

      // Ensure that S3 returned an object body before attempting to process it.
      if (!response.Body) {
        console.error(
          `Missing object body for ${objectKey} in bucket ${bucketName}`
        );

        // Add the failed SQS message to the partial-batch failure response.
        batchItemFailures.push({
          itemIdentifier: message.messageId,
        });
        continue;
      }

      // Retrieve the S3 object body.
      let s3ObjectBody = response.Body;

      if (s3ObjectBody) {
        // Convert the streaming S3 object body into a readable string.
        const objectData = await response.Body.transformToString();

        // Parse the S3 object's JSON content into a JavaScript value.
        const parsedObject = JSON.parse(objectData);

        // Extract the required fields defined by the event contract.
        // Note to self: Refer to the docs/schema directory to review the expected structure.
        // "required": ["event_id", "event_type", "occurred_at", "source", "payload"],
        const { event_id, event_type, occurred_at, source, payload } =
          parsedObject;

        // Event types must follow the project's dot-separated naming convention.
        // Examples: "customer.created", "order.completed", "user_profile.updated-v2".
        const EVENT_TYPE_PATTERN =
          /^[a-z0-9]+(?:[._-][a-z0-9]+)*\.[a-z0-9]+(?:[._-][a-z0-9]+)*$/;

        // Verify that all required event fields exist and have the expected types.
        if (
          typeof event_id !== "string" ||
          typeof event_type !== "string" ||
          typeof occurred_at !== "string" ||
          typeof source !== "string" ||
          payload === null ||
          typeof payload !== "object" ||
          Array.isArray(payload)
        ) {
          console.error(
            `${objectKey} in bucket ${bucketName} contains missing or incorrectly typed required fields: event_id, event_type, occurred_at, source, payload`
          );

          // Add the failed SQS message to the partial-batch failure response.
          batchItemFailures.push({
            itemIdentifier: message.messageId,
          });

          continue;
        }

        // Verify that event_id contains between 1 and 128 characters.
        if (event_id.length < 1 || event_id.length > 128) {
          console.error("event_id must be between 1 and 128 characters");

          // Add the failed SQS message to the partial-batch failure response.
          batchItemFailures.push({
            itemIdentifier: message.messageId,
          });

          continue;
        }

        // Verify that event_type is nonempty and follows the event naming
        // convention defined by the event contract.
        if (event_type.length < 1 || !EVENT_TYPE_PATTERN.test(event_type)) {
          console.error(
            "event_type must follow the required dot-separated naming convention"
          );

          // Add the failed SQS message to the partial-batch failure response.
          batchItemFailures.push({
            itemIdentifier: message.messageId,
          });

          continue;
        }

        // Verify that source contains at least one character.
        if (source.length < 1) {
          console.error("source must be at least 1 character");

          // Add the failed SQS message to the partial-batch failure response.
          batchItemFailures.push({
            itemIdentifier: message.messageId,
          });

          continue;
        }

        // Verify that occurred_at represents a valid date-time.
        // Examples:
        // 2026-09-16T17:30:00Z
        // 2026-09-16T13:30:00-04:00
        const occurredAtDate = new Date(occurred_at);

        if (occurred_at.length < 1 || Number.isNaN(occurredAtDate.getTime())) {
          console.error("occurred_at must be a valid date-time");

          // Add the failed SQS message to the partial-batch failure response.
          batchItemFailures.push({
            itemIdentifier: message.messageId,
          });

          continue;
        }

        // Retrieve the DynamoDB table name supplied through the Lambda environment.
        const dynamodbTableName = process.env.DYNAMODB_TABLE_NAME;

        // Fail processing if the required DynamoDB table configuration is missing.
        if (dynamodbTableName === undefined) {
          throw new Error(
            "DYNAMODB_TABLE_NAME environment variable is not configured."
          );
        }

        // Initialize the low-level AWS SDK client used to communicate with DynamoDB.
        const dynamodbClient = new DynamoDBClient({});

        // Wrap the low-level client with the DynamoDB document client so items
        // can be read and written using standard JavaScript values.
        const dynamodbDocumentClient =
          DynamoDBDocumentClient.from(dynamodbClient);

        // Create the conditional write used to persist the processed event.
        const putEventCommand = new PutCommand({
          TableName: dynamodbTableName,
          Item: {
            event_id,
            event_type,
            occurred_at,
            source,
            payload,
          },

          // Prevent an existing event with the same event_id from being overwritten.
          ConditionExpression: "attribute_not_exists(event_id)",
        });

        try {
          // Attempt to persist the processed event in DynamoDB.
          await dynamodbDocumentClient.send(putEventCommand);
        } catch (error) {
          // A failed conditional check means the event_id already exists.
          // Treat duplicate delivery as a successful no-op rather than an SQS failure.
          if (
            error instanceof Error &&
            error.name === "ConditionalCheckFailedException"
          ) {
            console.log(
              `Event ${event_id} already exists in DynamoDB; treating duplicate as successful no-op.`
            );

            continue;
          }

          // Treat any other DynamoDB error as an actual processing failure.
          console.error(
            `Failed to persist event ${event_id} to DynamoDB:`,
            error
          );

          batchItemFailures.push({
            itemIdentifier: message.messageId,
          });

          continue;
        }
      } else {
        console.warn(`object ${objectKey} from bucket ${bucketName} is empty`);
      }
    } catch (error) {
      // Treat unexpected S3 or processing errors as failures for this SQS message.
      console.error(
        `Error processing object ${objectKey} from bucket ${bucketName}:`,
        error
      );

      batchItemFailures.push({
        itemIdentifier: message.messageId,
      });

      continue;
    }
  }

  // Return only the SQS message identifiers that failed processing so Lambda
  // can retry those records without retrying successfully processed messages.
  return {
    batchItemFailures,
  };
};
