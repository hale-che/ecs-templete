# Pure JSON generation module: no provider, resource, or data source; creates and attaches no IAM roles. | 纯 JSON 生成模块：无 provider、resource、data source，不创建或关联 IAM 角色。
terraform {
  required_version = "~> 1.6.0"
}

locals {
  ecs_prefix  = "arn:${var.partition}:ecs:${var.region}:${var.account_id}"
  cluster     = "${local.ecs_prefix}:cluster/${var.cluster_name}"
  environment = element(reverse(split("-", var.cluster_name)), 0)
  name_prefix = trimsuffix(var.cluster_name, "-ecs-fargate-${local.environment}")
  names       = [for service in keys(var.service_repositories) : "${local.name_prefix}-${service}-${local.environment}"]
  build_names = [for service in keys(var.service_repositories) : "${local.name_prefix}-${service}-build-${local.environment}"]
  services    = [for name in local.names : "${local.ecs_prefix}:service/${var.cluster_name}/${name}"]
  projects    = [for name in local.build_names : "arn:${var.partition}:codebuild:${var.region}:${var.account_id}:project/${name}"]
  builds      = [for name in local.build_names : "arn:${var.partition}:codebuild:${var.region}:${var.account_id}:build/${name}:*"]
  log_groups  = concat([for name in local.names : "/ecs/${name}"], [for name in local.build_names : "/aws/codebuild/${name}"])
  logs        = [for name in local.log_groups : "arn:${var.partition}:logs:${var.region}:${var.account_id}:log-group:${name}"]

  readonly_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RegionalDiscoveryAndMetrics"
        Effect = "Allow"
        # These APIs cannot be scoped to project ARNs and expose regional resource lists, metrics, and task definition metadata. | 这些 API 不支持项目 ARN 限定，会暴露当前区域的列表/指标/任务定义元数据。
        Action = [
          "ecs:ListClusters", "ecs:ListTaskDefinitions", "ecs:ListTaskDefinitionFamilies",
          "ecs:DescribeTaskDefinition", "logs:DescribeLogGroups", "codebuild:ListProjects",
          "cloudwatch:ListMetrics", "cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics",
        ]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = var.region } }
      },
      {
        Sid       = "ListProjectServicesAndTasks"
        Effect    = "Allow"
        Action    = ["ecs:ListServices", "ecs:ListTasks"]
        Resource  = "*"
        Condition = { ArnEquals = { "ecs:cluster" = local.cluster } }
      },
      {
        Sid      = "DescribeProjectCluster"
        Effect   = "Allow"
        Action   = ["ecs:DescribeClusters"]
        Resource = [local.cluster]
      },
      {
        Sid      = "DescribeProjectServices"
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices"]
        Resource = local.services
      },
      {
        Sid      = "DescribeProjectTasks"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks"]
        Resource = ["${local.ecs_prefix}:task/${var.cluster_name}/*"]
      },
      {
        Sid      = "ReadProjectLogGroups"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogStreams", "logs:FilterLogEvents"]
        Resource = [for arn in local.logs : "${arn}:*"]
      },
      {
        Sid      = "ReadProjectLogStreams"
        Effect   = "Allow"
        Action   = ["logs:GetLogEvents"]
        Resource = [for arn in local.logs : "${arn}:log-stream:*"]
      },
      {
        Sid      = "DescribeProjectBuilds"
        Effect   = "Allow"
        Action   = ["codebuild:BatchGetProjects", "codebuild:ListBuildsForProject"]
        Resource = local.projects
      },
      {
        Sid      = "ReadProjectBuildResults"
        Effect   = "Allow"
        Action   = ["codebuild:BatchGetBuilds"]
        Resource = local.builds
      },
      {
        Sid      = "InspectProjectImages"
        Effect   = "Allow"
        Action   = ["ecr:DescribeRepositories", "ecr:DescribeImages", "ecr:ListImages"]
        Resource = [for repository in distinct(values(var.service_repositories)) : "arn:${var.partition}:ecr:${var.region}:${var.account_id}:repository/${repository}"]
      },
    ]
  }

  # Attach alongside the readonly policy. Existing CodeBuild projects handle releases; do not grant personnel direct task definition registration or image push permissions. | 与只读策略一起关联。发布由现有 CodeBuild 执行，不给人员直接注册任务定义或推镜像的权限。
  operations_policy = {
    Version = "2012-10-17"
    Statement = concat(
      [for index, name in local.names : {
        Sid      = "UpdateService${index}"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService"]
        Resource = [local.services[index]]
        Condition = {
          ArnEquals       = { "ecs:cluster" = local.cluster }
          ArnLikeIfExists = { "ecs:task-definition" = "${local.ecs_prefix}:task-definition/${name}:*" }
          BoolIfExists    = { "ecs:enable-execute-command" = "false" }
        }
      }],
      [
        {
          Sid    = "PassExistingEcsRoles"
          Effect = "Allow"
          Action = ["iam:PassRole"]
          Resource = flatten([for name in local.names : [
            "arn:${var.partition}:iam::${var.account_id}:role/${trimsuffix(name, "-${local.environment}")}-ecs-execution-role-${local.environment}",
            "arn:${var.partition}:iam::${var.account_id}:role/${trimsuffix(name, "-${local.environment}")}-ecs-task-role-${local.environment}",
          ]])
          Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
        },
        {
          Sid      = "StartConfiguredBuilds"
          Effect   = "Allow"
          Action   = ["codebuild:StartBuild"]
          Resource = local.projects
          # Use only the project configuration; prevent StartBuild overrides of build commands, targets, and service roles. | 只允许使用项目配置，避免通过 StartBuild 改写构建命令、目标或服务角色。
          # sourceVersion is not restricted by these conditions; a branch or commit in the repository can still be selected. | sourceVersion 不在这些条件内，仍可选择仓库中的分支/commit。
          Condition = {
            Null = { for key in [
              "codebuild:source.buildspec", "codebuild:source.location", "codebuild:source.auth.type",
              "codebuild:source.auth.resource", "codebuild:secondarySources", "codebuild:serviceRole",
              "codebuild:environment.environmentVariables", "codebuild:environment.image",
              "codebuild:environment.imagePullCredentialsType", "codebuild:environment.registryCredential",
              "codebuild:environment.privilegedMode", "codebuild:artifacts", "codebuild:secondaryArtifacts",
              "codebuild:logsConfig", "codebuild:cache", "codebuild:encryptionKey",
            ] : key => "true" }
          }
        },
        {
          Sid    = "StopProjectBuilds"
          Effect = "Allow"
          Action = ["codebuild:StopBuild"]
          # StopBuild uses the project IAM resource type, not build. | StopBuild 的 IAM 资源类型是 project，不是 build。
          Resource = local.projects
        },
      ],
    )
  }
}
