locals {
  # Fargate supports fixed CPU and memory combinations; an invalid combination causes an error at apply.
  # tomap and tolist are required because mixed value types cannot be indexed with a variable.
  fargate_memory = tomap({
    "256"   = tolist([512, 1024, 2048])
    "512"   = range(1024, 4096 + 1, 1024)
    "1024"  = range(2048, 8192 + 1, 1024)
    "2048"  = range(4096, 16384 + 1, 1024)
    "4096"  = range(8192, 30720 + 1, 1024)
    "8192"  = range(16384, 61440 + 1, 4096)
    "16384" = range(32768, 122880 + 1, 8192)
  })
}

resource "aws_ecs_task_definition" "this" {
  for_each = var.services

  family = local.name[each.key]

  cpu                      = each.value.cpu
  memory                   = each.value.memory
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  execution_role_arn = aws_iam_role.execution[each.key].arn
  task_role_arn      = aws_iam_role.task[each.key].arn

  container_definitions = jsonencode(local.container_definitions[each.key])

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  tags = { Name = local.name[each.key] }

  # Leave track_latest unset: Terraform tracks only its own registered revision. A revision newly registered by CodeBuild
  # is not treated as drift, so ignore_changes is unnecessary here.
  track_latest = false

  lifecycle {
    precondition {
      condition     = alltrue([for ref in values(each.value.secrets) : startswith(ref, "arn:") || contains(keys(var.managed_secrets), split(":", ref)[0])])
      error_message = "Service ${each.key}: every secrets value must be a full ARN or a key defined in managed_secrets."
    }

    precondition {
      condition     = contains(lookup(local.fargate_memory, tostring(each.value.cpu), []), each.value.memory)
      error_message = "Service ${each.key}: cpu=${each.value.cpu} and memory=${each.value.memory} is not a valid Fargate combination; see the ECS task size table."
    }
  }
}
