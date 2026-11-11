variables {
  account_id   = "123456789012"
  cluster_name = "az-cn-rdit-example-ecs-fargate-dev"
  service_repositories = {
    frontend-ext = "example/frontend-ext"
    frontend-int = "example/frontend-int"
    backend      = "example/backend"
  }
}

run "dev_permissions" {
  command = plan

  assert {
    condition = alltrue([
      for statement in jsondecode(output.readonly_policy_json).Statement :
      alltrue([for action in statement.Action :
        can(regex("^[a-z]+:(Describe|List|Get|BatchGet|Filter)", action))
      ])
    ])
    error_message = "只读策略不能包含修改操作。"
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(output.operations_policy_json).Statement :
      try(statement.Resource != "*" && !contains(statement.Resource, "*"), false)
    ])
    error_message = "运维操作不能授权全账号资源。"
  }

  assert {
    condition = toset(flatten([
      for statement in jsondecode(output.operations_policy_json).Statement : statement.Action
    ])) == toset(["ecs:UpdateService", "iam:PassRole", "codebuild:StartBuild", "codebuild:StopBuild"])
    error_message = "操作权限只能包含已明确的服务更新、构建触发/停止及所需角色传递。"
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(output.operations_policy_json).Statement :
      !contains(statement.Action, "ecs:UpdateService") || try(
        statement.Condition.ArnLikeIfExists["ecs:task-definition"] ==
        "arn:aws-cn:ecs:cn-north-1:123456789012:task-definition/${split("/", statement.Resource[0])[2]}:*" &&
        statement.Condition.BoolIfExists["ecs:enable-execute-command"] == "false", false
      )
    ])
    error_message = "每个服务只能切换自己的任务定义，且不能开启 ECS Exec。"
  }

  assert {
    condition = one([
      for statement in jsondecode(output.operations_policy_json).Statement : statement
      if statement.Sid == "StartConfiguredBuilds"
    ]).Condition.Null["codebuild:source.buildspec"] == "true"
    error_message = "不能允许临时覆盖 buildspec。"
  }
}

run "prd_isolation" {
  command = plan

  variables {
    account_id   = "210987654321"
    cluster_name = "az-cn-rdit-another-ecs-fargate-prd"
    service_repositories = {
      backend = "custom/production-api"
    }
  }

  assert {
    condition = alltrue([
      for policy in [output.readonly_policy_json, output.operations_policy_json] :
      !strcontains(policy, "az-cn-rdit-example-") && !strcontains(policy, "123456789012") &&
      !strcontains(policy, "frontend-ext") && !strcontains(policy, "example/backend")
    ])
    error_message = "切换账号、环境和服务后不能残留示例或其他环境的授权。"
  }

  assert {
    condition     = strcontains(output.readonly_policy_json, "repository/custom/production-api")
    error_message = "ECR 授权必须使用输入的实际仓库名，不能按服务名猜测。"
  }
}

run "reject_wildcard_account" {
  command = plan
  variables {
    account_id = "*"
  }
  expect_failures = [var.account_id]
}

run "reject_wildcard_repository" {
  command = plan
  variables {
    service_repositories = { backend = "*" }
  }
  expect_failures = [var.service_repositories]
}
