variable "region" {
  description = "部署区域。整套代码里唯一写区域的地方。"
  type        = string
}

variable "project" {
  description = "项目标识，资源命名为 az-cn-rdit-<project>-<用途>-<environment>。"
  type        = string

  # The default frontend-ext execution role name is exactly 64 characters when project is 17 characters; validate custom service names separately. | 默认 frontend-ext 执行角色在 project 为 17 位时恰好 64 字符；自定义服务名还会单独校验。
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,16}$", var.project))
    error_message = "project 只能用小写字母、数字和连字符，2-17 位；IAM 角色名不能超过 64 字符。"
  }
}

variable "environment" {
  description = "环境标识，统一使用小写 dev / ppd / prd。"
  type        = string

  validation {
    condition     = contains(["dev", "ppd", "prd"], var.environment)
    error_message = "environment 必须是小写 dev、ppd 或 prd。"
  }
}

variable "mandatory_tags" {
  description = "AZ 强制 Tag，实际值填写在各环境 tfvars 的 mandatory_tags 中。"
  # Use a map for AZ tag keys containing spaces and validate all seven required keys explicitly. | 含空格的 AZ 标签键使用 map，并单独校验七个键名。
  type = map(string)

  validation {
    condition = toset(keys(var.mandatory_tags)) == toset([
      "applicationname", "applicationowner", "Cost Center", "IDMD No",
      "applicationid", "environment", "creationdate",
    ])
    error_message = "mandatory_tags 必须包含 AZ 要求的七个标签，键名及大小写须与清单一致。"
  }

  # An empty string passes the type check but is equivalent to a missing tag in the console. | 空字符串能过 type 检查，但在控制台上和没打 Tag 一样。
  validation {
    condition     = alltrue([for v in values(var.mandatory_tags) : trimspace(v) != ""])
    error_message = "强制 Tag 不允许留空，七个字段都要填。"
  }
}

variable "log_retention_days" {
  description = "日志保留天数。"
  type        = number
  default     = 30
}

variable "file_bucket_name" {
  description = "应用文件桶名字，默认 az-cn-rdit-<project>-files-<environment>。S3 桶名全局唯一，撞名才显式指定。"
  type        = string
  default     = null
}

variable "codebase_bucket_name" {
  description = "代码桶名字，默认 az-cn-rdit-<project>-s3-codebase-<environment>。S3 桶名全局唯一，撞名才显式指定。"
  type        = string
  default     = null
}

variable "kms_administrator_arns" {
  description = "AZ 密钥管理员及执行 Terraform 的 IAM 角色 ARN；每环境必填，包含实际部署角色以通过 KMS 防锁定校验。"
  type        = list(string)

  validation {
    condition = length(var.kms_administrator_arns) > 0 && alltrue([
      for arn in var.kms_administrator_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", arn))
    ])
    error_message = "kms_administrator_arns 至少提供一个完整 IAM role ARN，不能填 STS 会话 ARN 或通配符。"
  }
}

