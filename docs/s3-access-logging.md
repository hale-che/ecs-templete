# S3 访问日志（Sonar S6258）

应用文件桶已增加 `aws_s3_bucket_logging.files`，将访问日志投递到 AZ 预先提供的集中日志桶。
不为业务桶添加旧式 `log-delivery-write` ACL，不创建递归记录自身日志的目标桶。

三个环境分别填写 `s3_access_log_bucket_name`，可使用同一个同区域日志桶，以前缀区分项目与环境。
前缀为 `az-cn-rdit-<project>-<environment>/s3/`，实际配置从 `s3_access_logging` output 取得。

## AZ 需提供和配置

- 目标桶必须与源桶处于同一个账号和区域，且不能是业务桶自身。
- 按 AWS 当前说明，S3 server access logging 的目标桶须使用 SSE-S3，不能直接复用默认 SSE-KMS 的桶。
  这是日志目标桶限制；业务文件桶仍使用项目专用 CMK。若 AZ 要求日志桶也强制 SSE-KMS，需先确认兼容的审计方案。
- 目标桶不能启用 Object Lock / 默认保留期或 Requester Pays；日志保留策略由 AZ 统一管理。
- AZ 在目标桶现有 policy 中合并日志服务的写入授权，不应覆盖其他项目的 policy。
  该共享桶 policy 不归本模板管理。

以下为项目 ceam 的 dev 示例，需替换目标桶及账号；其他环境使用其实际源桶和前缀：

```json
{
  "Sid": "ReceiveCeamDevS3AccessLogs",
  "Effect": "Allow",
  "Principal": {"Service": "logging.s3.amazonaws.com"},
  "Action": "s3:PutObject",
  "Resource": "arn:aws-cn:s3:::AZ_LOG_BUCKET/az-cn-rdit-ceam-dev/s3/*",
  "Condition": {
    "ArnEquals": {"aws:SourceArn": "arn:aws-cn:s3:::az-cn-rdit-ceam-files-dev"},
    "StringEquals": {"aws:SourceAccount": "123456789012"}
  }
}
```

部署身份需对源桶具备 `s3:GetBucketLogging` / `s3:PutBucketLogging`；无需为了这项配置而授予它管理共享目标桶策略的权限。
目标桶不存在、投递权限未就绪时，实际 apply / 日志投递仍可能失败。

本地 plan 只能证明日志配置进入计划，不能证明日志已送达；部署后检查 `get-bucket-logging`，
产生一次源桶访问并等待目标前缀出现日志，再重新运行 Sonar。扫描器版本是否识别独立 logging 资源以实际复扫为准。

参考：[AWS S3 访问日志配置、目标桶限制及投递权限](https://docs.aws.amazon.com/AmazonS3/latest/userguide/enable-server-access-logging.html)。
