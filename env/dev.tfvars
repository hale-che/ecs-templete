region      = "cn-north-1"
project     = "aiec"
environment = "dev"

# AZ mandatory tags. project controls resource names; applicationname is the application display name. | AZ 强制标签。project 用于资源命名，applicationname 是应用展示名称。
mandatory_tags = {
  applicationname  = "AIEC Platform"
  applicationowner = "yongguo.he@astrazeneca.com"
  "Cost Center"    = "4109900005"
  "IDMD No"        = "CSE-13668"
  applicationid    = "SNSVC0008172"
  environment      = "Dev"
  creationdate     = "11/11/2026" # Before deployment, enter the actual creation date in the format required by AZ. | 部署前按 AZ 要求填写实际创建日期。
}

# Pushes to the dev branch build and push DEV images automatically; a separate release process deploys ECS. | DEV 推 dev 分支自动构建并推送镜像；ECS 部署由独立发布流程执行。
enable_build_webhook = true

log_retention_days = 30

# Create one S3 CMK and one TLS Secret CMK per environment. Enter the IAM ARNs of AZ administrators and the actual deployment role. | 本模板创建每环境 S3 / TLS Secret 两把 CMK。填 AZ 管理员及实际部署角色的 IAM ARN。
kms_administrator_arns = [
  "arn:aws-cn:iam::REPLACE_ME:role/REPLACE_ME",
]

# Private subnets supplied by AZ; all three environments currently share these two subnets and the configured service security group. | AZ 提供的私有子网；当前三个环境共用这两个子网和各服务所填的 SG。
subnet_ids = [
  "subnet-8c4c1efb",
  "subnet-0886d048a9ec36d81",
]

# The map key is both the service and container name and forms resource names: az-cn-rdit-<project>-<service>-dev. | key 是服务名，也是容器名，还会拼进资源名：az-cn-rdit-<project>-<服务名>-dev。
# AZ creates and supplies security_group_ids and target_group_arn. | security_group_ids 和 target_group_arn 都是 AZ 创建后给的。
# All three services share one Git repository; buildspec paths are relative to the repository root. | 三个服务使用同一 Git 仓库，buildspec 路径相对于仓库根目录。
# repository is the service's ECR image repository name, not a Git repository or source directory. | repository 是各自的 ECR 镜像仓库名，不是 Git 仓库或源码目录。
# Initial ECS image: enter an existing yyyyMMddHHmmss tag (Asia/Shanghai). CodeBuild generates a new tag per build. | 初始 ECS 镜像填写已推送的北京时间戳 tag；CodeBuild 每次构建独立生成新 tag。
services = {
  "frontend-ext" = {
    cpu           = 512 # 0.5 vCPU | 0.5 个虚拟 CPU
    memory        = 1024
    repository    = "REPLACE_ME-frontend-ext"
    repo_url      = "https://github.com/AZU-RDIT/AIEC.git"
    buildspec     = "frontend-ext/buildspec.yml" # External frontend | 外网前端
    branch        = "dev"
    tag           = "REPLACE_ME_IMAGE_TAG"
    port          = 8443
    desired_count = 1

    security_group_ids = ["sg-0960c20f67f17cb68"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "dev"
      BACKEND_URL = "https://backend-service:8002"
    }

  }

  "frontend-int" = {
    cpu           = 512
    memory        = 1024
    repository    = "REPLACE_ME-frontend-int"
    repo_url      = "https://github.com/AZU-RDIT/AIEC.git"
    buildspec     = "frontend-int/buildspec.yml" # Internal frontend | 内网前端
    branch        = "dev"
    tag           = "REPLACE_ME_IMAGE_TAG"
    port          = 8443
    desired_count = 1

    security_group_ids = ["sg-0960c20f67f17cb68"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "dev"
      BACKEND_URL = "https://backend-service:8002"
    }

  }

  "backend" = {
    cpu        = 2048 # 2 vCPU | 2 个虚拟 CPU
    memory     = 4096
    repository = "REPLACE_ME-backend"
    repo_url   = "https://github.com/AZU-RDIT/AIEC.git"
    buildspec  = "backend/buildspec.yml" # Backend | 后端

    # The backend reads and writes the application file bucket; task role permissions are generated automatically. | 后端读写应用文件桶，任务角色权限自动生成。
    file_bucket_access = true
    branch             = "dev"
    tag                = "REPLACE_ME_IMAGE_TAG"
    port               = 8002
    desired_count      = 1

    security_group_ids   = ["sg-0960c20f67f17cb68"]
    service_connect_name = "backend-service"

    # Without an ALB health check, the container health check is the only health signal. | 没有 ALB 健康检查，容器健康检查是唯一的健康信号。
    # -k skips self-signed certificate verification; curl must be installed in the image. | -k 跳过自签证书校验；要求镜像里有 curl。
    health_check_command = "curl -fsSk https://localhost:8002/health || exit 1"

    environment = {
      APP_ENV = "dev"
    }

    # Map environment variable names to Secrets Manager ARNs; execution role permissions are scoped to these ARNs automatically. | 环境变量名 -> Secrets Manager ARN。执行角色权限自动按这里的 ARN 收口。
    # Terraform injects TLS certificates automatically; do not repeat them here. | TLS 证书由 Terraform 自动注入，不用在这里写。
    # Only add secrets supplied by AZ here, such as the RDS password: | 这里只放 AZ 给的密钥，比如 RDS 密码：
    # secrets = { DB_PASSWORD = "arn:aws-cn:secretsmanager:...:secret:xxx-AbCdEf:password::" } | 示例：通过 Secrets Manager 引用数据库密码
    # If this secret uses a CMK, also specify: | 该 Secret 若使用 CMK，还要填：
    # secrets_kms_key_arns = ["arn:aws-cn:kms:cn-north-1:<account-id>:key/<key-id>"] | 示例：指定该外部密钥使用的 KMS key ARN
  }
}
