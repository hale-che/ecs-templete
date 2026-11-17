# Secret containers only; values are entered manually after apply, so they never reach code or state.
# Tasks fail with ResourceInitializationError until a value is set.
resource "aws_secretsmanager_secret" "this" {
  for_each = var.managed_secrets

  name        = "${local.secret_name_prefix}/${each.key}"
  description = each.value

  tags = { Name = "${local.secret_name_prefix}/${each.key}" }
}
