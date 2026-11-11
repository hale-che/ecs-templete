output "readonly_policy_json" {
  description = "AZ 联合登录人员的只读排查权限 JSON。"
  value       = jsonencode(local.readonly_policy)

  precondition {
    condition     = length(jsonencode(local.readonly_policy)) <= 6144
    error_message = "只读策略超过 IAM 单个托管策略的 6144 字符限制，需拆分交付。"
  }
}

output "operations_policy_json" {
  description = "AZ 运维操作附加权限 JSON，与只读策略一起关联；不创建角色。"
  value       = jsonencode(local.operations_policy)

  precondition {
    condition     = length(jsonencode(local.operations_policy)) <= 6144
    error_message = "运维操作策略超过 IAM 单个托管策略的 6144 字符限制，需拆分交付。"
  }
}
