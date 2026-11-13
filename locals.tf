data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  # In aws-cn, dns_suffix is amazonaws.com.cn; using the data source avoids omitting .cn. | aws-cn 下 dns_suffix 是 amazonaws.com.cn，手写最容易漏掉那个 .cn。
  ecr_registry = "${local.account_id}.dkr.ecr.${var.region}.${data.aws_partition.current.dns_suffix}"

  # Required resource naming: az-cn-rdit-<project>-<purpose>-<dev|ppd|prd>. | 评审命名要求：az-cn-rdit-<project>-<资源用途>-<dev|ppd|prd>。
  name_prefix  = "az-cn-rdit-${var.project}"
  cluster_name = "${local.name_prefix}-ecs-fargate-${var.environment}"

  name = {
    for k in keys(var.services) : k => "${local.name_prefix}-${k}-${var.environment}"
  }

  execution_role_name = { for k in keys(var.services) : k => "${local.name_prefix}-${k}-ecs-execution-role-${var.environment}" }
  task_role_name      = { for k in keys(var.services) : k => "${local.name_prefix}-${k}-ecs-task-role-${var.environment}" }
  build_role_name     = { for k in keys(var.services) : k => "${local.name_prefix}-${k}-build-role-${var.environment}" }
  build_name          = { for k in keys(var.services) : k => "${local.name_prefix}-${k}-build-${var.environment}" }
  build_project_arn   = { for k, name in local.build_name : k => "arn:${local.partition}:codebuild:${var.region}:${local.account_id}:project/${name}" }

  tags = merge(var.mandatory_tags, {
    Project   = var.project
    ManagedBy = "terraform"
  })

  log_group = { for k, v in local.name : k => "/ecs/${v}" }

  file_bucket_name = coalesce(var.file_bucket_name, "${local.name_prefix}-files-${var.environment}")

  ecr_arn = {
    for k, s in var.services :
    k => "arn:${local.partition}:ecr:${var.region}:${local.account_id}:repository/${s.repository}"
  }

  service_arn = {
    for k, v in local.name :
    k => "arn:${local.partition}:ecs:${var.region}:${local.account_id}:service/${local.cluster_name}/${v}"
  }

  build_log_stream_arn = {
    for k, v in local.name :
    k => "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/codebuild/${local.build_name[k]}:log-stream:*"
  }

  log_stream_arn = {
    for k, v in local.log_group :
    k => "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:${v}:log-stream:*"
  }

  # The TLS secret is shared by all three services, so merge it here instead of repeating it per service. | TLS 密钥三个服务共用，在这里统一合进去，不用每个服务重复填。
  # Service-specific secrets go in the tfvars secrets map; tfvars takes precedence when names conflict. | 服务各自的密钥填 tfvars 的 secrets，同名时以 tfvars 为准。
  secrets_effective = {
    for k, s in var.services : k => merge(
      {
        TLS_CERT = "${var.tls_secret_arn}:cert::"
        TLS_KEY  = "${var.tls_secret_arn}:key::"
      },
      s.secrets,
    )
  }

  # IAM requires the base secret ARN. ECS valueFrom may include a :json-key:: suffix; keep the first seven colon-separated segments. | IAM 要密钥本体的 ARN。ECS 的 valueFrom 可以带 :json-key:: 后缀，截掉前 7 段还原。
  secret_arns = {
    for k, v in local.secrets_effective :
    k => distinct([for a in values(v) : join(":", slice(split(":", a), 0, 7))])
  }

  container_base = {
    for k, s in var.services : k => {
      name      = k
      image     = "${local.ecr_registry}/${s.repository}:${s.tag}"
      essential = true

      readonlyRootFilesystem = s.readonly_root_filesystem

      portMappings = [{
        name          = k
        containerPort = s.port
        protocol      = "tcp"
      }]

      environment = [for ek, ev in s.environment : { name = ek, value = ev }]
      secrets     = [for sk, sv in local.secrets_effective[k] : { name = sk, valueFrom = sv }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = local.log_group[k]
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = k
        }
      }
    }
  }

  # Append healthCheck with merge instead of setting it to null; ECS rejects explicit null container properties. | 用 merge 追加而不是写 healthCheck = null：ECS 不接受显式 null 的容器属性。
  container_definitions = {
    for k, s in var.services : k => [merge(
      local.container_base[k],
      s.health_check_command == null ? {} : {
        healthCheck = {
          command     = ["CMD-SHELL", s.health_check_command]
          interval    = 30
          timeout     = 5
          retries     = 3
          startPeriod = 60
        }
      },
    )]
  }
}
