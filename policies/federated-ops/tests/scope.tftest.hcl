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
    error_message = "Read-only policy must not contain write actions."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(output.operations_policy_json).Statement :
      try(statement.Resource != "*" && !contains(statement.Resource, "*"), false)
    ])
    error_message = "Operations policy must not grant account-wide resources."
  }

  assert {
    condition = toset(flatten([
      for statement in jsondecode(output.operations_policy_json).Statement : statement.Action
    ])) == toset(["ecs:UpdateService", "iam:PassRole", "codebuild:StartBuild", "codebuild:StopBuild"])
    error_message = "Operations may only include the defined service updates, build start/stop, and required PassRole."
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
    error_message = "Each service may only switch to its own task definitions and cannot enable ECS Exec."
  }

  assert {
    condition = one([
      for statement in jsondecode(output.operations_policy_json).Statement : statement
      if statement.Sid == "StartConfiguredBuilds"
    ]).Condition.Null["codebuild:source.buildspec"] == "true"
    error_message = "Must not allow buildspec overrides."
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
    error_message = "After switching account, environment, and service, no example or other-environment grants may remain."
  }

  assert {
    condition     = strcontains(output.readonly_policy_json, "repository/custom/production-api")
    error_message = "ECR grants must use the given repository names, not names guessed from service names."
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
