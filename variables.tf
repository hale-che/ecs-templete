variable "region" {
  description = "部署区域。整套代码里唯一写区域的地方。"
  type        = string
}

variable "project" {
  description = "项目标识，命名规范 AZ-CNRDIT-<ENV>-<project>-<服务名> 的第三段。"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,19}$", var.project))
    error_message = "project 只能用小写字母、数字和连字符，2-20 位。太长会把 IAM 角色名顶过 64 字符。"
  }
}

variable "environment" {
  description = "环境标识，取 DEV / PPD / PRD。"
  type        = string

  validation {
    condition     = contains(["DEV", "PPD", "PRD"], var.environment)
    error_message = "environment 必须是 DEV、PPD 或 PRD。"
  }
}

variable "mandatory_tags" {
  description = "AZ 强制 Tag。键名以 AZ 下发的清单为准。"
  type = object({
    AccountOwner = string # 账号所有者
    Maintainer   = string # 维护人
    CMDB         = string # CMDB 信息
    RequestID    = string # 申请单号
    CostCenter   = string # 成本中心
  })

  # 空字符串能过 type 检查，但在控制台上和没打 Tag 一样。
  validation {
    condition     = alltrue([for v in values(var.mandatory_tags) : trimspace(v) != ""])
    error_message = "强制 Tag 不允许留空，五个字段都要填。"
  }
}

variable "kms_key_id" {
  description = "加密日志组的 KMS CMK。别名、Key ID、ARN 都行，ARN 由 data 源解析。"
  type        = string
}

variable "log_retention_days" {
  description = "日志保留天数。"
  type        = number
  default     = 30
}

variable "secret_kms_key_arns" {
  description = <<-EOT
    加密 Secrets Manager 密钥的 CMK。和 kms_key_id（日志用）不是同一把时必须给，
    否则执行角色取不到密钥，任务启动报 AccessDenied。用 AWS 托管密钥则不用填。
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.secret_kms_key_arns : can(regex("^arn:aws[a-z-]*:kms:", a))])
    error_message = "secret_kms_key_arns 必须是 KMS Key 的完整 ARN。"
  }
}

variable "subnet_ids" {
  description = "AZ 提供的私有子网，任务起在这里面。跨可用区至少给两个。"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "至少给两个子网，否则单可用区故障会把服务全部打掉。"
  }
}

variable "services" {
  description = "一个服务一个 Task Definition，map 的 key 是服务名，也是容器名。"

  type = map(object({
    cpu    = number
    memory = number

    # ECR 仓库名。镜像地址和执行角色的拉取权限都从这里推。
    repository = string
    tag        = string

    # 容器监听的端口，也是 ALB 转发的目标端口。
    port = number

    # AZ 创建后给的，一服务一个。
    security_group_ids = list(string)

    # ALB 目标组。只有接用户流量的服务需要，健康检查配在目标组上。
    # 不挂 ALB 的服务留 null，改用 health_check_command。
    target_group_arn = optional(string)

    # 注册进 Service Connect，供其他服务用 https://<这个名字>:<port> 访问。
    # null 表示只作为客户端：能调别人，别人调不到它。
    service_connect_name = optional(string)

    environment = optional(map(string), {})
    # 环境变量名 -> Secrets Manager ARN。密文不进 Terraform，执行角色权限按这里的 ARN 收口。
    secrets = optional(map(string), {})

    # nginx 这类要写 /var/cache、/var/run 的镜像必须是 false。
    # 证书也要靠 entrypoint 落盘，所以这里不能设 true。
    readonly_root_filesystem = optional(bool, false)

    # 容器健康检查命令。不挂 ALB 的服务没有这个就没有任何健康信号 ——
    # 进程挂死但不退出时 ECS 不会替换它。要求镜像里有 curl 或 wget。
    health_check_command = optional(string)

    # 业务代码访问 AWS 资源的权限。AZ 规范要求限定到项目自身资源，禁通配。
    # conditions 用于进一步收口，例如 s3:ListBucket 配 s3:prefix 只列项目自己的前缀。
    task_role_policy_statements = optional(list(object({
      sid       = optional(string)
      actions   = list(string)
      resources = list(string)
      conditions = optional(list(object({
        test     = string
        variable = string
        values   = list(string)
      })), [])
    })), [])

    # 任务数。null 当 1 用。
    desired_count = optional(number)

    # 两个都给才建 Auto Scaling；留空表示固定任务数，不扩缩容。
    min_capacity = optional(number)
    max_capacity = optional(number)
  }))

  # 服务名同时是容器名，容器名只收这个字符集。
  validation {
    condition     = alltrue([for k in keys(var.services) : can(regex("^[a-z0-9][a-z0-9-]{0,30}$", k))])
    error_message = "服务名只能用小写字母、数字和连字符，不超过 31 位。"
  }

  # 只支持 Secrets Manager。放别的 ARN 进来，推导执行角色权限那段会按段数截取而越界报错。
  validation {
    condition = alltrue(flatten([
      for s in values(var.services) : [
        for a in values(s.secrets) : can(regex("^arn:aws[a-z-]*:secretsmanager:", a))
      ]
    ]))
    error_message = "secrets 的值必须是 Secrets Manager 的完整 ARN。用 SSM Parameter Store 要先改 iam.tf。"
  }

  validation {
    condition = alltrue(flatten([
      for s in values(var.services) : [
        for st in s.task_role_policy_statements : !contains(st.resources, "*") && !contains(st.actions, "*")
      ]
    ]))
    error_message = "task_role_policy_statements 不允许 actions 或 resources 用 \"*\"，要限定到项目自身资源。"
  }
}
