resource "aws_cloudwatch_log_group" "this" {
  for_each = var.services

  name              = local.log_group[each.key]
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn

  tags = { Name = local.log_group[each.key] }
}
