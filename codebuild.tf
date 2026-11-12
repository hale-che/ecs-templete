# One CodeBuild project per service. Keep buildspec in the application repository and inject its required values here. | 一个服务一个 CodeBuild 项目。buildspec 放应用仓库，这里只注入它需要的值。
# GitHub credentials are account-wide and configured manually once, outside Terraform; see README. | GitHub 凭证是账号级的，手工建一次，不由 Terraform 管（见 README）。

resource "aws_cloudwatch_log_group" "build" {
  for_each = var.services

  # Create the log group explicitly because groups created by CodeBuild never expire. | 自己建而不是让 CodeBuild 建：它建出来的日志组永不过期。
  name              = "/aws/codebuild/${local.build_name[each.key]}"
  retention_in_days = var.log_retention_days

  tags = { Name = "/aws/codebuild/${local.build_name[each.key]}" }
}

resource "aws_codebuild_project" "build" {
  for_each = var.services

  name         = local.build_name[each.key]
  description  = "Build and push ${local.name[each.key]} images to ECR. Managed by Terraform."
  service_role = aws_iam_role.codebuild[each.key].arn

  source {
    type                = "GITHUB"
    location            = each.value.repo_url
    buildspec           = each.value.buildspec
    git_clone_depth     = 1
    report_build_status = true
  }

  source_version = each.value.branch

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type = each.value.build_compute_type
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"

    # docker build requires a Docker daemon; builds fail without it. | docker build 要 Docker daemon，少了这个构建直接失败。
    privileged_mode = true

    # Do not hardcode these values in buildspec; they follow the selected environment automatically. | 这几个值 buildspec 里不要硬编码，换环境自动跟着变。
    environment_variable {
      name  = "ECR_REPO"
      value = "${local.ecr_registry}/${each.value.repository}"
    }

    # IMAGE_TAG is generated once by buildspec at build time (Asia/Shanghai, yyyyMMddHHmmss). | IMAGE_TAG 由 buildspec 在构建时生成一次，使用北京时间，精确到秒。
    # services.*.tag pins the initial ECS image only; do not inject it into builds. | services.*.tag 只指定 ECS 初始镜像，不再注入构建环境。

    environment_variable {
      name  = "CLUSTER"
      value = aws_ecs_cluster.this.name
    }

    environment_variable {
      name  = "SERVICE"
      value = aws_ecs_service.this[each.key].name
    }

    environment_variable {
      name  = "TASK_FAMILY"
      value = aws_ecs_task_definition.this[each.key].family
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.build[each.key].name
    }
  }

  tags = { Name = local.build_name[each.key] }
}

# Trigger automatically on push; disabled by default in production. | push 自动触发。生产默认关闭。
resource "aws_codebuild_webhook" "build" {
  for_each = { for k, v in var.services : k => v if var.enable_build_webhook }

  project_name = aws_codebuild_project.build[each.key].name
  build_type   = "BUILD"

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PUSH"
    }

    filter {
      type    = "HEAD_REF"
      pattern = "^refs/heads/${each.value.branch}$"
    }
  }
}
