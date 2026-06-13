output "instance_id" {
  description = "EC2 instance id (use with SSM send-command)"
  value       = aws_instance.app.id
}

output "xray_group_name" {
  description = "X-Ray group name (CloudWatch metrics dimension)"
  value       = aws_xray_group.todo.group_name
}

output "alarm_name" {
  description = "Fault-rate alarm name"
  value       = aws_cloudwatch_metric_alarm.fault_rate.alarm_name
}

output "sns_topic_arn" {
  description = "SNS topic ARN for alarm actions"
  value       = aws_sns_topic.alarms.arn
}

output "region" {
  value = var.region
}
