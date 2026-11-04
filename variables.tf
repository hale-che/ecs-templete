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

    # 都是 AZ 创建后给的，一服务一个。健康检查配在目标组上，不在这份代码里。
    security_group_ids = list(string)
    target_group_arn   = string

    environment = optional(map(string), {})
    # 环境变量名 -> Secrets Manager ARN。密文不进 Terraform，执行角色权限按这里的 ARN 收口。
    secrets = optional(map(string), {})

    # nginx 这类要写 /var/cache、/var/run 的镜像必须是 false。
    readonly_root_filesystem = optional(bool, false)

    # 业务代码访问 AWS 资源的权限。AZ 规范要求限定到项目自身资源，禁通配。
    task_role_policy_statements = optional(list(object({
      sid       = optional(string)
      actions   = list(string)
      resources = list(string)
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
