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

output "ecr_repository_urls" {
  description = "本模板创建的 ECR 仓库地址，按服务名索引。"
  value       = { for k, s in var.services : k => aws_ecr_repository.this[s.repository].repository_url }
}

output "codebuild_projects" {
  description = "CodeBuild 项目名。手工触发：aws codebuild start-build --project-name <名字>。"
  value       = { for k, v in aws_codebuild_project.build : k => v.name }
}

output "file_bucket" {
  description = "应用文件桶。Intelligent-Tiering，内置 30 天转 IA、90 天转 Archive Instant Access。"
  value       = aws_s3_bucket.files.bucket
}

output "file_bucket_kms_key_arn" {
  description = "本环境创建的应用文件桶 CMK。"
  value       = aws_kms_key.files.arn
}

output "logs_kms_key_arn" {
  description = "本环境创建的 CloudWatch Logs CMK，ECS 和 CodeBuild 日志组共用。"
  value       = aws_kms_key.logs.arn
}

output "tls_secret_arn" {
  description = "TLS 证书的 Secret ARN，外部已建好，本模板只引用。"
  value       = var.tls_secret_arn
}
