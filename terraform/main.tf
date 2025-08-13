Replace the region and optionally project_name value. Bucket names must be globally unique.

hcl
Copy
Edit
provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "event-etl-demo"
}

resource "random_id" "suffix" {
  byte_length = 3
}

# Buckets
resource "aws_s3_bucket" "raw" {
  bucket = "${var.project_name}-raw-${random_id.suffix.hex}"
}

resource "aws_s3_bucket" "processed" {
  bucket = "${var.project_name}-processed-${random_id.suffix.hex}"
}

# Upload Glue script to processed bucket under scripts/
resource "aws_s3_object" "glue_script" {
  bucket = aws_s3_bucket.processed.bucket
  key    = "scripts/glue_job.py"
  source = "${path.module}/../glue/glue_job.py"
  etag   = filemd5("${path.module}/../glue/glue_job.py")
}

# ----- Lambda packaging -----
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/lambda"
  output_path = "${path.module}/../src/lambda.zip"
}

resource "aws_iam_role" "lambda_role" {
  name               = "${var.project_name}-lambda-role-${random_id.suffix.hex}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Minimal Lambda policy: logs, read raw bucket objects, start Glue job
data "aws_iam_policy_document" "lambda_inline" {
  statement {
    sid     = "Logs"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }

  statement {
    sid     = "ReadRaw"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.raw.arn,
      "${aws_s3_bucket.raw.arn}/*"
    ]
  }

  statement {
    sid     = "StartGlueJob"
    actions = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_policy" {
  role   = aws_iam_role.lambda_role.id
  policy = data.aws_iam_policy_document.lambda_inline.json
}

resource "aws_lambda_function" "on_s3_create" {
  function_name    = "${var.project_name}-on-s3-create-${random_id.suffix.hex}"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"
  timeout          = 60
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      GLUE_JOB_NAME    = aws_glue_job.etl_job.name
      PROCESSED_BUCKET = aws_s3_bucket.processed.bucket
    }
  }
}

# Allow S3 to invoke Lambda
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.on_s3_create.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.raw.arn
}

# S3 → Lambda notification on .csv/.json
resource "aws_s3_bucket_notification" "raw_notify" {
  bucket = aws_s3_bucket.raw.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.on_s3_create.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".csv"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.on_s3_create.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".json"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

# ----- Glue job -----
resource "aws_iam_role" "glue_role" {
  name               = "${var.project_name}-glue-role-${random_id.suffix.hex}"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
}

data "aws_iam_policy_document" "glue_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

# Minimal Glue policy: CloudWatch logs, read raw, write processed, temp dir
data "aws_iam_policy_document" "glue_inline" {
  statement {
    sid = "S3Access"
    actions = ["s3:GetObject", "s3:ListBucket", "s3:PutObject"]
    resources = [
      aws_s3_bucket.raw.arn,
      "${aws_s3_bucket.raw.arn}/*",
      aws_s3_bucket.processed.arn,
      "${aws_s3_bucket.processed.arn}/*"
    ]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }

  # Glue needs these
  statement {
    sid = "Glue"
    actions = [
      "glue:GetJob",
      "glue:CreateJob",
      "glue:StartJobRun",
      "glue:GetJobRun",
      "glue:GetJobRuns"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "glue_policy" {
  role   = aws_iam_role.glue_role.id
  policy = data.aws_iam_policy_document.glue_inline.json
}

resource "aws_glue_job" "etl_job" {
  name     = "${var.project_name}-glue-job-${random_id.suffix.hex}"
  role_arn = aws_iam_role.glue_role.arn

  glue_version = "4.0"  # Spark 3 on Glue 4.0
  number_of_workers = 2
  worker_type       = "G.1X"

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.processed.bucket}/${aws_s3_object.glue_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"   = "python"
    "--enable-metrics" = "true"
    "--TempDir"        = "s3://${aws_s3_bucket.processed.bucket}/temp/"
  }
}

output "raw_bucket" {
  value = aws_s3_bucket.raw.bucket
}

output "processed_bucket" {
  value = aws_s3_bucket.processed.bucket
}

output "lambda_name" {
  value = aws_lambda_function.on_s3_create.function_name
}

output "glue_job_name" {
  value = aws_glue_job.etl_job.name
}
