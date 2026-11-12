# AZ Federated Role 运维权限交付

合作方已明确：角色供后续 AZ 运维人员使用，项目组**只交付 Policy**。
AZ 负责创建/选择 Federated Role、企业 SSO、信任策略及策略关联。本项目不修改这些配置。

## 交付文件

已提供 AIEC DEV 专用 JSON 模板，见 [`policies/federated-ops/dev/`](../policies/federated-ops/dev/README.md)。
项目和环境名称已固定为 `aiec` / `dev`；账号 ID 和三个 ECR 仓库名仍须替换，不能直接部署含占位符的模板。

一次按一个账号、一个环境生成两份 JSON，建议在 AZ 侧分别建为客户托管策略：

| 文件 | 用途 |
| --- | --- |
| `federated-ops-readonly.json` | 查看 ECS 状态、服务事件、任务退出信息，读取本项目应用和构建日志，查看镜像元数据、构建结果及指标 |
| `federated-ops-operations.json` | 运维操作附加策略，与只读策略一起关联；允许更新现有服务、切换已存在的 revision、触发/停止现有 CodeBuild 构建 |

值班只读人员只关联第一份；承担发布及服务变更的人员关联两份。
每份生成时检查 IAM 单个托管策略的 6144 字符限制。不要把六份环境策略合为一个文件。

`policies/federated-ops/examples/` 中的 JSON 是用 `example.tfvars` 生成的可审阅示例，
账号 `123456789012`、项目 `example`、仓库名均为示例，**不能直接用于真实账号**。
真实账号、项目和仓库名当前仍未填写，正式交付前需用实际值重新生成。

## 资源与权限边界

- ECS 服务、CodeBuild 项目、ECR 仓库和六个日志组按输入的服务名单逐个列举 ARN。
- 任务只读权限限定本环境集群下的长格式任务 ARN，适用于当前新建的 Fargate 集群。
- 每个服务的 `UpdateService` 只能选择自己的 Task Definition family，不允许借此切到其他服务的定义或开启 ECS Exec。
- `iam:PassRole` 仅包含本环境服务现有的执行/任务角色，并限定传给 `ecs-tasks.amazonaws.com`。
  这用于更新服务采用已有 revision；不包含 CodeBuild 角色或创建/修改角色的权限。
- `StartBuild` 仅限本环境现有项目；要求请求中不带 buildspec、源码地址、环境变量、镜像、凭证、角色、产物及日志等敏感覆盖参数。
  分支/commit（`sourceVersion`）仍可选择，因此有该权限的人具有实际发布能力，生产发版流程仍由 AZ 管理。
- 不包含直接注册/注销 Task Definition、推送/删除 ECR 镜像、创建/删除服务、单独启动/停止任务、ECS Exec。
- 不包含直接读取/修改 Secrets 值、TLS 私钥、S3 业务文件、Terraform state、KMS 解密或 IAM 管理。
  运维人员仍能读取应用/构建日志；日志中不能输出密码、私钥或业务敏感数据。
- 此策略不提供 RDS、网络、ALB/WAF 或 KMS 的管理权限，相关基础设施由 AZ 管理。
  也不是执行 `terraform apply` 的授权清单。

`ecs:UpdateService` 是一个范围较广的 API：除了重部署、revision 切换和任务数调整，
它还可修改服务的其他配置。IAM 无法把此授权严格等同于“仅重启”，不要按“仅重启权限”交付。
修改 `desired_count` 会影响容量，当前无 Auto Scaling，下一次 Terraform apply 会恢复 tfvars 指定的任务数。
回滚通过选择本服务已存在的 revision 完成，不给人员直接注册任意新 revision 的权限。
发布和回滚后的代码依然使用 ECS 的任务/执行角色权限，不能将本策略描述为完全无法间接接触应用数据。

### `Resource: "*"` 的例外

以下只读 API 无法全部按项目 ARN 隔离，因此单独列出并限制区域：

