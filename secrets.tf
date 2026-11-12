# Create only the secret container, not aws_secretsmanager_secret_version, because secret values would enter state. | 只建 Secret 容器，刻意不建 aws_secretsmanager_secret_version —— 那样值会进 state。
# The initial secret value must be set manually after the first deployment; see the Secrets section in README. | 代价是首次部署要手工填一次值，见 README 的「密钥」一节。
resource "aws_secretsmanager_secret" "tls" {
  name        = local.tls_secret_name
  description = "TLS cert and key for ${local.cluster_name}, base64 encoded. Value set out of band."
  kms_key_id  = aws_kms_key.secrets.arn

  # Secrets Manager uses soft deletion; the name remains reserved during the recovery window, which defaults to 30 days. | Secrets Manager 是软删除，删掉后名字仍被占用（默认 30 天恢复期）。
  # 0 means immediate permanent deletion, avoiding already scheduled for deletion errors during repeated nonproduction destroy/apply cycles. | 0 = 立即永久删除，否则非生产反复 destroy/apply 会撞 already scheduled for deletion。
  recovery_window_in_days = var.environment == "prd" ? 30 : 0

  tags = { Name = local.tls_secret_name }
}
