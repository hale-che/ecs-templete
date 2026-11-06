resource "aws_cloudwatch_log_group" "this" {
  for_each = var.services

  name              = local.log_group[each.key]
  retention_in_days = var.log_retention_days

  tags = { Name = local.log_group[each.key] }
}
