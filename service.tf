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

  load_balancer {
    target_group_arn = each.value.target_group_arn
    container_name   = each.key
    container_port   = each.value.port
  }

  # 给容器启动留出时间，否则第一次健康检查就把任务杀了，陷入起-杀循环。
  health_check_grace_period_seconds = 60

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
  }
}
