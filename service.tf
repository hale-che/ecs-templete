resource "aws_ecs_service" "this" {
  for_each = var.services

  # Complete role permissions, log groups, and file bucket encryption before starting tasks to prevent writes using old encryption settings.
  depends_on = [
    aws_iam_role_policy.execution,
    aws_iam_role_policy.task,
    aws_cloudwatch_log_group.this,
    aws_s3_bucket_policy.files,
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

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.this.arn

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

  # Only relevant when an ALB is attached; allow the container time to start before health checks can stop the task.
  health_check_grace_period_seconds = each.value.target_group_arn == null ? null : 60

  # For rolling updates, start new tasks before stopping old ones to maintain capacity.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Roll back automatically when new tasks repeatedly fail instead of retrying indefinitely and delaying the release.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Propagate mandatory tags to each task so costs can be allocated by cost center.
  propagate_tags = "SERVICE"

  tags = { Name = local.name[each.key] }

  lifecycle {
    # task_definition: CodeBuild releases point the service to a new revision; ignoring changes prevents the next apply from reverting it.
    # Auto Scaling is disabled; Terraform continues to manage desired_count.
    ignore_changes = [task_definition]

    # Without an ALB or container health check, ECS cannot replace an unresponsive process that has not exited.
    precondition {
      condition     = each.value.target_group_arn != null || each.value.health_check_command != null
      error_message = "Service ${each.key} has neither an ALB target group nor a health_check_command, so it has no health check."
    }
  }
}
