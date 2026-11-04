terraform {
  required_version = "~> 1.6.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = ">= 5.60.0, < 6.0.0"
    }
  }

  # 留空：bucket / key 由 `terraform init -backend-config=...` 分环境传入。
  backend "s3" {}
}
