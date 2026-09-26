variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "sentinelops"
}

variable "log_group_name" {
  description = "CloudWatch Log Group to pull incident context from"
  type        = string
}

variable "alarm_metric_namespace" {
  description = "Namespace of the CloudWatch metric to alarm on (e.g. AWS/Lambda, AWS/ECS)"
  type        = string
  default     = "AWS/Lambda"
}

variable "alarm_metric_name" {
  description = "Metric name to alarm on (e.g. Errors, 5XXError)"
  type        = string
  default     = "Errors"
}

variable "alarm_threshold" {
  description = "Threshold that triggers the alarm"
  type        = number
  default     = 1
}

variable "lookback_minutes" {
  description = "How many minutes of logs to pull for AI analysis"
  type        = number
  default     = 15
}

variable "auto_remediate" {
  description = "Enable auto-remediation logic (off by default - build this out deliberately)"
  type        = bool
  default     = false
}
