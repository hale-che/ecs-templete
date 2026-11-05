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

kms_key_id         = "alias/REPLACE_ME"
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
    tag           = "latest"
    port          = 8443
    desired_count = 1

    security_group_ids = ["sg-REPLACE_ME"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV = "dev"
      # nginx 反代 /api 的上游，内部 ALB 的 DNS 名，AZ 建好后给。
      # 变量名要和镜像里 nginx 模板用的一致。
      BACKEND_URL = "http://REPLACE_ME-internal-alb"
    }
  }

  "frontend-int" = {
    cpu           = 512
    memory        = 1024
    repository    = "REPLACE_ME-frontend-int"
    tag           = "latest"
    port          = 8443
    desired_count = 1

    security_group_ids = ["sg-REPLACE_ME"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "dev"
      BACKEND_URL = "http://REPLACE_ME-internal-alb"
    }
  }

  "backend" = {
    cpu           = 2048 # 2 vCPU
    memory        = 4096
    repository    = "REPLACE_ME-backend"
    tag           = "latest"
    port          = 8002
    desired_count = 1

    security_group_ids = ["sg-REPLACE_ME"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV = "dev"
    }

    # 环境变量名 -> Secrets Manager ARN。执行角色权限自动按这里的 ARN 收口。
    secrets = {}
  }
}
