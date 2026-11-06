region      = "cn-north-1"
project     = "REPLACE_ME"
environment = "PPD"

mandatory_tags = {
  AccountOwner = "REPLACE_ME"
  Maintainer   = "REPLACE_ME"
  CMDB         = "REPLACE_ME"
  RequestID    = "REPLACE_ME"
  CostCenter   = "REPLACE_ME"
}

# 不自动触发，构建由人工或外部流水线发起。
enable_build_webhook = false

log_retention_days = 90

subnet_ids = [
  "subnet-REPLACE_ME-az-a",
  "subnet-REPLACE_ME-az-b",
]

services = {
  "frontend-ext" = {
    cpu           = 1024 # 1 vCPU
    memory        = 2048
    repository    = "REPLACE_ME-frontend-ext"
    repo_url      = "https://github.com/REPLACE_ME/REPLACE_ME-frontend-ext.git"
    tag           = "latest"
    port          = 8443
    desired_count = 1

    security_group_ids = ["sg-REPLACE_ME"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "ppd"
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
    repo_url      = "https://github.com/REPLACE_ME/REPLACE_ME-frontend-int.git"
    tag           = "latest"
    port          = 8443
    desired_count = 1

    security_group_ids = ["sg-REPLACE_ME"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "ppd"
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
    cpu           = 2048 # 2 vCPU
    memory        = 8192
    repository    = "REPLACE_ME-backend"
    repo_url      = "https://github.com/REPLACE_ME/REPLACE_ME-backend.git"

    # 后端读写应用文件桶，任务角色权限自动生成。
    file_bucket_access = true
    tag           = "latest"
    port          = 8002
    desired_count = 1

    security_group_ids = ["sg-REPLACE_ME"]
    # 不接用户流量，不挂 ALB。前端通过 https://backend-service:8002 访问。
    service_connect_name = "backend-service"

    # 没有 ALB 健康检查，容器健康检查是唯一的健康信号。
    # -k 跳过自签证书校验；要求镜像里有 curl。
    health_check_command = "curl -fsSk https://localhost:8002/health || exit 1"

    environment = {
      APP_ENV = "ppd"
    }

    # 证书走 Secrets Manager 注入成环境变量，entrypoint 写成文件。
    # 一个 Secret 两个字段（cert / key），ARN 末尾的 :字段名:: 是 ECS 取 JSON 字段的语法。
    secrets = {
      TLS_CERT = "arn:aws-cn:secretsmanager:cn-north-1:REPLACE_ME:secret:REPLACE_ME-AbCdEf:cert::"
      TLS_KEY  = "arn:aws-cn:secretsmanager:cn-north-1:REPLACE_ME:secret:REPLACE_ME-AbCdEf:key::"
    }
  }
}
