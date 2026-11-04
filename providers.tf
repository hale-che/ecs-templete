provider "aws" {
  region = var.region

  # 强制 Tag 通过 default_tags 下发到所有资源，单个资源不再重复写。
  default_tags {
    tags = local.tags
  }
}
