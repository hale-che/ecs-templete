region      = "cn-north-1"
project     = "aiec"
environment = "prd"

mandatory_tags = {
  applicationname  = "AIEC Platform"
  applicationowner = "yongguo.he@astrazeneca.com"
  "Cost Center"    = "4109900005"
  "IDMD No"        = "CSE-13668"
  applicationid    = "SNSVC0008172"
  environment      = "Prod"
  creationdate     = "xx/xx/2026" # Before deployment, enter the actual creation date in the format required by AZ. | 部署前按 AZ 要求填写实际创建日期。
}

# No automatic trigger; start builds manually or from an external pipeline. | 不自动触发，构建由人工或外部流水线发起。
enable_build_webhook = false

log_retention_days = 365

# Create one S3 CMK and one TLS Secret CMK per environment. Enter the IAM ARNs of AZ administrators and the actual deployment role. | 本模板创建每环境 S3 / TLS Secret 两把 CMK。填 AZ 管理员及实际部署角色的 IAM ARN。
kms_administrator_arns = [
  "arn:aws-cn:iam::REPLACE_ME:role/REPLACE_ME",
]

# Already supplied by AZ; share subnets and the security group with DEV and PPD. | AZ 已提供；与 DEV / PPD 共用子网和 SG。
subnet_ids = [
  "subnet-8c4c1efb",
  "subnet-0886d048a9ec36d81",
]

# Use a fixed production image tag instead of latest. Run exactly two tasks per service without Auto Scaling. | 生产的 tag 填确定版本，不要 latest。三个服务固定各 2 个任务，不启用自动扩缩容。
services = {
  "frontend-ext" = {
    cpu           = 1024 # 1 vCPU per task, with 2 tasks | 1 vCPU × 2 个任务
    memory        = 2048
    repository    = "REPLACE_ME-frontend-ext"
    repo_url      = "https://github.com/AZU-RDIT/AIEC.git"
    buildspec     = "frontend-ext/buildspec.yml"
    branch        = "main"
    tag           = "REPLACE_ME"
    port          = 8443
    desired_count = 2

    security_group_ids = ["sg-0960c20f67f17cb68"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "prd"
      BACKEND_URL = "https://backend-service:8002"
    }

  }

  "frontend-int" = {
    cpu           = 1024
    memory        = 2048
    repository    = "REPLACE_ME-frontend-int"
    repo_url      = "https://github.com/AZU-RDIT/AIEC.git"
    buildspec     = "frontend-int/buildspec.yml"
    branch        = "main"
    tag           = "REPLACE_ME"
    port          = 8443
    desired_count = 2

    security_group_ids = ["sg-0960c20f67f17cb68"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "prd"
      BACKEND_URL = "https://backend-service:8002"
    }

  }

  "backend" = {
    cpu        = 4096 # 4 vCPU per task, with 2 tasks | 4 vCPU × 2 个任务
    memory     = 8192
    repository = "REPLACE_ME-backend"
    repo_url   = "https://github.com/AZU-RDIT/AIEC.git"
    buildspec  = "backend/buildspec.yml"
    branch     = "main"

    # The backend reads and writes the application file bucket; task role permissions are generated automatically. | 后端读写应用文件桶，任务角色权限自动生成。
    file_bucket_access = true
    tag                = "REPLACE_ME"
    port               = 8002
    desired_count      = 2

    security_group_ids   = ["sg-0960c20f67f17cb68"]
    service_connect_name = "backend-service"

    # Without an ALB health check, the container health check is the only health signal. | 没有 ALB 健康检查，容器健康检查是唯一的健康信号。
    # -k skips self-signed certificate verification; curl must be installed in the image. | -k 跳过自签证书校验；要求镜像里有 curl。
    health_check_command = "curl -fsSk https://localhost:8002/health || exit 1"

    environment = {
      APP_ENV = "prd"
    }

    # Terraform injects TLS certificates automatically; do not repeat them here. | TLS 证书由 Terraform 自动注入，不用在这里写。
    # Only add secrets supplied by AZ here, such as the RDS password: | 这里只放 AZ 给的密钥，比如 RDS 密码：
    # secrets = { DB_PASSWORD = "arn:aws-cn:secretsmanager:...:secret:xxx-AbCdEf:password::" } | 示例：通过 Secrets Manager 引用数据库密码
    # If this secret uses a CMK, also specify: | 该 Secret 若使用 CMK，还要填：
    # secrets_kms_key_arns = ["arn:aws-cn:kms:cn-north-1:<account-id>:key/<key-id>"] | 示例：指定该外部密钥使用的 KMS key ARN
  }
}
