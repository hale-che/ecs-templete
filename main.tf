locals {
  # Fargate 的 CPU/内存组合是固定表，组合错了要到 apply 才报。
  # tomap + tolist 是必须的：值类型不统一时，用变量做下标取不出来。
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

  # 不设 track_latest：Terraform 只认自己注册的那个 revision。CodeBuild 新注册的
  # revision 不会被当成偏移，所以这里不需要 ignore_changes。
  track_latest = false

  lifecycle {
    precondition {
      condition     = contains(lookup(local.fargate_memory, tostring(each.value.cpu), []), each.value.memory)
      error_message = "服务 ${each.key} 的 cpu=${each.value.cpu} 与 memory=${each.value.memory} 不是 Fargate 合法组合，见 ECS 任务大小表。"
    }
  }
}
