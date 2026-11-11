# 项目专用 KMS 密钥

按最新 PR 评审要求，本模板为每个环境创建自己的 customer managed keys，由 AZ 接管密钥运维。
这替代旧的“只引用 AZ 提供的 S3 key ARN”方案。

| 资源 | 用途 | 别名示例（项目 ceam） |
| --- | --- | --- |
| `aws_kms_key.files` | S3 应用文件桶 SSE-KMS | `alias/az-cn-rdit-ceam-files-kms-dev` |
| `aws_kms_key.secrets` | TLS 证书 Secret 加密 | `alias/az-cn-rdit-ceam-secrets-kms-dev` |

两把 key 均为对称 `ENCRYPT_DECRYPT` CMK，自动开启轮换，删除等待期 30 天，Terraform 设置
`prevent_destroy = true`。只定义别名和元数据，不在 Terraform 中生成或保存密钥材料。
TLS Secret 的证书、私钥和 RDS 密码仍在 Terraform 之外写入。

## 必填参数及身份

三个 `env/*.tfvars` 分别填写 `kms_administrator_arns`，至少包含实际执行 Terraform 的 IAM 角色：

```hcl
kms_administrator_arns = [
  "arn:aws-cn:iam::123456789012:role/az-deployment-admin",
  "arn:aws-cn:iam::123456789012:role/az-key-admin",
]
```

必须填写 IAM role ARN，不是 `arn:...:sts::...:assumed-role/...` 会话 ARN；替换成 AZ 真实角色。
这些管理员可以管理 key / alias / policy / rotation；不把整个账号所有角色默认授权为密钥使用者。
实际部署角色未包含在其中时，KMS 的防锁定安全检查可能拒绝创建/更新策略，不能绕过该检查。
保留只允许实际账号 root 身份执行 `PutKeyPolicy` 的恢复入口。

执行 Terraform 的身份还需具备创建 key、管理 alias 及本项目 key / policy / tag / rotation 的 IAM 权限。
创建 key 的 API 使用 `Resource: "*"`，应以 `aws:RequestTag/Project`、`Environment` 限定；
后续管理限定具体项目 key ARN / 标签及 alias。KMS policy 内的 `Resource: "*"` 仅指所属的当前 key。
日常 Federated Role 的只读/发布 Policy 不包含这些密钥管理员权限。

旧输入 `file_bucket_kms_key_arn` / `tls_kms_key_arn` 已移除；这两个名字现在仅作为实际 key ARN 的 outputs。
新增 key 的标识无需手抄到环境文件，S3、TLS Secret 及执行/任务角色自动引用资源输出。

## 项目隔离与使用权限

- S3 CMK 的使用权限限定 `file_bucket_access = true` 服务的任务角色精确 ARN，要求 Project 主体标签匹配，
  仅经本区域 S3 调用，且加密上下文属于当前文件桶。
- TLS Secret CMK 的执行权限限定本环境各执行角色精确 ARN 及 Project 标签，
  仅经本区域 Secrets Manager 解密，且上下文属于本环境 TLS Secret。
- `kms_administrator_arns` 中的角色另获经 Secrets Manager 写入/验证本环境 TLS Secret 所需的数据密钥权限。
  人工录入 TLS 值仍须具备该 Secret 的 `secretsmanager:PutSecretValue` IAM 权限。
- 使用角色的 IAM 策略仍限定具体 key ARN 及其引用的实际 Secret ARN，Key Policy 与 IAM 双方同时授权。
- S3 开启 Bucket Key；上下文兼容桶 ARN 和未使用 Bucket Key 的旧对象 ARN。
- `kms:ViaService` 在中国区同样使用 `s3.cn-north-1.amazonaws.com` /
  `secretsmanager.cn-north-1.amazonaws.com`，不使用 `.com.cn`。

AZ 另行创建的 RDS / Entra ID Secret 及其 CMK 不归本模板所有，不能擅自换 key。
在实际引用它的服务中填写完整 Secret ARN 和 `secrets_kms_key_arns`：

```hcl
secrets = {
  DB_PASSWORD = "arn:aws-cn:secretsmanager:cn-north-1:123456789012:secret:rds-AbCdEf:password::"
}
secrets_kms_key_arns = [
  "arn:aws-cn:kms:cn-north-1:123456789012:key/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
]
```

执行角色会获得受 Secrets Manager 服务和实际 Secret 上下文限制的 `kms:Decrypt`。
AZ 仍须在该外部 CMK 的 Key Policy 中授权。仅添加 IAM 不能保证外部 CMK 已允许访问。
Aurora / RDS 存储加密、备份和 GuardDuty 等外部身份的授权仍由 AZ 对应模板维护。

## 上传与已有数据

桶默认使用项目 S3 CMK。无加密头的上传采用此默认值；显式加密时必须同时指定
`aws:kms` 与该 key 的完整 ARN。SSE-S3、SSE-C、其他 key、alias/裸 key ID、
以及只带 `aws:kms` 不带 key ARN 的请求仍被桶策略拒绝。

修改默认 key 不会重加密已有对象、历史版本或已有 Secret 版本；任务更新也不等于历史数据迁移。
旧数据仍需旧 key 解密，不能提前禁用或删除旧 key。通过审批后的复制/Batch Operations 等单独迁移并验收。
本次代码不执行历史对象复制、删除或外部 Secret 密钥切换。

## 上线验证

1. 填入真实 `kms_administrator_arns` 及其他环境参数，确认部署角色具备 KMS 创建权限。
2. 审查真实 plan，特别是本轮命名修改引起的资源替换，先制定存量迁移方案。
3. 部署后分别检查 S3 默认加密、TLS Secret 的 KmsKeyId 与两个 key 的轮换状态。
4. 用后端任务角色验证上传/下载；用执行角色验证 TLS 注入；前端任务角色不能使用文件桶 key。
5. 验证错误 key、错误项目角色、跨环境角色不能使用当前 key，人工 TLS 录入身份不能直接用 key 解密其他内容。
6. 验证外部 RDS Secret 的 Key Policy 和实际注入；云上验证未完成前，本地测试不代表已生效。

官方参考：

- [KMS Key Policy 与 IAM 委派](https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html)
- [Terraform KMS Key 资源](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key)
- [S3 SSE-KMS 与权限](https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingKMSEncryption.html)
- [Secrets Manager 加密与权限](https://docs.aws.amazon.com/secretsmanager/latest/userguide/security-encryption.html)
