variable "region" {
  description = "Deployment region. The only place in the codebase where the region is set."
  type        = string
}

variable "project" {
  description = "Project identifier. Resources are named az-cn-rdit-<project>-<purpose>-<environment>."
  type        = string

  # The default frontend-ext execution role name is exactly 64 characters when project is 17 characters; validate custom service names separately.
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,16}$", var.project))
    error_message = "project must be 2-17 lowercase letters, digits, or hyphens; IAM role names cannot exceed 64 characters."
  }
}

variable "environment" {
  description = "Environment identifier: lowercase dev / ppd / prd."
  type        = string

  validation {
    condition     = contains(["dev", "ppd", "prd"], var.environment)
    error_message = "environment must be lowercase dev, ppd, or prd."
  }
}

variable "mandatory_tags" {
  description = "AZ mandatory tags. Set actual values in mandatory_tags of each environment tfvars."
  # Use a map for AZ tag keys containing spaces and validate all seven required keys explicitly.
  type = map(string)

  validation {
    condition = toset(keys(var.mandatory_tags)) == toset([
      "applicationname", "applicationowner", "Cost Center", "IDMD No",
      "applicationid", "environment", "creationdate",
    ])
    error_message = "mandatory_tags must contain the seven AZ-required tags, with keys matching the list exactly (case-sensitive)."
  }

  # An empty string passes the type check but is equivalent to a missing tag in the console.
  validation {
    condition     = alltrue([for v in values(var.mandatory_tags) : trimspace(v) != ""])
    error_message = "Mandatory tags cannot be empty; all seven must be set."
  }
}

variable "log_retention_days" {
  description = "Log retention in days, default 1 year. Must be a value supported by CloudWatch."
  type        = number
  default     = 365

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731,
      1096, 1827, 2192, 2557, 2922, 3288, 3653,
    ], var.log_retention_days)
    error_message = "log_retention_days must be a value supported by CloudWatch: 1/3/5/7/14/30/60/90/120/150/180/365/400/545/731/1096/1827/2192/2557/2922/3288/3653."
  }
}

variable "file_bucket_name" {
  description = "Application file bucket name, default az-cn-rdit-<project>-files-<environment>. S3 names are globally unique; set explicitly only on conflict."
  type        = string
  default     = null
}

variable "access_log_bucket_name" {
  description = "S3 access log bucket name, default az-cn-rdit-<project>-s3-access-logs-<environment>. Set explicitly only on conflict."
  type        = string
  default     = null
}

variable "secret_name_prefix" {
  description = "Secret names are <prefix>/<managed_secrets key>; default <project>/<environment>. Must differ per environment in a shared account."
  type        = string
  default     = null
}

variable "managed_secrets" {
  description = "Secrets created empty by Terraform, purpose => description. Enter values manually after apply. Must include tls."
  type        = map(string)

  validation {
    condition     = contains(keys(var.managed_secrets), "tls")
    error_message = "managed_secrets must include tls; its JSON keys cert / key are injected into every service."
  }

  validation {
    condition     = alltrue([for k in keys(var.managed_secrets) : can(regex("^[a-z0-9-]+$", k))])
    error_message = "managed_secrets keys may only contain lowercase letters, digits, and hyphens."
  }
}

variable "codebuild_image" {
  description = <<-EOT
    CodeBuild image. Defaults to the Amazon Linux 2023 managed image;
    do not use amazonlinux2 images, which are based on end-of-support AL2.
  EOT
  type        = string
  default     = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
}

variable "ecr_image_tag_mutability" {
  description = "ECR tag mutability. Timestamp tags are unique, so IMMUTABLE works; use MUTABLE if moving tags such as latest are also pushed."
  type        = string
  default     = "MUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.ecr_image_tag_mutability)
    error_message = "ecr_image_tag_mutability must be MUTABLE or IMMUTABLE."
  }
}

variable "ecr_untagged_expire_days" {
  description = "Days to keep untagged images. Re-pushing an existing tag leaves the old image untagged."
  type        = number
  default     = 30
}

variable "ecr_max_image_count" {
  description = "Images to keep per repository. With unique tags (timestamp + commit) images only accumulate, so this caps them."
  type        = number
  default     = 30
}

variable "kms_administrator_arns" {
  description = "IAM role ARNs of AZ key administrators and the Terraform deployer; required per environment. Include the deploy role to pass the KMS lockout check."
  type        = list(string)

  validation {
    condition = length(var.kms_administrator_arns) > 0 && alltrue([
      for arn in var.kms_administrator_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", arn))
    ])
    error_message = "kms_administrator_arns needs at least one full IAM role ARN; STS session ARNs and wildcards are not allowed."
  }

  # REPLACE_ME consists of valid role-name characters, so the rule above accepts it and the failure surfaces only when the key is created.
  validation {
    condition     = !can(regex("REPLACE_ME", join(",", var.kms_administrator_arns)))
    error_message = "kms_administrator_arns still contains REPLACE_ME; replace it with the actual role name."
  }
}

variable "subnet_ids" {
  description = "Private subnets provided by AZ where tasks run. At least two across availability zones."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "Provide at least two subnets; otherwise a single AZ failure takes down all services."
  }
}

