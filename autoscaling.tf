# 只给同时填了 min_capacity 和 max_capacity 的服务建。现在只有 PRD。
locals {
  autoscaled = {
    for k, s in var.services : k => s
    if s.min_capacity != null && s.max_capacity != null
  }
}

resource "aws_appautoscaling_target" "this" {
  for_each = local.autoscaled

  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this[each.key].name}"
  scalable_dimension = "ecs:service:DesiredCount"

  min_capacity = each.value.min_capacity
  max_capacity = each.value.max_capacity
}

resource "aws_appautoscaling_policy" "cpu" {
  for_each = aws_appautoscaling_target.this

  name               = "${local.name[each.key]}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = each.value.service_namespace
  resource_id        = each.value.resource_id
  scalable_dimension = each.value.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    # 70% 是起步值，要压测后调。
    target_value = 70

    # 扩容快、缩容慢，避免流量抖动时来回伸缩。
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}
