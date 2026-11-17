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
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "cluster_name" {
  description = "Cluster name az-cn-rdit-<project>-ecs-fargate-<environment>, matching the main project; one environment per run."
  type        = string

  validation {
    condition     = can(regex("^az-cn-rdit-[a-z0-9][a-z0-9-]{1,16}-ecs-fargate-(dev|ppd|prd)$", var.cluster_name))
    error_message = "cluster_name must follow the project environment naming convention."
  }
}

variable "service_repositories" {
  description = "Service name -> actual ECR repository name; repository names may differ from service names."
  type        = map(string)

  validation {
    condition = length(var.service_repositories) > 0 && alltrue([
      for name, repository in var.service_repositories :
      can(regex("^[a-z0-9][a-z0-9-]{0,30}$", name)) &&
      can(regex("^[a-z0-9][a-z0-9._/-]*$", repository))
    ])
    error_message = "Provide at least one service; service and repository names cannot contain wildcards or ARNs."
  }
}
