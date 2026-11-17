output "readonly_policy_json" {
  description = "Read-only troubleshooting policy JSON for AZ federated users."
  value       = jsonencode(local.readonly_policy)

  precondition {
    condition     = length(jsonencode(local.readonly_policy)) <= 6144
    error_message = "Read-only policy exceeds the 6144-character IAM managed policy limit; split it."
  }
}

output "operations_policy_json" {
  description = "Additional AZ operations policy JSON, attached alongside the read-only policy; no role is created."
  value       = jsonencode(local.operations_policy)

  precondition {
    condition     = length(jsonencode(local.operations_policy)) <= 6144
    error_message = "Operations policy exceeds the 6144-character IAM managed policy limit; split it."
  }
}
