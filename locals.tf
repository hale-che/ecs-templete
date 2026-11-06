data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  partition   = data.aws_partition.current.partition
  account_id  = data.aws_caller_identity.current.account_id
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

  service_arn = {
    for k, v in local.name :
    k => "arn:${local.partition}:ecs:${var.region}:${local.account_id}:service/${local.cluster_name}/${v}"
  }

  build_log_stream_arn = {
    for k, v in local.name :
    k => "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/codebuild/${v}:log-stream:*"
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

  container_base = {
    for k, s in var.services : k => {
      name      = k
      image     = "${local.ecr_registry}/${s.repository}:${s.tag}"
      essential = true

      readonlyRootFilesystem = s.readonly_root_filesystem

      # name 是 Service Connect 引用端口的方式，不能省。
      # 不设 appProtocol：应用自己终止 TLS，Envoy 要走 L4 透传，
      # 设成 http 它会试图解析加密流量，连接建得起来但请求全失败。
      portMappings = [{
        name          = k
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
    }
  }

  # 用 merge 追加而不是写 healthCheck = null：ECS 不接受显式 null 的容器属性。
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