variable "services" {
  description = "One task definition per service. The map key is the service name and the container name."

  type = map(object({
    cpu    = number
    memory = number

    # ECR repository name; derive the image URI and execution role pull permissions from this value.
    repository = string

    # Existing timestamp tag for the initial ECS task; CodeBuild generates its own tag per build.
    image_tag = string

    # GitHub source repository URL for CodeBuild; services in one repository use the same URL.
    repo_url = string
    branch   = optional(string, "main")
    # Buildspec path relative to the repository root, allowing separate service directories in one repository.
    buildspec = optional(string, "buildspec.yml")

    # npm and Java builds need memory; use BUILD_GENERAL1_MEDIUM if necessary.
    build_compute_type = optional(string, "BUILD_GENERAL1_SMALL")

    # Grant the task role read and write permissions on the file bucket; only the backend needs this under the SBP.
    file_bucket_access = optional(bool, false)

    # Container listening port, also used as the ALB target port.
    port = number

    # Created and supplied by AZ; all services in all three environments currently share one security group whose rules AZ manages.
    security_group_ids = list(string)

    # ALB target group, required only for services receiving user traffic; health checks are configured on the target group.
    # Leave null for services without an ALB and use health_check_command instead.
    target_group_arn = optional(string)

    service_connect_name = optional(string)

    environment = optional(map(string), {})
    # Environment variable => managed_secrets key (optionally key:json-key) or full external secret ARN.
    secrets = optional(map(string), {})

    # For AZ-supplied secrets using CMKs, list the key ARNs so execution roles receive kms:Decrypt automatically.
    # Secrets in managed_secrets use aws/secretsmanager; do not list a key for them.
    secrets_kms_key_arns = optional(list(string), [])

    # Images such as nginx that write to /var/cache or /var/run require false.
    # The entrypoint must also write certificate files, so this cannot be true.
    readonly_root_filesystem = optional(bool, false)

    # Container health check command. Without an ALB, a service has no health signal unless this is configured;
    # ECS cannot replace an unresponsive process that has not exited. The image must include curl or wget.
    health_check_command = optional(string)

    # Permissions for application code to access AWS resources; AZ requires project-specific resources and forbids unrestricted wildcards.
    # Use conditions for additional scope restrictions, such as s3:prefix on s3:ListBucket to list only project prefixes.
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

    # Task count; null is treated as 1.
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
    error_message = "Frontend BACKEND_URL must be an HTTPS service address (e.g. https://backend-service:8002) without a path or trailing slash."
  }

  # The service name is also the container name and must use this character set.
  validation {
    condition     = alltrue([for k in keys(var.services) : can(regex("^[a-z0-9][a-z0-9-]{0,30}$", k))])
    error_message = "Service names must be at most 31 lowercase letters, digits, or hyphens."
  }

  # Target group ARNs are not validated anywhere else; a wrong value fails only when the ECS service is created.
  validation {
    condition = alltrue([
      for s in values(var.services) :
      s.target_group_arn == null ||
      can(regex("^arn:aws[a-z-]*:elasticloadbalancing:[a-z0-9-]+:[0-9]{12}:targetgroup/[A-Za-z0-9-]{1,32}/[0-9a-f]{16}$", coalesce(s.target_group_arn, "")))
    ])
    error_message = "target_group_arn must be a full target group ARN, e.g. arn:aws-cn:elasticloadbalancing:cn-north-1:<12-digit account>:targetgroup/<name>/<16 hex chars>."
  }

  # Catch any leftover placeholder in one shot: repository, tag, security groups, secrets.
  validation {
    condition     = alltrue([for s in values(var.services) : !can(regex("REPLACE_ME", jsonencode(s)))])
    error_message = "services still contains REPLACE_ME values."
  }

  # ECR repository names reject uppercase; the module now creates these repositories.
  validation {
    condition = alltrue([
      for s in values(var.services) :
      can(regex("^([a-z0-9]+([._-][a-z0-9]+)*/)*[a-z0-9]+([._-][a-z0-9]+)*$", s.repository))
    ])
    error_message = "repository may only contain lowercase letters, digits, and . _ - /; ECR does not allow uppercase."
  }

  # Full ARNs need the six-character suffix: a name-only ARN passes plan but fails at task startup.
  validation {
    condition = alltrue(flatten([
      for s in values(var.services) : [
        for a in values(s.secrets) :
        can(regex("^[a-z0-9-]+(:[A-Za-z0-9_.-]+)?$", a)) ||
        can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+-[A-Za-z0-9]{6}(:[^:]*:[^:]*:[^:]*)?$", a))
      ]
    ]))
    error_message = "secrets values must be a managed_secrets key (optionally key:json-key) or a full secret ARN with the 6-character suffix."
  }

  validation {
    condition = alltrue(flatten([
      for s in values(var.services) : [
        for a in s.secrets_kms_key_arns : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", a))
      ]
    ]))
    error_message = "secrets_kms_key_arns may only contain full KMS key ARNs; aliases, key IDs, and wildcards are not allowed."
  }

  validation {
    condition = alltrue(flatten([
      for s in values(var.services) : [
        for st in s.task_role_policy_statements : !contains(st.resources, "*") && !contains(st.actions, "*")
      ]
    ]))
    error_message = "task_role_policy_statements must not use \"*\" in actions or resources; scope them to project resources."
  }
}
