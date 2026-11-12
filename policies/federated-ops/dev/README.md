# AIEC DEV Federated Role Policy JSON

这两份 JSON 是从当前 Terraform 策略生成模块导出的 DEV 模板，仅用于审阅和补全后交付。
项目为 `aiec`，区域为 `cn-north-1`，分区为 `aws-cn`，集群为 `az-cn-rdit-aiec-ecs-fargate-dev`。

| 文件 | 用途 |
| --- | --- |
| `federated-ops-readonly.template.json` | 只读排查权限 |
| `federated-ops-operations.template.json` | 服务更新、构建触发/停止及所需角色传递权限；需同时关联只读策略 |

## 交付前必须替换

| 占位符 | 实际值 |
| --- | --- |
| `REPLACE_ME_ACCOUNT_ID` | DEV 所在 AWS 中国区账号的 12 位账号 ID，两份文件中的所有出现位置均需替换 |
| `REPLACE_ME_ECR_FRONTEND_EXT` | 外网前端 ECR 仓库名，与 `env/dev.tfvars` 的 `services.frontend-ext.repository` 一致 |
| `REPLACE_ME_ECR_FRONTEND_INT` | 内网前端 ECR 仓库名，与 `env/dev.tfvars` 的 `services.frontend-int.repository` 一致 |
| `REPLACE_ME_ECR_BACKEND` | 后端 ECR 仓库名，与 `env/dev.tfvars` 的 `services.backend.repository` 一致 |

仓库名不含 registry 域名、镜像 tag 或 ARN；实际名称中若有命名空间路径，保留完整路径。
ECR 占位符仅出现在只读策略中。两份文件都是合法 JSON，但含占位符时不是可直接部署的 IAM Policy。
获得实际参数后，优先使用上级目录的 `export.py` 重新生成正式文件，避免手工替换遗漏。

这些文件只包含权限 Policy，不包含 Federated Role 的 SSO 信任策略，也不会创建或关联角色。
权限边界、区域级只读列表可见范围、验收要求和重新生成方法见 [交付说明](../../../docs/federated-ops.md)。
后续修改策略生成模块时需同步重新生成这两份模板。
