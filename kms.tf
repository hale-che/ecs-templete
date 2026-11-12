# Per the latest review, create separate S3 and TLS Secret CMKs for each environment; AZ manages the keys. | 按最新评审要求：每环境创建自己的 S3 / TLS Secret CMK，AZ 接管运维。
# Use role ARN condition strings in the key policy to avoid a key -> role -> key dependency cycle. | Key Policy 先使用角色 ARN 条件字符串，避免 key -> role -> key 的循环依赖。
locals {
  # KMS ViaService uses amazonaws.com in every partition; do not use the aws-cn DNS suffix. | KMS ViaService 在所有分区都使用 amazonaws.com，不能套用 aws-cn 的 DNS 后缀。
  kms_s3_via_service      = "s3.${var.region}.amazonaws.com"
  kms_secrets_via_service = "secretsmanager.${var.region}.amazonaws.com"

  account_root_arn       = "arn:${local.partition}:iam::${local.account_id}:root"
  tls_secret_arn_pattern = "arn:${local.partition}:secretsmanager:${var.region}:${local.account_id}:secret:${local.tls_secret_name}-*"
  file_key_role_arns     = [for k, s in var.services : "arn:${local.partition}:iam::${local.account_id}:role/${local.task_role_name[k]}" if s.file_bucket_access]
  tls_key_role_arns      = [for name in values(local.execution_role_name) : "arn:${local.partition}:iam::${local.account_id}:role/${name}"]

  secret_kms_key_arns = {
    for k, s in var.services : k => distinct(concat(
      [aws_kms_key.secrets.arn],
      s.secrets_kms_key_arns,
    ))
  }
}

data "aws_iam_policy_document" "kms_administration" {
  statement {
    sid       = "RootPolicyRecovery"
    actions   = ["kms:PutKeyPolicy"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.account_root_arn]
    }
    # Allow only the actual root identity to recover the policy, without delegating key usage to arbitrary IAM identities in the account. | 仅实际 root 身份恢复策略，不将整个账号的使用权限委派给任意 IAM 身份。
    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = [local.account_root_arn]
    }
  }

  statement {
    sid = "NamedKeyAdministrators"
    actions = [
      "kms:DescribeKey", "kms:GetKeyPolicy", "kms:PutKeyPolicy", "kms:ListResourceTags",
      "kms:TagResource", "kms:UntagResource", "kms:UpdateKeyDescription",
      "kms:EnableKey", "kms:DisableKey", "kms:EnableKeyRotation", "kms:DisableKeyRotation",
      "kms:GetKeyRotationStatus", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
      "kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = var.kms_administrator_arns
    }
  }
}

data "aws_iam_policy_document" "file_key" {
  source_policy_documents = [data.aws_iam_policy_document.kms_administration.json]

  dynamic "statement" {
    for_each = length(local.file_key_role_arns) > 0 ? [1] : []
    content {
      sid       = "UseFileKeyForProjectTasks"
      actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = [local.account_root_arn]
      }
      condition {
        test     = "ArnEquals"
        variable = "aws:PrincipalArn"
        values   = local.file_key_role_arns
      }
      condition {
        test     = "StringEquals"
        variable = "aws:PrincipalTag/Project"
        values   = [var.project]
      }
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = [local.kms_s3_via_service]
      }
      condition {
        test     = "StringLike"
        variable = "kms:EncryptionContext:aws:s3:arn"
        values   = ["arn:${local.partition}:s3:::${local.file_bucket_name}", "arn:${local.partition}:s3:::${local.file_bucket_name}/*"]
      }
    }
  }
}

data "aws_iam_policy_document" "secret_key" {
  source_policy_documents = [data.aws_iam_policy_document.kms_administration.json]

  statement {
    sid       = "DecryptTlsForProjectExecutionRoles"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.account_root_arn]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = local.tls_key_role_arns
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/Project"
      values   = [var.project]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.kms_secrets_via_service]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:SecretARN"
      values   = [local.tls_secret_arn_pattern]
    }
  }

  statement {
    sid       = "ProvisionTlsThroughSecretsManager"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = var.kms_administrator_arns
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.kms_secrets_via_service]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:SecretARN"
      values   = [local.tls_secret_arn_pattern]
    }
  }
}

resource "aws_kms_key" "files" {
  description              = "S3 file encryption for ${local.name_prefix}-${var.environment}"
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = true
  deletion_window_in_days  = 30
  policy                   = data.aws_iam_policy_document.file_key.json
  tags                     = { Name = "${local.name_prefix}-files-kms-${var.environment}" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "files" {
  name          = "alias/${local.name_prefix}-files-kms-${var.environment}"
  target_key_id = aws_kms_key.files.key_id
}

resource "aws_kms_key" "secrets" {
  description              = "TLS Secret encryption for ${local.name_prefix}-${var.environment}"
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = true
  deletion_window_in_days  = 30
  policy                   = data.aws_iam_policy_document.secret_key.json
  tags                     = { Name = "${local.name_prefix}-secrets-kms-${var.environment}" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${local.name_prefix}-secrets-kms-${var.environment}"
  target_key_id = aws_kms_key.secrets.key_id
}
