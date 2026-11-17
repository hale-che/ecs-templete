# Index by service name, which is also the container name.

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "service_names" {
  value = { for k, v in aws_ecs_service.this : k => v.name }
}

output "families" {
  description = "Task definition family. CodeBuild uses it to fetch the latest revision."
  value       = { for k, v in aws_ecs_task_definition.this : k => v.family }
}

output "task_definition_arns" {
  description = "ARN of the revision created by Terraform; not necessarily the one currently running."
  value       = { for k, v in aws_ecs_task_definition.this : k => v.arn }
}

output "execution_role_arns" {
  value = { for k, v in aws_iam_role.execution : k => v.arn }
}

output "task_role_arns" {
  description = "Role the application uses to access AWS; add permissions via task_role_policy_statements."
  value       = { for k, v in aws_iam_role.task : k => v.arn }
}

output "log_group_names" {
  value = { for k, v in aws_cloudwatch_log_group.this : k => v.name }
}

output "image_urls" {
  description = "Full derived image URI used by CodeBuild push, including the .com.cn suffix."
  value       = { for k, s in var.services : k => "${local.ecr_registry}/${s.repository}:${s.image_tag}" }
}

output "ecr_repository_urls" {
  description = "ECR repository URLs created by this template, keyed by service name."
  value       = { for k, s in var.services : k => aws_ecr_repository.this[s.repository].repository_url }
}

output "codebuild_projects" {
  description = "CodeBuild project names. Trigger manually: aws codebuild start-build --project-name <name>."
  value       = { for k, v in aws_codebuild_project.build : k => v.name }
}

output "file_bucket" {
  description = "Application file bucket. Intelligent-Tiering moves objects to IA after 30 days and Archive Instant Access after 90."
  value       = aws_s3_bucket.files.bucket
}

output "access_log_bucket" {
  description = "Bucket receiving S3 server access logs for the file bucket."
  value       = aws_s3_bucket.access_logs.bucket
}

output "file_bucket_kms_key_arn" {
  description = "CMK for the application file bucket in this environment."
  value       = aws_kms_key.files.arn
}

output "logs_kms_key_arn" {
  description = "CloudWatch Logs CMK for this environment, shared by ECS and CodeBuild log groups."
  value       = aws_kms_key.logs.arn
}

output "secret_arns" {
  description = "Secrets created by Terraform, keyed by managed_secrets key. Enter their values after apply."
  value       = local.managed_secret_arns
}
