provider "aws" {
  region = var.region

  # Apply mandatory tags to all resources through default_tags instead of repeating them on each resource.
  default_tags {
    tags = local.tags
  }
}
