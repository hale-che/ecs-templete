# Each service gets an execution role and a task role. The execution role lets the ECS agent pull images, write logs, and fetch secrets;
# the task role serves application code. Sharing roles would grant every service the union of all permissions.

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # ECS task role SourceArn conditions cannot target a specific cluster; do not invent a Project condition that prevents tasks from starting.
    # Retain account and region conditions against the confused deputy problem; enforce project isolation through resource ARNs, KMS conditions, and PassRole restrictions.
    # https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:ecs:${var.region}:${local.account_id}:*"]
    }
  }
}

# ---------------------------------------------------------------------------
# Execution role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "execution" {
  for_each = var.services

  name               = local.execution_role_name[each.key]
  description        = "ECS agent role for ${local.name[each.key]}. Managed by Terraform."
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = { Name = local.execution_role_name[each.key] }

  lifecycle {
    precondition {
      condition     = length(local.execution_role_name[each.key]) <= 64
      error_message = "Role name exceeds the 64-character IAM limit; shorten project or service name."
    }
  }
}

data "aws_iam_policy_document" "execution" {
  for_each = var.services

  # ECR authorization tokens are account-wide; the API requires Resource "*" and does not support resource-level restrictions.
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [local.ecr_arn[each.key]]
  }

  statement {
    sid       = "WriteOwnLogStreams"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.log_stream_arn[each.key]]
  }

  # Only Secrets Manager is supported. Add ssm:GetParameters here to use SSM Parameter Store.
  dynamic "statement" {
    for_each = length(local.secret_arns[each.key]) > 0 ? [1] : []

    content {
      sid       = "ReadOwnSecrets"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = local.secret_arns[each.key]
    }
  }

  dynamic "statement" {
    for_each = length(local.secret_kms_key_arns[each.key]) > 0 ? [1] : []

    content {
      sid       = "DecryptOwnSecrets"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = local.secret_kms_key_arns[each.key]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = [local.kms_secrets_via_service]
      }

      condition {
        test     = "StringEquals"
        variable = "kms:EncryptionContext:SecretARN"
        values   = local.secret_arns[each.key]
      }
    }
  }
}

resource "aws_iam_role_policy" "execution" {
  for_each = var.services

  name   = "${local.name_prefix}-${each.key}-ecs-execution-policy-${var.environment}"
  role   = aws_iam_role.execution[each.key].id
  policy = data.aws_iam_policy_document.execution[each.key].json
}

# ---------------------------------------------------------------------------
# Task role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task" {
  for_each = var.services

  name               = local.task_role_name[each.key]
  description        = "Application role for ${local.name[each.key]}. Managed by Terraform."
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = { Name = local.task_role_name[each.key] }
}

locals {
  # Do not create policies for services with no permissions; the API rejects empty policy documents.
  services_with_task_policy = {
    for k, s in var.services : k => s
    if length(s.task_role_policy_statements) > 0 || s.file_bucket_access
  }
}

data "aws_iam_policy_document" "task" {
  for_each = local.services_with_task_policy

  # Scope object operations to the file bucket contents; ListBucket requires the bucket ARN without /*.
  dynamic "statement" {
    for_each = each.value.file_bucket_access ? [1] : []

    content {
      sid       = "ReadWriteFileBucketObjects"
      effect    = "Allow"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:GetObjectVersion"]
      resources = ["${aws_s3_bucket.files.arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = each.value.file_bucket_access ? [1] : []

    content {
      sid       = "ListFileBucket"
      effect    = "Allow"
      actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
      resources = [aws_s3_bucket.files.arn]
    }
  }

  dynamic "statement" {
    for_each = each.value.file_bucket_access ? [1] : []

    content {
      sid       = "UseFileBucketKmsKey"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [aws_kms_key.files.arn]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = [local.kms_s3_via_service]
      }

      # With Bucket Keys enabled, the context is the bucket ARN; otherwise, or for older objects, it is the object ARN.
      condition {
        test     = "StringLike"
        variable = "kms:EncryptionContext:aws:s3:arn"
        values   = [aws_s3_bucket.files.arn, "${aws_s3_bucket.files.arn}/*"]
      }
    }
  }

  dynamic "statement" {
    for_each = each.value.task_role_policy_statements

    content {
      sid       = statement.value.sid
      effect    = "Allow"
      actions   = statement.value.actions
      resources = statement.value.resources

      dynamic "condition" {
        for_each = statement.value.conditions

        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_iam_role_policy" "task" {
  for_each = local.services_with_task_policy

  name   = "${local.name_prefix}-${each.key}-ecs-task-policy-${var.environment}"
  role   = aws_iam_role.task[each.key].id
  policy = data.aws_iam_policy_document.task[each.key].json
}

# ---------------------------------------------------------------------------
# CodeBuild service role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "codebuild_assume" {
  for_each = var.services

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    # Scope the trust to the exact build project for this service and environment, rather than the entire account.
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [local.build_project_arn[each.key]]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  for_each = var.services

  name               = local.build_role_name[each.key]
  description        = "CodeBuild role for ${local.name[each.key]}. Managed by Terraform."
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume[each.key].json

  tags = { Name = local.build_role_name[each.key] }
}

data "aws_iam_policy_document" "codebuild" {
  for_each = var.services

  statement {
    sid       = "WriteOwnBuildLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.build_log_stream_arn[each.key]]
  }

  # ECR authorization tokens are account-wide; the API does not support resource-level restrictions.
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushOwnRepo"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
    ]
    resources = [local.ecr_arn[each.key]]
  }

  statement {
    sid       = "DeployOwnService"
    effect    = "Allow"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = [local.service_arn[each.key]]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project]
    }

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.this.arn]
    }
  }

  # The next two statements are needed only for option B, which registers a new revision; remove them if option A is chosen.
  # Register supports family ARNs and request tags; Describe does not support resource-level restrictions, so grant permissions separately.
  statement {
    sid       = "RegisterTaskDefinition"
    effect    = "Allow"
    actions   = ["ecs:RegisterTaskDefinition"]
    resources = ["arn:${local.partition}:ecs:${var.region}:${local.account_id}:task-definition/${local.name[each.key]}:*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = [var.project]
    }

    # Use environment from AZ mandatory tags; key name and case follow mandatory_tags.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/environment"
      values   = [var.mandatory_tags["environment"]]
    }
  }

  statement {
    sid       = "TagOwnNewTaskDefinition"
    effect    = "Allow"
    actions   = ["ecs:TagResource"]
    resources = ["arn:${local.partition}:ecs:${var.region}:${local.account_id}:task-definition/${local.name[each.key]}:*"]
    condition {
      test     = "StringEquals"
      variable = "ecs:CreateAction"
      values   = ["RegisterTaskDefinition"]
    }
  }

  statement {
    sid       = "DescribeTaskDefinitionMetadata"
    effect    = "Allow"
    actions   = ["ecs:DescribeTaskDefinition"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "PassExecutionAndTaskRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.execution[each.key].arn, aws_iam_role.task[each.key].arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "codebuild" {
  for_each = var.services

  name   = "${local.name_prefix}-${each.key}-build-policy-${var.environment}"
  role   = aws_iam_role.codebuild[each.key].id
  policy = data.aws_iam_policy_document.codebuild[each.key].json
}
