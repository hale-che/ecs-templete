data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# 别名/Key ID 都能解析成 ARN。IAM 策略和日志组都要真实 ARN，别名 ARN 不行。
data "aws_kms_key" "this" {
  key_id = var.kms_key_id
}

locals {
  partition   = data.aws_partition.current.partition
  account_id  = data.aws_caller_identity.current.account_id
  kms_key_arn = data.aws_kms_key.this.arn

  # aws-cn 下 dns_suffix 是 amazonaws.com.cn，手写最容易漏掉那个 .cn。
  ecr_registry = "${local.account_id}.dkr.ecr.${var.region}.${data.aws_partition.current.dns_suffix}"

  # AZ 命名规范：AZ-CNRDIT-<ENV>-<项目标识>[-<服务名>]。集群不带服务名，三个服务共用。
  cluster_name = "AZ-CNRDIT-${var.environment}-${var.project}"

  name = {
    for k in keys(var.services) : k => "${local.cluster_name}-${k}"
  }

  tags = merge(var.mandatory_tags, {
    Environment = var.environment
    Project     = var.project
    ManagedBy   = "terraform"
  })

  log_group = { for k, v in local.name : k => "/ecs/${v}" }

  ecr_arn = {
    for k, s in var.services :
    k => "arn:${local.partition}:ecr:${var.region}:${local.account_id}:repository/${s.repository}"
  }

  log_stream_arn = {
    for k, v in local.log_group :
    k => "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:${v}:log-stream:*"
  }

  # IAM 要密钥本体的 ARN。ECS 的 valueFrom 可以带 :json-key:: 后缀，截掉前 7 段还原。
  secret_arns = {
    for k, s in var.services :
    k => distinct([for a in values(s.secrets) : join(":", slice(split(":", a), 0, 7))])
  }

  # 没有容器健康检查：三个服务都挂 ALB，健康检查由目标组做。
  container_definitions = {
    for k, s in var.services : k => [{
      name      = k
      image     = "${local.ecr_registry}/${s.repository}:${s.tag}"
      essential = true

      readonlyRootFilesystem = s.readonly_root_filesystem

      portMappings = [{
        containerPort = s.port
        protocol      = "tcp"
      }]

      environment = [for ek, ev in s.environment : { name = ek, value = ev }]
      secrets     = [for sk, sv in s.secrets : { name = sk, valueFrom = sv }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = local.log_group[k]
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = k
        }
      }
    }]
  }
}
