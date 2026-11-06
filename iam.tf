# 每个服务一套执行角色 + 任务角色。执行角色给 ECS 代理（拉镜像、写日志、取密钥），
# 任务角色给业务代码。不共用：共用等于把所有服务的权限并集发给每一个服务。

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # 防混淆代理：限定只有本账号本区域的 ECS 任务能扮演。
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
# 执行角色
# ---------------------------------------------------------------------------

resource "aws_iam_role" "execution" {
  for_each = var.services

  name               = "${local.name[each.key]}-ecs-execution-role"
  description        = "ECS agent role for ${local.name[each.key]}. Managed by Terraform."
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = { Name = "${local.name[each.key]}-ecs-execution-role" }

  lifecycle {
    precondition {
      condition     = length("${local.name[each.key]}-ecs-execution-role") <= 64
      error_message = "角色名超过 IAM 的 64 字符上限，缩短 project 或服务名。"
    }
  }
}

data "aws_iam_policy_document" "execution" {
  for_each = var.services

  # ECR 登录令牌是账号级操作，API 不接受资源限定，只能是 "*"。
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

  # 只支持 Secrets Manager。改用 SSM Parameter Store 要在这里加 ssm:GetParameters。
  dynamic "statement" {
    for_each = length(local.secret_arns[each.key]) > 0 ? [1] : []

    content {
      sid       = "ReadOwnSecrets"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = local.secret_arns[each.key]
    }
  }

}

resource "aws_iam_role_policy" "execution" {
  for_each = var.services

  name   = "${local.name[each.key]}-ecs-execution-policy"
  role   = aws_iam_role.execution[each.key].id
  policy = data.aws_iam_policy_document.execution[each.key].json
}

# ---------------------------------------------------------------------------
# 任务角色
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task" {
  for_each = var.services

  name               = "${local.name[each.key]}-ecs-task-role"
  description        = "Application role for ${local.name[each.key]}. Managed by Terraform."
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = { Name = "${local.name[each.key]}-ecs-task-role" }
}

locals {
  # 没有自定义权限的服务不建空策略，空的 policy document 会被 API 拒绝。
  services_with_task_policy = {
    for k, s in var.services : k => s if length(s.task_role_policy_statements) > 0
  }
}

data "aws_iam_policy_document" "task" {
  for_each = local.services_with_task_policy

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

  name   = "${local.name[each.key]}-ecs-task-policy"
  role   = aws_iam_role.task[each.key].id
  policy = data.aws_iam_policy_document.task[each.key].json
}

# ---------------------------------------------------------------------------
# CodeBuild 服务角色
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "codebuild_assume" {
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
  }
}

resource "aws_iam_role" "codebuild" {
  for_each = var.services

  name               = "${local.name[each.key]}-build-role"
  description        = "CodeBuild role for ${local.name[each.key]}. Managed by Terraform."
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json

  tags = { Name = "${local.name[each.key]}-build-role" }
}

data "aws_iam_policy_document" "codebuild" {
  for_each = var.services

  statement {
    sid       = "WriteOwnBuildLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.build_log_stream_arn[each.key]]
  }

  # ECR 登录令牌是账号级操作，API 不接受资源限定。
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
  }

  # 方案 B（注册新 revision）才需要下面两条。定了方案 A 就删掉。
  # Task Definition 的 API 不支持资源限定，只能是 "*"。
  statement {
    sid       = "RegisterTaskDefinition"
    effect    = "Allow"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
    resources = ["*"]
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

  name   = "${local.name[each.key]}-build-policy"
  role   = aws_iam_role.codebuild[each.key].id
  policy = data.aws_iam_policy_document.codebuild[each.key].json
}
