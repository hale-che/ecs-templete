# 一个环境一个集群，三个服务共用。Fargate 不需要容量提供程序，服务直接用 launch_type。
resource "aws_ecs_cluster" "this" {
  name = local.cluster_name

  setting {
    name = "containerInsights"
    # 按指标量计费。DEV 要省钱的话改成 disabled。
    value = "enabled"
  }

  tags = { Name = local.cluster_name }
}

resource "aws_service_discovery_http_namespace" "this" {
  name        = lower(local.cluster_name)
  description = "Service Connect namespace for ${local.cluster_name}. Managed by Terraform."

  tags = { Name = lower(local.cluster_name) }
}
