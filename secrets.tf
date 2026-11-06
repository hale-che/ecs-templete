# 只建 Secret 容器，刻意不建 aws_secretsmanager_secret_version —— 那样值会进 state。
# 代价是首次部署要手工填一次值，见 README 的「密钥」一节。
resource "aws_secretsmanager_secret" "tls" {
  name        = "${local.cluster_name}/tls"
  description = "TLS cert and key for ${local.cluster_name}, base64 encoded. Value set out of band."

  # Secrets Manager 是软删除，删掉后名字仍被占用（默认 30 天恢复期）。
  # 0 = 立即永久删除，否则非生产反复 destroy/apply 会撞 already scheduled for deletion。
  recovery_window_in_days = var.environment == "PRD" ? 30 : 0

  tags = { Name = "${local.cluster_name}/tls" }
}
