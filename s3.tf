# 应用的文件桶。后端通过 S3 网关 Endpoint 读写，权限走任务角色。
# 一个环境一个桶。S3 桶名是全局唯一的，撞名就用 file_bucket_name 显式指定。

resource "aws_s3_bucket" "files" {
  bucket = local.file_bucket_name

  tags = { Name = local.file_bucket_name }
}

resource "aws_s3_bucket_public_access_block" "files" {
  bucket = aws_s3_bucket.files.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Sonar S6258：访问日志写入 AZ 集中日志桶，不给业务桶添加旧式 log-delivery-write ACL。
# 目标桶及其投递策略由 AZ 管理，配置要求见 docs/s3-access-logging.md。
resource "aws_s3_bucket_logging" "files" {
  bucket        = aws_s3_bucket.files.id
  target_bucket = var.s3_access_log_bucket_name
  target_prefix = local.s3_access_log_prefix

  lifecycle {
    precondition {
      condition     = var.s3_access_log_bucket_name != local.file_bucket_name
      error_message = "访问日志必须写入独立日志桶，不能投递回应用桶自身。"
    }
  }
}

# SSE-KMS 使用本项目创建的 CMK，不能退回 SSE-S3 或 aws/s3。
resource "aws_s3_bucket_server_side_encryption_configuration" "files" {
  bucket = aws_s3_bucket.files.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.files.arn
    }
  }
}

# 无加密请求头时使用上面的桶默认值；显式指定时必须使用同一把 CMK。
# 尤其 aws:kms 请求头未带 key ID 时，S3 会选 aws/s3，必须阻止这种绕过。
data "aws_iam_policy_document" "file_bucket" {
  statement {
    sid       = "DenyOtherServerSideEncryption"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.files.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid       = "DenyExplicitKmsWithoutApprovedKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.files.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [aws_kms_key.files.arn]
    }
  }

  statement {
    sid       = "DenyCustomerProvidedEncryptionKeys"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.files.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption-customer-algorithm"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "files" {
  bucket = aws_s3_bucket.files.id
  policy = data.aws_iam_policy_document.file_bucket.json

  depends_on = [aws_s3_bucket_server_side_encryption_configuration.files]
}

# 开版本控制。按要求不配历史版本的过期删除，保留规则由业务侧处理。
resource "aws_s3_bucket_versioning" "files" {
  bucket = aws_s3_bucket.files.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "files" {
  bucket = aws_s3_bucket.files.id

  depends_on = [aws_s3_bucket_versioning.files]

  # day 0 转 Intelligent-Tiering：不依赖应用上传时指定存储类，漏了也能兜住。
  # 之后的分层是 Intelligent-Tiering 内置的，30 天未访问转 Infrequent Access、
  # 90 天未访问转 Archive Instant Access，这两个阈值不可配。
  # 没有 Archive Access / Deep Archive Access 配置块，所以不会出现取回前要恢复的情况。
  rule {
    id     = "to-intelligent-tiering"
    status = "Enabled"

    filter {}

    transition {
      days          = 0
      storage_class = "INTELLIGENT_TIERING"
    }
  }

  # 清理失败的分片上传。这不是删文件 —— 未完成的分片看不见但一直计费。
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
