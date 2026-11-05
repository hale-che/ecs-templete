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

# 证书 Secret 用的 CMK，和日志那把不是同一把时必须给。
secret_kms_key_arns = ["arn:aws-cn:kms:cn-north-1:REPLACE_ME:key/REPLACE_ME"]

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
    port          = 8443
    desired_count = 2
    min_capacity  = 2
    max_capacity  = 4

    security_group_ids = ["sg-REPLACE_ME"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "prd"
      BACKEND_URL = "https://backend-service:8002"
    }

    # 证书走 Secrets Manager 注入成环境变量，entrypoint 写成文件。
    # 一个 Secret 两个字段（cert / key），ARN 末尾的 :字段名:: 是 ECS 取 JSON 字段的语法。
    secrets = {
      TLS_CERT = "arn:aws-cn:secretsmanager:cn-north-1:REPLACE_ME:secret:REPLACE_ME-AbCdEf:cert::"
      TLS_KEY  = "arn:aws-cn:secretsmanager:cn-north-1:REPLACE_ME:secret:REPLACE_ME-AbCdEf:key::"
    }
  }

  "frontend-int" = {
    cpu           = 1024
    memory        = 2048
    repository    = "REPLACE_ME-frontend-int"
    tag           = "REPLACE_ME"
    port          = 8443
    desired_count = 2
    min_capacity  = 2
    max_capacity  = 4

    security_group_ids = ["sg-REPLACE_ME"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "prd"
      BACKEND_URL = "https://backend-service:8002"
    }

    # 证书走 Secrets Manager 注入成环境变量，entrypoint 写成文件。
    # 一个 Secret 两个字段（cert / key），ARN 末尾的 :字段名:: 是 ECS 取 JSON 字段的语法。
    secrets = {
      TLS_CERT = "arn:aws-cn:secretsmanager:cn-north-1:REPLACE_ME:secret:REPLACE_ME-AbCdEf:cert::"
      TLS_KEY  = "arn:aws-cn:secretsmanager:cn-north-1:REPLACE_ME:secret:REPLACE_ME-AbCdEf:key::"
    }
  }

  "backend" = {
    cpu           = 4096 # 4 vCPU × 2 个任务
    memory        = 8192
    repository    = "REPLACE_ME-backend"
    tag           = "REPLACE_ME"
    port          = 8002
    desired_count = 2
    min_capacity  = 2
    max_capacity  = 4

    security_group_ids = ["sg-REPLACE_ME"]
    # 不接用户流量，不挂 ALB。前端通过 https://backend-service:8002 访问。
    service_connect_name = "backend-service"

    # 没有 ALB 健康检查，容器健康检查是唯一的健康信号。
    # -k 跳过自签证书校验；要求镜像里有 curl。
    health_check_command = "curl -fsSk https://localhost:8002/health || exit 1"

    environment = {
      APP_ENV = "prd"
    }

    # 证书走 Secrets Manager 注入成环境变量，entrypoint 写成文件。
    # 一个 Secret 两个字段（cert / key），ARN 末尾的 :字段名:: 是 ECS 取 JSON 字段的语法。
    secrets = {
      TLS_CERT = "arn:aws-cn:secretsmanager:cn-north-1:REPLACE_ME:secret:REPLACE_ME-AbCdEf:cert::"
      TLS_KEY  = "arn:aws-cn:secretsmanager:cn-north-1:REPLACE_ME:secret:REPLACE_ME-AbCdEf:key::"
    }
  }
}
