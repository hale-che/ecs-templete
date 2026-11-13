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
  description = "日志保留天数，默认 1 年。只能取 CloudWatch 允许的档位。"
  type        = number
  default     = 365

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731,
      1096, 1827, 2192, 2557, 2922, 3288, 3653,
    ], var.log_retention_days)
    error_message = "log_retention_days 只能取 CloudWatch 允许的档位：1/3/5/7/14/30/60/90/120/150/180/365/400/545/731/1096/1827/2192/2557/2922/3288/3653。"
  }
}

variable "file_bucket_name" {
  description = "应用文件桶名字，默认 az-cn-rdit-<project>-files-<environment>。S3 桶名全局唯一，撞名才显式指定。"
  type        = string
  default     = null
}

variable "tls_secret_arn" {
  description = <<-EOT
    TLS 证书的 Secret 完整 ARN，外部已建好，本模板不创建也不写值。
    里面要有 cert 和 key 两个 JSON 键，自动注入三个服务的 TLS_CERT / TLS_KEY。
  EOT
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+-[A-Za-z0-9]{6}$", var.tls_secret_arn))
    error_message = "tls_secret_arn 必须是完整 ARN，结尾带 Secrets Manager 自动生成的 6 位后缀。"
  }
}

variable "codebuild_image" {
  description = <<-EOT
    CodeBuild 构建镜像。默认是 Amazon Linux 2023 的托管镜像；
    带 amazonlinux2 的那套基于已停止支持的 AL2，不要再用。
  EOT
  type        = string
  default     = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
}

variable "ecr_image_tag_mutability" {
  description = "ECR tag 可变性。时间戳 tag 唯一，可以改 IMMUTABLE；若另外推 latest 这类移动 tag 则必须 MUTABLE。"
  type        = string
  default     = "MUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.ecr_image_tag_mutability)
    error_message = "ecr_image_tag_mutability 只能是 MUTABLE 或 IMMUTABLE。"
  }
}

variable "ecr_untagged_expire_days" {
  description = "未打 tag 的镜像保留天数。覆盖推送同一个 tag 会把旧镜像变成 untagged。"
  type        = number
  default     = 30
}

variable "ecr_max_image_count" {
  description = "每个仓库保留的镜像数。tag 唯一（时间戳 + commit）时镜像只增不减，靠这条收口。"
  type        = number
  default     = 30
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

  # REPLACE_ME 是合法角色名字符，上面那条拦不住；漏填要到建 key 时才报错。 | REPLACE_ME consists of valid role-name characters, so the rule above accepts it and the failure surfaces only when the key is created.
  validation {
    condition     = !can(regex("REPLACE_ME", join(",", var.kms_administrator_arns)))
    error_message = "kms_administrator_arns 里还有 REPLACE_ME 没替换成实际角色名。"
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

    # ECR repository name; derive the image URI and execution role pull permissions from this value. | ECR 仓库名。镜像地址和执行角色的拉取权限都从这里推。
    repository = string

    # Existing timestamp tag for the initial ECS task; CodeBuild generates its own tag per build. | ECS 初始任务引用的已存在时间戳 tag；CodeBuild 每次构建另行生成 tag。
    tag = string

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

  # Target group ARNs are not validated anywhere else; a wrong value fails only when the ECS service is created. | 目标组 ARN 别处没有校验，填错要到建 ECS 服务时才报。
  validation {
    condition = alltrue([
      for s in values(var.services) :
      s.target_group_arn == null ||
      can(regex("^arn:aws[a-z-]*:elasticloadbalancing:[a-z0-9-]+:[0-9]{12}:targetgroup/[A-Za-z0-9-]{1,32}/[0-9a-f]{16}$", coalesce(s.target_group_arn, "")))
    ])
    error_message = "target_group_arn 必须是完整的目标组 ARN，形如 arn:aws-cn:elasticloadbalancing:cn-north-1:<12位账号>:targetgroup/<名字>/<16位十六进制>。"
  }

  # Catch any leftover placeholder in one shot: repository, tag, security groups, secrets. | 一次兜住所有残留占位符：仓库名、tag、安全组、密钥。
  validation {
    condition     = alltrue([for s in values(var.services) : !can(regex("REPLACE_ME", jsonencode(s)))])
    error_message = "services 里还有 REPLACE_ME 没替换。"
  }

  # ECR repository names reject uppercase; the module now creates these repositories. | ECR 仓库名不收大写，仓库由本模板创建。
  validation {
    condition = alltrue([
      for s in values(var.services) :
      can(regex("^([a-z0-9]+([._-][a-z0-9]+)*/)*[a-z0-9]+([._-][a-z0-9]+)*$", s.repository))
    ])
    error_message = "repository 只能用小写字母、数字和 . _ - / ，ECR 仓库名不收大写。"
  }

  # Only Secrets Manager is supported; other ARN formats can cause an index error when deriving execution role permissions. | 只支持 Secrets Manager。放别的 ARN 进来，推导执行角色权限那段会按段数截取而越界报错。
  # Require the six-character suffix: a name-only ARN passes plan but fails at task startup. | 必须带 6 位后缀：只写名字的 ARN 能过 plan，但任务启动时才失败。
  validation {
    condition = alltrue(flatten([
      for s in values(var.services) : [
        for a in values(s.secrets) :
        can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+-[A-Za-z0-9]{6}(:[^:]*:[^:]*:[^:]*)?$", a))
      ]
    ]))
    error_message = "secrets 的值必须是完整 Secret ARN（结尾带 6 位随机后缀），可再接 :键名:: 取 JSON 里的某个键。"
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
