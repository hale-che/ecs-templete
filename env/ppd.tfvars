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

    # TLS 证书由 Terraform 自动注入，不用在这里写。
    # 这里只放 AZ 给的密钥，比如 RDS 密码：
    #   secrets = { DB_PASSWORD = "arn:aws-cn:secretsmanager:...:secret:xxx-AbCdEf:password::" }
  }
}