- ECS 集群/任务定义列表、`DescribeTaskDefinition`；后者按官方授权表不支持资源级限定。
- CloudWatch 指标列表与读取、CloudWatch Logs 日志组列表、CodeBuild 项目列表。

这意味着可见该账号当前区域的其他资源列表、指标及任务定义元数据，
但不能因此读取其他项目的日志内容、构建详情或 Secret 值。
不接受该可见范围时，AZ 可删除 `RegionalDiscoveryAndMetrics` 语句；届时需直接使用已知 ARN，
控制台发现资源、查看指标以及读取任务定义的功能会受限。

`ListServices` / `ListTasks` 另以 `Resource: "*"` 配合 `ecs:cluster` 条件，只允许本集群。
任何无 Secret 引用的明文环境变量仍可出现在任务定义/构建元数据中，不应把凭证写入明文变量。

这是附加的 Allow 策略，不是 Permissions Boundary；若现有角色已拥有更大权限，本策略不会撤销那些权限。
AZ 关联时需结合角色其他策略、SCP 和 Boundary 检查最终权限。

## 无需 AWS 账号访问的生成方式

要求 Terraform 1.6.x 和 Python 3。独立模块只包含变量、locals 和 outputs，
不需要 AWS Provider、凭证、S3 backend 或执行根项目的 apply。

从项目根目录执行：

```bash
cp policies/federated-ops/example.tfvars policies/federated-ops/dev.local.tfvars
```

在 `dev.local.tfvars` 填实际的 `account_id`、`cluster_name` 和 `service_repositories`。
集群名与主项目一致：`az-cn-rdit-<project>-ecs-fargate-dev`；PPD / PRD 各准备一个参数文件。
仓库名要与各环境 `env/*.tfvars` 一致，不带 registry 地址或镜像 tag。
模块默认为 `aws-cn` / `cn-north-1`，有差异时显式填写 `partition` / `region`。

```bash
python3 policies/federated-ops/export.py \
  --var-file policies/federated-ops/dev.local.tfvars \
  --output-dir policies/federated-ops/generated/dev
```

脚本在临时目录执行本地 `init`、`plan` 和 `show`，不执行 apply；导出前验证没有资源变更。
两份最终 JSON 位于指定目录，直接交给 AZ，不需要提交角色或信任策略。
PPD / PRD 换对应的参数文件和输出目录，按环境分别关联。

## 从主项目输出

根模块的 `federated-ops.tf` 使用主项目的实际账号、环境和仓库参数，避免另抄 ARN。
已有工作目录增加本地模块后需重新运行一次 `terraform init`。
在主项目按既有流程完成正常部署、state 中已有新 outputs 后，可导出：

```bash
terraform output -raw federated_ops_readonly_policy_json > federated-ops-readonly.json
terraform output -raw federated_ops_operations_policy_json > federated-ops-operations.json
```

仅为交付 Policy 不需要运行主项目 apply，使用上面的独立生成方式即可。

## 验证

```bash
terraform -chdir=policies/federated-ops init -backend=false
terraform -chdir=policies/federated-ops validate
terraform -chdir=policies/federated-ops test
```

本地测试检查只读/操作边界、服务与任务定义对应关系、环境隔离、实际仓库名和通配符输入拦截。
这些检查不等于 AWS IAM Policy Simulator、Access Analyzer 或真实账号的授权验收。
AZ 落地后需确认：本项目查看/重部署/触发构建/回滚可用，跨环境修改、直接读取 Secret 和业务文件不可用；
并核对现有角色上的其他策略是否扩大权限。StartBuild 条件需在中国区实际账号验证。

官方授权依据：

- [ECS Action / Resource / Condition](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ecs.html)
- [CodeBuild Action / Resource / Condition（中国区）](https://docs.amazonaws.cn/en_us/service-authorization/latest/reference/list_codebuild.html)
- [CodeBuild 请求条件与 buildspec 覆盖控制](https://docs.aws.amazon.com/codebuild/latest/userguide/action-context-keys.html)
- [CloudWatch Logs Action / Resource](https://docs.aws.amazon.com/service-authorization/latest/reference/list_logs.html)
