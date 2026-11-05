resource "aws_ecs_service" "this" {
  for_each = var.services

  # 两个隐式依赖 Terraform 推不出来：执行角色的内联策略、日志组。
  depends_on = [
    aws_iam_role_policy.execution,
    aws_cloudwatch_log_group.this,
  ]

  name            = local.name[each.key]
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this[each.key].arn
  desired_count   = coalesce(each.value.desired_count, 1)

  launch_type      = "FARGATE"
  platform_version = "LATEST"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = each.value.security_group_ids
    assign_public_ip = false
  }

  # 服务间调用：前端用 https://<service_connect_name>:<port> 直接访问后端，不经 ALB。
  # 每个任务会多一个 Envoy sidecar，占的是任务自己的 cpu/memory 配额。
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.this.arn

    # 只有填了 service_connect_name 的服务对外暴露名字，其余只作为客户端。
    dynamic "service" {
      for_each = each.value.service_connect_name == null ? [] : [each.value.service_connect_name]

      content {
        port_name      = each.key
        discovery_name = service.value

        client_alias {
          port     = each.value.port
          dns_name = service.value
        }
      }
    }

    # Envoy 自己的日志，和业务容器共用日志组，用前缀区分。
    log_configuration {
      log_driver = "awslogs"

      options = {
        "awslogs-group"         = local.log_group[each.key]
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "service-connect"
      }
    }
  }

  dynamic "load_balancer" {
    for_each = each.value.target_group_arn == null ? [] : [each.value.target_group_arn]

    content {
      target_group_arn = load_balancer.value
      container_name   = each.key
      container_port   = each.value.port
    }
  }

  # 只在挂了 ALB 时有意义：给容器启动留时间，否则第一次健康检查就把任务杀了。
  health_check_grace_period_seconds = each.value.target_group_arn == null ? null : 60

  # 滚动更新：先起新任务再停旧的，更新期间容量不下降。
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # 新任务反复起不来时自动回滚，而不是无限重试。缺了这个，一次坏镜像能让部署卡住几十分钟。
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # 强制 Tag 带到每个任务上，成本中心才能按任务归集。
  propagate_tags = "SERVICE"

  tags = { Name = local.name[each.key] }

  lifecycle {
    # task_definition：CodeBuild 发版会把服务指到新 revision，不忽略的话下次 apply 会拽回来。
    # desired_count：Auto Scaling 会改它。
    ignore_changes = [task_definition, desired_count]

    # 不挂 ALB 又没有容器健康检查的话，进程挂死不退出时 ECS 不会替换它。
    precondition {
      condition     = each.value.target_group_arn != null || each.value.health_check_command != null
      error_message = "服务 ${each.key} 既没挂 ALB 目标组、也没给 health_check_command，等于没有任何健康检查。"
    }
  }
}
