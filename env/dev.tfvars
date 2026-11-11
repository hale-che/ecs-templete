region      = "cn-north-1"
project     = "aiec"
environment = "dev"

# AZ 强制标签。project 用于资源命名，applicationname 是应用展示名称。
mandatory_tags = {
  applicationname  = "AIEC Platform"
  applicationowner = "yongguo.he@astrazeneca.com"
  "Cost Center"    = "4109900005"
  "IDMD No"        = "CSE-13326"
  applicationid    = "SNSVC0008172"
  environment      = "Dev"
  creationdate     = "11/11/2026" # 部署前按 AZ 要求填写实际创建日期。
}

# DEV 推 dev 分支自动构建部署。
enable_build_webhook = true

log_retention_days = 30

# 本模板创建每环境 S3 / TLS Secret 两把 CMK。填 AZ 管理员及实际部署角色的 IAM ARN。
kms_administrator_arns = [
  "arn:aws-cn:iam::REPLACE_ME:role/REPLACE_ME",
]

# AZ 提供的私有子网；当前三个环境共用这两个子网和各服务所填的 SG。
subnet_ids = [
  "subnet-8c4c1efb",
  "subnet-0886d048a9ec36d81",
]

# key 是服务名，也是容器名，还会拼进资源名：az-cn-rdit-<project>-<服务名>-dev。
# security_group_ids 和 target_group_arn 都是 AZ 创建后给的。
# 三个服务使用同一 Git 仓库，buildspec 路径相对于仓库根目录。
# repository 是各自的 ECR 镜像仓库名，不是 Git 仓库或源码目录。
services = {
  "frontend-ext" = {
    cpu           = 512 # 0.5 vCPU
    memory        = 1024
    repository    = "REPLACE_ME-frontend-ext"
    repo_url      = "https://github.com/AZU-RDIT/AIEC.git"
    buildspec     = "frontend-ext/buildspec.yml" # 外网前端
    branch        = "dev"
    tag           = "latest"
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
    buildspec     = "frontend-int/buildspec.yml" # 内网前端
    branch        = "dev"
    tag           = "latest"
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
    cpu        = 2048 # 2 vCPU
    memory     = 4096
    repository = "REPLACE_ME-backend"
    repo_url   = "https://github.com/AZU-RDIT/AIEC.git"
    buildspec  = "backend/buildspec.yml" # 后端

    # 后端读写应用文件桶，任务角色权限自动生成。
    file_bucket_access = true
    branch             = "dev"
    tag                = "latest"
    port               = 8002
    desired_count      = 1

    security_group_ids   = ["sg-0960c20f67f17cb68"]
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
    # 该 Secret 若使用 CMK，还要填：
    #   secrets_kms_key_arns = ["arn:aws-cn:kms:cn-north-1:<account-id>:key/<key-id>"]
  }
}
