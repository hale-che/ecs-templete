# One security group per service, following the SBP port matrix; existing shared SGs are no longer used.
# VPC comes from the subnets and ALB SGs from the target groups, so no extra inputs are needed.
data "aws_subnet" "first" {
  id = var.subnet_ids[0]
}

data "aws_vpc" "this" {
  id = data.aws_subnet.first.vpc_id
}

# S3 gateway endpoint prefix list (ECR image layers, file bucket); China regions may use the cn. prefix.
data "aws_ec2_managed_prefix_list" "s3" {
  filter {
    name   = "prefix-list-name"
    values = ["com.amazonaws.${var.region}.s3", "cn.com.amazonaws.${var.region}.s3"]
  }
}

data "aws_lb_target_group" "this" {
  for_each = { for k, s in var.services : k => s.target_group_arn if s.target_group_arn != null }
  arn      = each.value

  lifecycle {
    postcondition {
      condition     = length(self.load_balancer_arns) > 0
      error_message = "Target group ${each.value} is not attached to an ALB listener yet; ALB ingress cannot be derived."
    }
  }
}

data "aws_lb" "this" {
  for_each = toset(flatten([for tg in data.aws_lb_target_group.this : tolist(tg.load_balancer_arns)]))
  arn      = each.value
}

locals {
  database_port = 5432

  alb_security_group_ids = {
    for k, tg in data.aws_lb_target_group.this :
    k => distinct(flatten([for lb in tg.load_balancer_arns : data.aws_lb.this[lb].security_groups]))
  }

  # ALB -> frontend on the container port.
  sg_ingress_from_alb = merge([
    for k, sgs in local.alb_security_group_ids : {
      for sg in sgs : "${k}:${sg}" => { service = k, source = sg, port = var.services[k].port }
    }
  ]...)

  # Service -> service (e.g. frontend -> backend 8002), declared on the receiving side via ingress_from_services.
  sg_service_links = merge([
    for k, s in var.services : {
      for src in s.ingress_from_services : "${src}:${k}" => { from = src, to = k, port = s.port }
    }
  ]...)
}

resource "aws_security_group" "service" {
  for_each = var.services

  name        = "${local.name_prefix}-${each.key}-sg-${var.environment}"
  description = "ECS service ${local.name[each.key]}. Managed by Terraform."
  vpc_id      = data.aws_vpc.this.id

  tags = { Name = "${local.name_prefix}-${each.key}-sg-${var.environment}" }
}

resource "aws_vpc_security_group_ingress_rule" "from_alb" {
  for_each = local.sg_ingress_from_alb

  security_group_id            = aws_security_group.service[each.value.service].id
  referenced_security_group_id = each.value.source
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = "HTTPS from ALB"
}

resource "aws_vpc_security_group_ingress_rule" "from_service" {
  for_each = local.sg_service_links

  security_group_id            = aws_security_group.service[each.value.to].id
  referenced_security_group_id = aws_security_group.service[each.value.from].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = "HTTPS from ${each.value.from}"
}

resource "aws_vpc_security_group_egress_rule" "to_service" {
  for_each = local.sg_service_links

  security_group_id            = aws_security_group.service[each.value.from].id
  referenced_security_group_id = aws_security_group.service[each.value.to].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = "HTTPS to ${each.value.to}"
}

# Interface endpoints (ECR API / dkr, Logs, Secrets Manager) inside the VPC.
resource "aws_vpc_security_group_egress_rule" "vpc_endpoints" {
  for_each = var.services

  security_group_id = aws_security_group.service[each.key].id
  cidr_ipv4         = data.aws_vpc.this.cidr_block
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS to VPC interface endpoints"
}

resource "aws_vpc_security_group_egress_rule" "s3" {
  for_each = var.services

  security_group_id = aws_security_group.service[each.key].id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.s3.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS to S3 gateway endpoint"
}

resource "aws_vpc_security_group_egress_rule" "database" {
  for_each = { for k, s in var.services : k => s if s.database_access }

  security_group_id = aws_security_group.service[each.key].id
  cidr_ipv4         = data.aws_vpc.this.cidr_block
  ip_protocol       = "tcp"
  from_port         = local.database_port
  to_port           = local.database_port
  description       = "PostgreSQL over TLS to RDS"
}

# Entra ID and Microsoft Graph are public endpoints reached through NAT or proxy.
resource "aws_vpc_security_group_egress_rule" "internet_https" {
  for_each = { for k, s in var.services : k => s if s.internet_https_egress }

  security_group_id = aws_security_group.service[each.key].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS to Entra ID and Microsoft Graph"
}
