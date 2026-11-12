# Index by service name, which is also the container name. | 按服务名索引。服务名同时也是容器名。

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
  description = "Task Definition family。CodeBuild 用它拉最新 revision。"
  value       = { for k, v in aws_ecs_task_definition.this : k => v.family }
}

output "task_definition_arns" {
  description = "Terraform 创建的那个 revision 的 ARN，不一定是线上正在跑的。"
  value       = { for k, v in aws_ecs_task_definition.this : k => v.arn }
}

output "execution_role_arns" {
  value = { for k, v in aws_iam_role.execution : k => v.arn }
}

output "task_role_arns" {
  description = "业务代码访问 AWS 资源用的角色，权限在 task_role_policy_statements 里加。"
  value       = { for k, v in aws_iam_role.task : k => v.arn }
}

output "log_group_names" {
  value = { for k, v in aws_cloudwatch_log_group.this : k => v.name }
}

output "image_urls" {
  description = "推导出的完整镜像地址，CodeBuild push 时直接用，不用自己拼 .com.cn。"
  value       = { for k, s in var.services : k => "${local.ecr_registry}/${s.repository}:${s.tag}" }
}

output "codebuild_projects" {
  description = "CodeBuild 项目名。手工触发：aws codebuild start-build --project-name <名字>。"
  value       = { for k, v in aws_codebuild_project.build : k => v.name }
}

output "file_bucket" {
  description = "应用文件桶。Intelligent-Tiering，内置 30 天转 IA、90 天转 Archive Instant Access。"
  value       = aws_s3_bucket.files.bucket
}

output "codebase_bucket" {
  description = "代码桶。和文件桶同一把 S3 CMK，不分层。"
  value       = aws_s3_bucket.codebase.bucket
}

output "file_bucket_kms_key_arn" {
  description = "本环境创建的应用文件桶 CMK。"
  value       = aws_kms_key.files.arn
}

output "tls_kms_key_arn" {
  description = "本环境创建的 TLS Secret CMK。"
  value       = aws_kms_key.secrets.arn
}

output "tls_secret_arn" {
  description = "TLS 证书的 Secret。Terraform 只建容器，值要手工填，见 README。"
  value       = aws_secretsmanager_secret.tls.arn
}
