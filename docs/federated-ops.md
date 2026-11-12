# AZ Federated Role 运维权限交付

项目组交付权限 Policy JSON，AZ 负责 Federated Role、企业 SSO、信任策略及策略关联。

## DEV 扩充交付

当前 DEV 文件位于 [`policies/federated-ops/dev/`](../policies/federated-ops/dev/README.md)，
账号 `332091793104`、区域 `cn-north-1`、项目 `aiec`、环境 `dev`。
按 DEV 开发运维需求扩充为三份，以 txt 保存合法 IAM Policy JSON：

| 文件 | 用途 |
| --- | --- |
| `AWS_CN_RDIT_AIEC_DEVOPS_DEV-policy01.txt` | 只读排查及相关基础配置查询 |
| `AWS_CN_RDIT_AIEC_DEVOPS_DEV-policy02.txt` | DEV ECS、ECR、CodeBuild、S3、日志、Secret、监控及 PassRole |
| `AWS_CN_RDIT_AIEC_DEVOPS_DEV-policy03.txt` | DEV 服务角色及内联策略、服务关联角色、KMS key / alias、Cloud Map |

只读人员关联第一份；完整 DEV 运维关联三份。每份须在 IAM 单个托管策略的 6144 字符上限内。
文件名及排版参考 `examples/` 中的三个 txt，权限及资源依据当前 AIEC 项目配置。

DEV 管理权限包括直接注册 Task Definition、修改服务和构建配置、推送/删除镜像、读写文件及 Secret，
不同于原先只允许服务更新和构建触发的标准策略。
项目资源按 DEV 名称、账号/区域、已有资源标签或创建请求标签限定；查询可见部分区域级和账号级元数据。
IAM 内联策略修改及构建项目修改具有较大间接授权能力，这些身份 Allow 策略并非隔离其他环境的 Permissions Boundary。

三个 ECR 仓库名仍为占位符，policy01 / policy02 均须填写实际值。
KMS 管理和数据使用仍须对应 Key Policy 授权；ECS Exec 仍须配置任务角色及运行环境。
项目未给出实际 Terraform state 桶 / 锁表及外部 RDS Secret ARN，这些资源不猜测授权。
`ecs:DeregisterTaskDefinition` 不支持资源级限定，本次未授予区域级注销权限。
具体覆盖范围、前提及未覆盖项见 [DEV README](../policies/federated-ops/dev/README.md)。

DEV 扩充文件独立维护，上级标准生成模块和 `export.py` 不会生成这三份文件，请勿覆盖。
本次不修改 PPD / PRD 的标准策略或运行中的 AWS 角色。

## 标准策略生成模块

`policies/federated-ops/main.tf`、`export.py` 和根模块 `federated-ops.tf` 的两个 outputs
继续提供标准的只读 / 有限运维策略，适用于继续使用原授权范围的环境。
标准只读策略包含 ECS、项目日志、镜像元数据、构建结果及指标查询；标准操作策略只允许
更新现有服务、切换本服务已有 revision、传递六个 ECS 角色，以及触发/停止现有 CodeBuild 构建。
标准策略不提供直接注册 Task Definition、推镜像、修改构建项目、读取 Secret / S3 业务文件或 IAM / KMS 管理权限。

标准操作策略还保留以下条件：

- `UpdateService` 仅能选择本服务 family，不允许开启 ECS Exec。
- `iam:PassRole` 仅传给 `ecs-tasks.amazonaws.com`。
- `StartBuild` 不允许覆盖 buildspec、源码地址、环境变量、镜像、凭证、角色、产物和日志等配置；仍能选择分支/commit。

标准策略中的区域发现、指标和任务定义元数据查询使用 `Resource: "*"` 并限制区域；
`ListServices` / `ListTasks` 使用本集群条件。它们也是附加 Allow，并不撤销角色原有权限。

### 独立离线导出标准策略

要求 Terraform 1.6.x 和 Python 3。不需要 AWS Provider、凭证、S3 backend 或根项目 apply。
在项目根目录执行：

```bash
cp policies/federated-ops/example.tfvars policies/federated-ops/standard.local.tfvars
```

填入实际 `account_id`、`cluster_name` 和 `service_repositories`。
集群名为 `az-cn-rdit-<project>-ecs-fargate-<environment>`，仓库名须与对应 `env/*.tfvars` 一致。
默认分区 / 区域是 `aws-cn` / `cn-north-1`。

```bash
python3 policies/federated-ops/export.py \
  --var-file policies/federated-ops/standard.local.tfvars \
  --output-dir policies/federated-ops/generated/standard
```

脚本在临时目录运行本地 init / plan / show，检查无资源变更并检查策略大小，不执行 apply。
输出 `federated-ops-readonly.json` 和 `federated-ops-operations.json`。

### 根项目标准输出

`federated-ops.tf` 从根项目获取实际账号、环境和仓库输入。
按既有流程部署且 state 中已有对应 outputs 后，可导出标准策略：

```bash
terraform output -raw federated_ops_readonly_policy_json > federated-ops-readonly.json
terraform output -raw federated_ops_operations_policy_json > federated-ops-operations.json
```

只为生成标准 Policy 无需运行根项目 apply，优先使用独立模块。

## 验证

DEV 文件检查：

```bash
python3 tests/check-dev-federated-policies.py
```

该脚本检查 JSON、语言版本、大小及典型的本地权限匹配：DEV 发布、数据管理、PassRole 服务限定、
跨环境资源不直接匹配、KMS 标签及 namespace 创建条件。
它不实现完整 IAM 授权评估，不等于 Policy Simulator、Access Analyzer 或真实账号验收。

标准生成模块检查：

```bash
terraform -chdir=policies/federated-ops init -backend=false
terraform -chdir=policies/federated-ops validate
terraform -chdir=policies/federated-ops test
```

AZ 关联时需检查角色其他策略、SCP、Boundary 和资源策略的最终效果；
DEV 数据读写、KMS、Exec 和构建变更按扩充范围验收，标准环境继续按原有限操作范围验收。

官方授权依据：

- [IAM 策略语言版本](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_version.html)
- [ECS Action / Resource / Condition](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ecs.html)
- [CodeBuild Action / Resource / Condition](https://docs.amazonaws.cn/en_us/service-authorization/latest/reference/list_codebuild.html)
- [CloudWatch Logs Action / Resource](https://docs.aws.amazon.com/service-authorization/latest/reference/list_logs.html)
- [KMS Key Policy](https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html)
- [AWS 机器可读服务授权参考](https://docs.aws.amazon.com/service-authorization/latest/reference/service-reference.html)
