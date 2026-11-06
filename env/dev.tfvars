region      = "cn-north-1"
project     = "REPLACE_ME"
environment = "DEV"

# AZ 下发的强制 Tag 清单，键名以清单为准。
mandatory_tags = {
  AccountOwner = "REPLACE_ME"
  Maintainer   = "REPLACE_ME"
  CMDB         = "REPLACE_ME"
  RequestID    = "REPLACE_ME"
  CostCenter   = "REPLACE_ME"
}

# DEV 推 dev 分支自动构建部署。
enable_build_webhook = true

log_retention_days = 30

# AZ 提供的私有子网，跨可用区至少两个。
subnet_ids = [
  "subnet-REPLACE_ME-az-a",
  "subnet-REPLACE_ME-az-b",
]

# key 是服务名，也是容器名，还会拼进资源名：AZ-CNRDIT-DEV-<project>-<服务名>。
# security_group_ids 和 target_group_arn 都是 AZ 创建后给的。
services = {
  "frontend-ext" = {
    cpu           = 512 # 0.5 vCPU
    memory        = 1024
    repository    = "REPLACE_ME-frontend-ext"
    repo_url      = "https://github.com/REPLACE_ME/REPLACE_ME-frontend-ext.git"
    branch        = "dev"
    tag           = "latest"
    port          = 8443
    desired_count = 1

    security_group_ids = ["sg-REPLACE_ME"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV = "dev"
      # nginx 反代 /api 的上游，Service Connect 的名字，三个环境一样。
      # 不校验后端证书，所以 SAN 不构成约束。
      BACKEND_URL = "https://backend-service:8002"
    }

  }

  "frontend-int" = {
    cpu           = 512
    memory        = 1024
    repository    = "REPLACE_ME-frontend-int"
    repo_url      = "https://github.com/REPLACE_ME/REPLACE_ME-frontend-int.git"
    branch        = "dev"
    tag           = "latest"
    port          = 8443
    desired_count = 1

    security_group_ids = ["sg-REPLACE_ME"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "dev"
      BACKEND_URL = "https://backend-service:8002"
    }

  }

  "backend" = {
    cpu           = 2048 # 2 vCPU
    memory        = 4096
    repository    = "REPLACE_ME-backend"
    repo_url      = "https://github.com/REPLACE_ME/REPLACE_ME-backend.git"

    # 后端读写应用文件桶，任务角色权限自动生成。
    file_bucket_access = true
    branch        = "dev"
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
      APP_ENV = "dev"
    }

    # 环境变量名 -> Secrets Manager ARN。执行角色权限自动按这里的 ARN 收口。
    # TLS 证书由 Terraform 自动注入，不用在这里写。
    # 这里只放 AZ 给的密钥，比如 RDS 密码：
    #   secrets = { DB_PASSWORD = "arn:aws-cn:secretsmanager:...:secret:xxx-AbCdEf:password::" }
  }
}
