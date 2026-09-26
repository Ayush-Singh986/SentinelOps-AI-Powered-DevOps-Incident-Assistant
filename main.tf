terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------- SSM Parameters for secrets (fill values via `terraform apply -var` or CI secrets) ----------
resource "aws_ssm_parameter" "slack_webhook" {
  name  = "/${var.project_name}/slack_webhook_url"
  type  = "SecureString"
  value = "REPLACE_ME_VIA_CI_OR_CLI"

  lifecycle {
    ignore_changes = [value] # set the real value out-of-band, don't store secrets in state diffs
  }
}

resource "aws_ssm_parameter" "anthropic_api_key" {
  name  = "/${var.project_name}/anthropic_api_key"
  type  = "SecureString"
  value = "REPLACE_ME_VIA_CI_OR_CLI"

  lifecycle {
    ignore_changes = [value]
  }
}

# ---------- SNS topic that CloudWatch alarms publish to ----------
resource "aws_sns_topic" "incidents" {
  name = "${var.project_name}-incidents"
}

# ---------- IAM role for Lambda ----------
resource "aws_iam_role" "lambda_exec" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:FilterLogEvents", "logs:GetLogEvents"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = [
          aws_ssm_parameter.slack_webhook.arn,
          aws_ssm_parameter.anthropic_api_key.arn
        ]
      }
    ]
  })
}

# ---------- Lambda function ----------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_lambda_function" "incident_assistant" {
  function_name    = "${var.project_name}-incident-assistant"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      LOG_GROUP_NAME               = var.log_group_name
      SLACK_WEBHOOK_SSM_PARAM      = aws_ssm_parameter.slack_webhook.name
      ANTHROPIC_API_KEY_SSM_PARAM  = aws_ssm_parameter.anthropic_api_key.name
      LOOKBACK_MINUTES             = var.lookback_minutes
      AUTO_REMEDIATE               = var.auto_remediate
    }
  }
}

resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.incident_assistant.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.incidents.arn
}

resource "aws_sns_topic_subscription" "lambda_sub" {
  topic_arn = aws_sns_topic.incidents.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.incident_assistant.arn
}

# ---------- Example CloudWatch Alarm wired to the SNS topic ----------
resource "aws_cloudwatch_metric_alarm" "example_alarm" {
  alarm_name          = "${var.project_name}-example-alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = var.alarm_metric_name
  namespace           = var.alarm_metric_namespace
  period              = 60
  statistic           = "Sum"
  threshold           = var.alarm_threshold
  alarm_description   = "Triggers SentinelOps AI incident analysis"
  alarm_actions       = [aws_sns_topic.incidents.arn]
}
