output "lambda_function_name" {
  value = aws_lambda_function.incident_assistant.function_name
}

output "sns_topic_arn" {
  value = aws_sns_topic.incidents.arn
}

output "cloudwatch_alarm_name" {
  value = aws_cloudwatch_metric_alarm.example_alarm.alarm_name
}