variable "enable_build_webhook" {
  description = <<-EOT
    GitHub push 自动触发构建。生产默认关闭 —— 推一次代码就发一次生产不是好主意。
    开启前账号里要先有 GitHub 凭证，见 README。
  EOT
  type        = bool
  default     = false
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

    # ECR repository name; derive the image URI and execution role pull permissions from this value. | ECR 仓库名。镜像地址和执行角色的拉取权限都从这里推。
    repository = string
    tag        = string

    # GitHub source repository URL for CodeBuild; services in one repository use the same URL. | GitHub 仓库地址，CodeBuild 的源。同仓库的服务填相同 URL。
    repo_url = string
    branch   = optional(string, "main")
    # Buildspec path relative to the repository root, allowing separate service directories in one repository. | 构建文件相对于仓库根目录的路径，用于同仓库的不同服务目录。
    buildspec = optional(string, "buildspec.yml")

    # npm and Java builds need memory; use BUILD_GENERAL1_MEDIUM if necessary. | npm 和 Java 构建吃内存，不够就换 BUILD_GENERAL1_MEDIUM。
    build_compute_type = optional(string, "BUILD_GENERAL1_SMALL")

    # Grant the task role read and write permissions on the file bucket; only the backend needs this under the SBP. | 给任务角色加文件桶的读写权限。按 SBP 只有后端需要。
    file_bucket_access = optional(bool, false)

    # Container listening port, also used as the ALB target port. | 容器监听的端口，也是 ALB 转发的目标端口。
    port = number

    # Created and supplied by AZ; all services in all three environments currently share one security group whose rules AZ manages. | AZ 创建后提供；当前三个环境的三个服务共用同一个 SG，规则由 AZ 管理。
    security_group_ids = list(string)

    # ALB target group, required only for services receiving user traffic; health checks are configured on the target group. | ALB 目标组。只有接用户流量的服务需要，健康检查配在目标组上。
    # Leave null for services without an ALB and use health_check_command instead. | 不挂 ALB 的服务留 null，改用 health_check_command。
    target_group_arn = optional(string)

    service_connect_name = optional(string)

    environment = optional(map(string), {})
    # Map environment variable names to Secrets Manager ARNs; Terraform stores no secret values and scopes execution role access to these ARNs. | 环境变量名 -> Secrets Manager ARN。密文不进 Terraform，执行角色权限按这里的 ARN 收口。
    secrets = optional(map(string), {})

    # For AZ-supplied secrets using CMKs, list the key ARNs so execution roles receive kms:Decrypt automatically. | 上述 AZ 提供的 Secret 若使用 CMK，列出对应 key ARN，执行角色自动补 kms:Decrypt。
    # The TLS secret uses the CMK created by this project; do not repeat it here. | TLS Secret 使用本项目创建的 CMK，不用在这里重复填。
    secrets_kms_key_arns = optional(list(string), [])

    # Images such as nginx that write to /var/cache or /var/run require false. | nginx 这类要写 /var/cache、/var/run 的镜像必须是 false。
    # The entrypoint must also write certificate files, so this cannot be true. | 证书也要靠 entrypoint 落盘，所以这里不能设 true。
    readonly_root_filesystem = optional(bool, false)

    # Container health check command. Without an ALB, a service has no health signal unless this is configured; | 容器健康检查命令。不挂 ALB 的服务没有这个就没有任何健康信号 ——
    # ECS cannot replace an unresponsive process that has not exited. The image must include curl or wget. | 进程挂死但不退出时 ECS 不会替换它。要求镜像里有 curl 或 wget。
    health_check_command = optional(string)

    # Permissions for application code to access AWS resources; AZ requires project-specific resources and forbids unrestricted wildcards. | 业务代码访问 AWS 资源的权限。AZ 规范要求限定到项目自身资源，禁通配。
    # Use conditions for additional scope restrictions, such as s3:prefix on s3:ListBucket to list only project prefixes. | conditions 用于进一步收口，例如 s3:ListBucket 配 s3:prefix 只列项目自己的前缀。
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

    # Task count; null is treated as 1. | 任务数。null 当 1 用。
    desired_count = optional(number)

  }))

  validation {
    condition = alltrue([
      for name, service in var.services :
      contains(["frontend-ext", "frontend-int"], name) ? can(regex(
        "^https://[a-zA-Z0-9][a-zA-Z0-9.-]*(:[0-9]+)?$",
        lookup(service.environment, "BACKEND_URL", "")
      )) : true
    ])
    error_message = "前端 BACKEND_URL 必须使用 HTTPS 的服务地址（例如 https://backend-service:8002），且不能带路径或末尾斜杠。"
  }

  # The service name is also the container name and must use this character set. | 服务名同时是容器名，容器名只收这个字符集。
  validation {
    condition     = alltrue([for k in keys(var.services) : can(regex("^[a-z0-9][a-z0-9-]{0,30}$", k))])
    error_message = "服务名只能用小写字母、数字和连字符，不超过 31 位。"
  }

  # Only Secrets Manager is supported; other ARN formats can cause an index error when deriving execution role permissions. | 只支持 Secrets Manager。放别的 ARN 进来，推导执行角色权限那段会按段数截取而越界报错。
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
        for a in s.secrets_kms_key_arns : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", a))
      ]
    ]))
    error_message = "secrets_kms_key_arns 只能包含完整的 KMS key ARN，不能使用 alias、key ID 或通配符。"
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
