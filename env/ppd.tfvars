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

kms_key_id         = "alias/REPLACE_ME"
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
    tag           = "latest"
    port          = 8443
    desired_count = 1

    security_group_ids = ["sg-REPLACE_ME"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "ppd"
      BACKEND_URL = "http://REPLACE_ME-internal-alb"
    }
  }

  "frontend-int" = {
    cpu           = 1024
    memory        = 2048
    repository    = "REPLACE_ME-frontend-int"
    tag           = "latest"
    port          = 8443
    desired_count = 1

    security_group_ids = ["sg-REPLACE_ME"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "ppd"
      BACKEND_URL = "http://REPLACE_ME-internal-alb"
    }
  }

  "backend" = {
    cpu           = 2048 # 2 vCPU
    memory        = 8192
    repository    = "REPLACE_ME-backend"
    tag           = "latest"
    port          = 8002
    desired_count = 1

    security_group_ids = ["sg-REPLACE_ME"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV = "ppd"
    }

    secrets = {}
  }
}
