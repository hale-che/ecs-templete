data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  # In aws-cn, dns_suffix is amazonaws.com.cn; using the data source avoids omitting .cn.
  ecr_registry = "${local.account_id}.dkr.ecr.${var.region}.${data.aws_partition.current.dns_suffix}"

  # Required resource naming: az-cn-rdit-<project>-<purpose>-<dev|ppd|prd>.
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

  file_bucket_name       = coalesce(var.file_bucket_name, "${local.name_prefix}-files-${var.environment}")
  access_log_bucket_name = coalesce(var.access_log_bucket_name, "${local.name_prefix}-s3-access-logs-${var.environment}")

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

  secret_name_prefix  = coalesce(var.secret_name_prefix, "${var.project}/${var.environment}")
  managed_secret_arns = { for k, s in aws_secretsmanager_secret.this : k => s.arn }

  # Resolve "key" / "key:json-key" to managed secret ARNs; full ARNs pass through. Unknown keys fail the task definition precondition.
  service_secrets = {
    for k, s in var.services : k => {
      for ek, ref in s.secrets : ek => startswith(ref, "arn:") ? ref : (
        length(split(":", ref)) == 2
        ? "${lookup(local.managed_secret_arns, split(":", ref)[0], ref)}:${split(":", ref)[1]}::"
        : lookup(local.managed_secret_arns, ref, ref)
      )
    }
  }

  # The TLS secret is shared by all three services, so merge it here instead of repeating it per service.
  # Service-specific secrets go in the tfvars secrets map; tfvars takes precedence when names conflict.
  secrets_effective = {
    for k, s in var.services : k => merge(
      {
        TLS_CERT = "${local.managed_secret_arns["tls"]}:cert::"
        TLS_KEY  = "${local.managed_secret_arns["tls"]}:key::"
      },
      local.service_secrets[k],
    )
  }

  # IAM requires the base secret ARN. ECS valueFrom may include a :json-key:: suffix; keep the first seven colon-separated segments.
  secret_arns = {
    for k, v in local.secrets_effective :
    k => distinct([for a in values(v) : join(":", slice(split(":", a), 0, min(7, length(split(":", a)))))])
  }

  container_base = {
    for k, s in var.services : k => {
      name      = k
      image     = "${local.ecr_registry}/${s.repository}:${s.image_tag}"
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

  # Append healthCheck with merge instead of setting it to null; ECS rejects explicit null container properties.
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
