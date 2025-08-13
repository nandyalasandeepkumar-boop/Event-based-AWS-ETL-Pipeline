import json
import os
import urllib.parse
import boto3
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

glue = boto3.client("glue")

GLUE_JOB_NAME = os.environ["GLUE_JOB_NAME"]
PROCESSED_BUCKET = os.environ["PROCESSED_BUCKET"]

def lambda_handler(event, context):
    """
    Triggered by S3:ObjectCreated for .csv or .json files.
    Starts a Glue job with --input_path and --output_path args.
    """
    logger.info("Event: %s", json.dumps(event))

    for record in event.get("Records", []):
        s3 = record["s3"]
        bucket = s3["bucket"]["name"]
        key = urllib.parse.unquote_plus(s3["object"]["key"])

        if not (key.endswith(".csv") or key.endswith(".json")):
            logger.info("Skipping non-data object: %s", key)
            continue

        input_path = f"s3://{bucket}/{key}"
        output_path = f"s3://{PROCESSED_BUCKET}/curated/"

        logger.info("Starting Glue job '%s' with input=%s output=%s",
                    GLUE_JOB_NAME, input_path, output_path)

        response = glue.start_job_run(
            JobName=GLUE_JOB_NAME,
            Arguments={
                "--input_path": input_path,
                "--output_path": output_path
            }
        )
        logger.info("Glue JobRunId: %s", response.get("JobRunId"))

    return {"statusCode": 200, "body": "OK"}
