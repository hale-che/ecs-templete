variable "partition" {
  type    = string
  default = "aws-cn"
}

variable "region" {
  type    = string
  default = "cn-north-1"
}

variable "account_id" {
  type = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id 必须是 12 位 AWS 账号 ID。"
  }
}

variable "cluster_name" {
  description = "与主项目一致的 az-cn-rdit-<project>-ecs-fargate-<environment>，一次只生成一个环境。"
  type        = string

  validation {
    condition     = can(regex("^az-cn-rdit-[a-z0-9][a-z0-9-]{1,16}-ecs-fargate-(dev|ppd|prd)$", var.cluster_name))
    error_message = "cluster_name 必须符合项目的环境命名规范。"
  }
}

variable "service_repositories" {
  description = "服务名 -> 实际 ECR 仓库名，支持与服务名不同的仓库命名。"
  type        = map(string)

  validation {
    condition = length(var.service_repositories) > 0 && alltrue([
      for name, repository in var.service_repositories :
      can(regex("^[a-z0-9][a-z0-9-]{0,30}$", name)) &&
      can(regex("^[a-z0-9][a-z0-9._/-]*$", repository))
    ])
    error_message = "至少提供一个服务；服务名、仓库名不能含通配符或 ARN。"
  }
}
