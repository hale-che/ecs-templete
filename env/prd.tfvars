region      = "cn-north-1"
project     = "REPLACE_ME"
environment = "PRD"

mandatory_tags = {
  AccountOwner = "REPLACE_ME"
  Maintainer   = "REPLACE_ME"
  CMDB         = "REPLACE_ME"
  RequestID    = "REPLACE_ME"
  CostCenter   = "REPLACE_ME"
}

kms_key_id         = "alias/REPLACE_ME"
log_retention_days = 365

subnet_ids = [
  "subnet-REPLACE_ME-az-a",
  "subnet-REPLACE_ME-az-b",
]

# 生产的 tag 填确定版本，不要 latest。三个服务都是 2 个任务起步，扩缩容 2-4。
services = {
  "frontend-ext" = {
    cpu           = 1024 # 1 vCPU × 2 个任务
    memory        = 2048
    repository    = "REPLACE_ME-frontend-ext"
    tag           = "REPLACE_ME"
    port          = 80
    desired_count = 2
    min_capacity  = 2
    max_capacity  = 4

    security_group_ids = ["sg-REPLACE_ME"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "prd"
      BACKEND_URL = "http://REPLACE_ME-internal-alb"
    }
  }

  "frontend-int" = {
    cpu           = 1024
    memory        = 2048
    repository    = "REPLACE_ME-frontend-int"
    tag           = "REPLACE_ME"
    port          = 80
    desired_count = 2
    min_capacity  = 2
    max_capacity  = 4

    security_group_ids = ["sg-REPLACE_ME"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "prd"
      BACKEND_URL = "http://REPLACE_ME-internal-alb"
    }
  }

  "backend" = {
    cpu           = 4096 # 4 vCPU × 2 个任务
    memory        = 8192
    repository    = "REPLACE_ME-backend"
    tag           = "REPLACE_ME"
    port          = 8080
    desired_count = 2
    min_capacity  = 2
    max_capacity  = 4

    security_group_ids = ["sg-REPLACE_ME"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV = "prd"
    }

    secrets = {}
  }
}
