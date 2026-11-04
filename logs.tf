resource "aws_cloudwatch_log_group" "this" {
  for_each = var.services

  name              = local.log_group[each.key]
  retention_in_days = var.log_retention_days

  # 强制 CMK 加密。Key Policy 要允许 logs.<region>.amazonaws.com，否则创建报 AccessDenied。
  kms_key_id = local.kms_key_arn

  tags = { Name = local.log_group[each.key] }
}
