# One cluster per environment, shared by three services. Fargate services use launch_type directly without a capacity provider.
resource "aws_ecs_cluster" "this" {
  name = local.cluster_name

  setting {
    name = "containerInsights"
    # Billed by metric volume. Set this to disabled to reduce DEV costs.
    value = "enabled"
  }

  tags = { Name = local.cluster_name }
}

resource "aws_service_discovery_http_namespace" "this" {
  name        = lower(local.cluster_name)
  description = "Service Connect namespace for ${local.cluster_name}. Managed by Terraform."

  tags = { Name = lower(local.cluster_name) }
}
