"""
SentinelOps - AI-Powered DevOps Incident Assistant
----------------------------------------------------
Trigger flow:
  CloudWatch Alarm -> SNS Topic -> this Lambda
Steps this function performs:
  1. Parse the SNS message to identify which alarm fired and which resource it's on.
  2. Pull the last N minutes of CloudWatch Logs for that resource.
  3. Send the alarm context + logs to Claude for root-cause analysis.
  4. Post a formatted incident summary to Slack.
  5. (Optional, disabled by default) Attempt safe auto-remediation for known issue types.
"""

import json
import os
import time
import urllib.request
import boto3

logs_client = boto3.client("logs")
ssm_client = boto3.client("ssm")

# --- Config (pulled from environment variables set by Terraform) ---
LOG_GROUP_NAME = os.environ.get("LOG_GROUP_NAME")
SLACK_WEBHOOK_SSM_PARAM = os.environ.get("SLACK_WEBHOOK_SSM_PARAM")
ANTHROPIC_API_KEY_SSM_PARAM = os.environ.get("ANTHROPIC_API_KEY_SSM_PARAM")
LOOKBACK_MINUTES = int(os.environ.get("LOOKBACK_MINUTES", "15"))
AUTO_REMEDIATE = os.environ.get("AUTO_REMEDIATE", "false").lower() == "true"


def get_ssm_secret(param_name: str) -> str:
    resp = ssm_client.get_parameter(Name=param_name, WithDecryption=True)
    return resp["Parameter"]["Value"]


def fetch_recent_logs(log_group: str, minutes: int) -> str:
    """Pull recent log events from CloudWatch Logs for context."""
    end_time = int(time.time() * 1000)
    start_time = end_time - (minutes * 60 * 1000)

    events = []
    try:
        paginator = logs_client.get_paginator("filter_log_events")
        for page in paginator.paginate(
            logGroupName=log_group,
            startTime=start_time,
            endTime=end_time,
            PaginationConfig={"MaxItems": 200},
        ):
            events.extend(page.get("events", []))
    except logs_client.exceptions.ResourceNotFoundException:
        return "(log group not found or no recent events)"

    if not events:
        return "(no log events found in the lookback window)"

    lines = [e["message"].strip() for e in events]
    return "\n".join(lines[-200:])  # cap payload size sent to the model


def call_claude_for_analysis(alarm_name: str, alarm_reason: str, log_excerpt: str) -> str:
    api_key = get_ssm_secret(ANTHROPIC_API_KEY_SSM_PARAM)

    prompt = f"""You are an SRE assistant. A CloudWatch alarm fired.

Alarm name: {alarm_name}
Alarm reason: {alarm_reason}

Recent log excerpt:
{log_excerpt}

Respond in this exact structure, concise and specific:
1. Likely root cause (1-2 sentences)
2. Severity (Low / Medium / High / Critical) with one-line justification
3. Recommended remediation steps (numbered, actionable)
4. Whether this looks safe for automated remediation (yes/no + why)
"""

    body = json.dumps(
        {
            "model": "claude-sonnet-4-6",
            "max_tokens": 600,
            "messages": [{"role": "user", "content": prompt}],
        }
    ).encode("utf-8")

    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=body,
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
        },
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=25) as resp:
        data = json.loads(resp.read())

    return "".join(block.get("text", "") for block in data.get("content", []))


def post_to_slack(alarm_name: str, analysis: str) -> None:
    webhook_url = get_ssm_secret(SLACK_WEBHOOK_SSM_PARAM)
    payload = {
        "text": f":rotating_light: *SentinelOps Incident Report*\n*Alarm:* {alarm_name}\n\n{analysis}"
    }
    req = urllib.request.Request(
        webhook_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    urllib.request.urlopen(req, timeout=10)


def lambda_handler(event, context):
    record = event["Records"][0]["Sns"]
    message = json.loads(record["Message"])

    alarm_name = message.get("AlarmName", "unknown-alarm")
    alarm_reason = message.get("NewStateReason", "no reason provided")

    log_excerpt = fetch_recent_logs(LOG_GROUP_NAME, LOOKBACK_MINUTES)
    analysis = call_claude_for_analysis(alarm_name, alarm_reason, log_excerpt)
    post_to_slack(alarm_name, analysis)

    if AUTO_REMEDIATE:
        # Placeholder: wire this to specific, whitelisted remediation actions only
        # (e.g. restart an ECS service, scale an ASG). Never let the model
        # execute arbitrary commands directly.
        pass

    return {"statusCode": 200, "body": "Incident processed"}
