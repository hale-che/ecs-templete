# One CodeBuild project per service. Keep buildspec in the application repository and inject its required values here.
# GitHub credentials are account-wide and configured manually once, outside Terraform; see README.

resource "aws_cloudwatch_log_group" "build" {
  for_each = var.services

  # Create the log group explicitly because groups created by CodeBuild never expire.
  name              = "/aws/codebuild/${local.build_name[each.key]}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn

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
    image        = var.codebuild_image
    type         = "LINUX_CONTAINER"

    # docker build requires a Docker daemon; builds fail without it.
    privileged_mode = true

    # Do not hardcode these values in buildspec; they follow the selected environment automatically.
    environment_variable {
      name  = "ECR_REPO"
      value = "${local.ecr_registry}/${each.value.repository}"
    }

    # IMAGE_TAG is generated once by buildspec at build time (Asia/Shanghai, yyyyMMddHHmmss).
    # services.*.image_tag pins the initial ECS image only; do not inject it into builds.

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
