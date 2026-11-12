# AZ requires only Policy JSON; do not create personnel roles, an IdP, or policy attachments here. | AZ 只要求 Policy：这里只生成 JSON，不创建人员角色、IdP 或策略关联。
module "federated_ops" {
  source = "./policies/federated-ops"

  partition            = local.partition
  region               = var.region
  account_id           = local.account_id
  cluster_name         = local.cluster_name
  service_repositories = { for name, service in var.services : name => service.repository }
}

output "federated_ops_readonly_policy_json" {
  description = "交给 AZ 关联到 Federated Role 的只读策略。"
  value       = module.federated_ops.readonly_policy_json
}

output "federated_ops_operations_policy_json" {
  description = "交给 AZ 的运维操作附加策略，需同时关联只读策略。"
  value       = module.federated_ops.operations_policy_json
}
