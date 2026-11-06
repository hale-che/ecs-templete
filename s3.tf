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

# 不用自管 CMK，和日志保持一致。S3 现在默认就是 SSE-S3，这里写出来是为了审计能看到。
resource "aws_s3_bucket_server_side_encryption_configuration" "files" {
  bucket = aws_s3_bucket.files.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
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
