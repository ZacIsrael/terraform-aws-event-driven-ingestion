import type {
  SQSEvent,
  SQSBatchResponse,
  SQSBatchItemFailure,
} from "aws-lambda";
import type SQSRecord = require("aws-lambda");
import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";

import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";

export const handler = async (event: SQSEvent): Promise<SQSBatchResponse> => {
  // Debugging
  console.log("event = ", event);

  // Array that keeps track of items that failed to be processed
  const batchItemFailures: SQSBatchItemFailure[] = [];

  //   Null check: see if Records array even exists
  if (!event.Records) {
    return {
      batchItemFailures,
    };
  }

  // Records array exists
  let sqsMessages = await event.Records;

  for (let i = 0; i < sqsMessages.length; i++) {
    const message = sqsMessages[i]!;
    // parse message body
    // note to self: refer to docs/schema directory to see structure

    // Read EventBridge event that describes what happened in S3
    // https://docs.aws.amazon.com/en_br/AmazonS3/latest/userguide/ev-events.html?
    const eventBridgeEvent = JSON.parse(message.body)!;

    // check if eventBridgeEvent.detail is an obeject
    if (
      typeof eventBridgeEvent.detail !== "object" ||
      eventBridgeEvent.detail === null
    ) {
      batchItemFailures.push({
        itemIdentifier: message.messageId,
      });
      continue;
    }

    // destruct object
    const { bucket, object } = eventBridgeEvent.detail;

    // name of the bucket where this event happened
    let bucketName = bucket.name;
    // if bucket name doesn't exist that's an error.
    if (!bucketName) {
      // Add record to the batchItemFailures array
      console.error("Missing bucket name in eventBridgeEvent.detail.bucket");
      batchItemFailures.push({
        itemIdentifier: message.messageId,
      });
      continue;
    }

    // Obviously, bucketName must be of type string
    if (typeof bucketName !== "string") {
      batchItemFailures.push({
        itemIdentifier: message.messageId,
      });
      continue;
    }

    // name of the key in the bucket
    let objectKey = object.key;
    // if object doesn't exist that's an error.
    if (!objectKey) {
      // Add record to the batchItemFailures array
      console.error("Missing object key in eventBridgeEvent.detail.object");
      batchItemFailures.push({
        itemIdentifier: message.messageId,
      });
      continue;
    }

    // Obviously, the key needs to be a string
    if (typeof objectKey !== "string") {
      // Add record to the batchItemFailures array
      batchItemFailures.push({
        itemIdentifier: message.messageId,
      });
      continue;
    }

    // Decode key in case it contains spaces or special characters
    objectKey = decodeURIComponent(objectKey.replace(/\+/g, " "));

    // Initialize S3 client
    const s3Client = new S3Client({});

    // Needed later to see if the object is greater than 64 KB
    const MAX_OBJECT_SIZE_BYTES = 64 * 1024;

    try {
      // Get the object from S3
      const getObjectCommand = new GetObjectCommand({
        Bucket: bucketName,
        Key: objectKey,
      });

      const response = await s3Client.send(getObjectCommand);

      // Check if object is greater than 64 KB
      if (
        response.ContentLength &&
        response.ContentLength > MAX_OBJECT_SIZE_BYTES
      ) {
        // Add record to the batchItemFailures array
        batchItemFailures.push({
          itemIdentifier: message.messageId,
        });
        continue;
      }

      if (!response.Body) {
        console.error(
          `Missing object body for ${objectKey} in bucket ${bucketName}`
        );
        // Add record to the batchItemFailures array
        batchItemFailures.push({
          itemIdentifier: message.messageId,
        });
        continue;
      }
      // Read object body
      let s3ObjectBody = response.Body;
      if (s3ObjectBody) {
        // Stream object's data (converts it to a readable string)
        const objectData = await response.Body.transformToString();

        const parsedObject = JSON.parse(objectData);

        // Destruct parseObject with required fields
        // note to self: refer to docs/schema directory to see expected structure
        // "required": ["event_id", "event_type", "occurred_at", "source", "payload"],
        const { event_id, event_type, occurred_at, source, payload } =
          parsedObject;

        // Event types must follow the project's dot-separated naming convention.
        // Examples: "customer.created", "order.completed", "user_profile.updated-v2"
        const EVENT_TYPE_PATTERN =
          /^[a-z0-9]+(?:[._-][a-z0-9]+)*\.[a-z0-9]+(?:[._-][a-z0-9]+)*$/;

        // Validate that all required event fields exist and have the expected types.
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

          batchItemFailures.push({
            itemIdentifier: message.messageId,
          });

          continue;
        }

        // event_id must contain between 1 and 128 characters.
        if (event_id.length < 1 || event_id.length > 128) {
          console.error("event_id must be between 1 and 128 characters");

          batchItemFailures.push({
            itemIdentifier: message.messageId,
          });

          continue;
        }

        // event_type must be nonempty and conform to the event naming convention
        // defined by the event contract.
        if (event_type.length < 1 || !EVENT_TYPE_PATTERN.test(event_type)) {
          console.error(
            "event_type must follow the required dot-separated naming convention"
          );

          batchItemFailures.push({
            itemIdentifier: message.messageId,
          });

          continue;
        }

        // source must contain at least one character.
        if (source.length < 1) {
          console.error("source must be at least 1 character");

          batchItemFailures.push({
            itemIdentifier: message.messageId,
          });

          continue;
        }

        // occurred_at must be a valid RFC 3339 date-time string.
        // Examples:
        // 2026-09-16T17:30:00Z
        // 2026-09-16T13:30:00-04:00
        const occurredAtDate = new Date(occurred_at);

        if (occurred_at.length < 1 || Number.isNaN(occurredAtDate.getTime())) {
          console.error("occurred_at must be a valid date-time");

          batchItemFailures.push({
            itemIdentifier: message.messageId,
          });

          continue;
        }

        // DynamoDB conditional PutItem

        // Retrieve the DynamoDB table name supplied by the Lambda environment configuration.
        const dynamodbTableName = process.env.DYNAMODB_TABLE_NAME;

        // Fail if the Lambda was deployed without its required DynamoDB table configuration.
        if (dynamodbTableName === undefined) {
          throw new Error(
            "DYNAMODB_TABLE_NAME environment variable is not configured."
          );
        }

        // Check if event already exists in the DynamoDB table. If not, then add it

        // Create the low-level AWS SDK client used to communicate with DynamoDB.
        const dynamodbClient = new DynamoDBClient({});

        // Wrap the base client so DynamoDB items use normal JavaScript values.
        const dynamodbDocumentClient =
          DynamoDBDocumentClient.from(dynamodbClient);

        // Event does not exist in DynamoDB, so add it
        const putEventCommand = new PutCommand({
          TableName: dynamodbTableName,
          Item: {
            event_id,
            event_type,
            occurred_at,
            source,
            payload,
          },

          // Prevent an existing event from being overwritten.
          ConditionExpression: "attribute_not_exists(event_id)",
        });

        try {
          // Attempt to persist the event record in DynamoDB.
          await dynamodbDocumentClient.send(putEventCommand);
        } catch (error) {
          // A failed condition means the event_id already exists.
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

          // Any other DynamoDB error represents an actual processing failure.
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
      console.error(
        `Error getting object ${objectKey} from bucket ${bucketName}:`,
        error
      );
      batchItemFailures.push({
        itemIdentifier: message.messageId,
      });

      continue;
    }
  }

  return {
    batchItemFailures,
  };
};
