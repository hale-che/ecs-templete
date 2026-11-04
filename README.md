# ECS Task Definition

三个服务（`frontend-ext` / `frontend-int` / `backend`）的 Task Definition，区域 `cn-north-1`。

管：ECS 集群、三个服务、Task Definition、KMS 加密日志组、每服务一对 IAM 角色、PRD 的自动扩缩容。
不管：安全组、ALB / 目标组 / 监听器、ECR 仓库、RDS、CodeBuild。前三样由 AZ 创建，ID 填进 tfvars。

apply 完就是能跑起来的完整框架 —— 有集群、有服务、有任务在跑。

## 你只需要填这些

每个 `env/*.tfvars` 各填一遍：

| 位置 | 填什么 |
| --- | --- |
| `project` | 项目标识，小写，≤20 字符 |
| `mandatory_tags` | AZ 下发的五个字段 |
| `kms_key_id` | KMS 别名，如 `alias/xxx` |
| `repository` ×3 | 三个 ECR 仓库名 |
| `tag` ×3 | 只有 PRD 要填，DEV/PPD 是 `latest` |
| `subnet_ids` | AZ 给的私有子网，≥2 个 |
| `security_group_ids` ×3 | AZ 给的安全组 |
| `target_group_arn` ×3 | AZ 给的目标组 |

其余字段都不用动。规格（CPU / 内存 / 任务数）已经按确认过的表填好了。

交接给 AZ 看 `docs/handover.md`：谁填什么、填在哪、不填会怎样。
开发打镜像看 `docs/image-requirements.md`。

## 结构

    versions.tf     TF 1.6 + Provider 5.x，空的 S3 backend
    providers.tf    强制 Tag 走 default_tags
    variables.tf    输入
    locals.tf       data 源 + 所有推导：命名、ARN、镜像地址、容器 JSON
    cluster.tf      ECS 集群，一个环境一个，三服务共用
    main.tf         Task Definition
    service.tf      ECS 服务，含 ignore_changes 和部署熔断
    autoscaling.tf  PRD 的 2-4 扩缩容，只给填了 min/max 的服务建
    iam.tf          执行角色 + 任务角色
    logs.tf         日志组
    outputs.tf      按服务名索引
    env/*.tfvars    DEV / PPD / PRD，唯一有环境差异的地方
    docs/           IAM 权限需求、交接清单、镜像要求

`env/*.tfvars` → `var.services` → `locals` 推导 → 资源。拼名字、拼 ARN 全在 `locals.tf`，资源文件里不出现字符串拼接。

## 规格

| 服务 | DEV | PPD | PRD |
| --- | --- | --- | --- |
| `frontend-ext` | 512 / 1024 | 1024 / 2048 | 1024 / 2048 ×2 |
| `frontend-int` | 512 / 1024 | 1024 / 2048 | 1024 / 2048 ×2 |
| `backend` | 2048 / 4096 | 2048 / 8192 | 4096 / 8192 ×2 |

CPU 单位 / 内存 MiB。PRD 三个服务都是 2 个任务起步，扩缩容 2-4，按 CPU 70% 目标跟踪（**阈值待压测确认**）。

DEV / PPD 不填 `min_capacity`/`max_capacity`，所以不建 Auto Scaling，任务数固定。

## 规范对照

| 要求 | 落点 |
| --- | --- |
| Terraform 1.6 | `versions.tf` `~> 1.6.0` |
| AWS Provider > 5.6 | `versions.tf` `>= 5.60.0, < 6.0.0` |
| 禁止硬编码 | 环境差异只在 `env/*.tfvars` |
| 命名规范 | `AZ-CNRDIT-<ENV>-<project>-<服务名>` |
| 最小权限 IAM | 每服务一对角色，ARN 按该服务自己的仓库和密钥收口 |
| IAM 条件限制 | 信任策略带 `aws:SourceAccount` / `aws:SourceArn`，KMS 带 `kms:ViaService` |
| 强制 Tag | 五个字段必填且不许留空，走 `default_tags` |
| KMS 加密 | 日志组强制 CMK |
| 密码不硬编码 | 只传 Secret ARN，密文不进 state |

`mandatory_tags` 的键名是我按理解写的，**拿到 AZ 清单后要核对改名**。IAM 权限清单见 `docs/iam-permissions.md`。

## 发布解耦

Terraform 只注册 revision 1，之后 CodeBuild 改镜像 tag，不动 Terraform 代码。

revision 不可变，state 里那个一直存在，CodeBuild 新注册的不算偏移，所以**不需要** `ignore_changes`，但 `track_latest` 必须保持 `false`。

服务侧的 `ignore_changes = [task_definition, desired_count]` 已经在 `service.tf` 里了。
代价：Terraform 改了 cpu/内存之后会注册新 revision，但**服务不会自动切过去**，要靠下一次 CodeBuild 发版带上，或手动 `update-service`。

对 CodeBuild 那份代码的约束：重新注册 revision 前必须 `describe-task-definition --include TAGS`，否则新 revision 丢掉强制 Tag。

## 跑

    terraform init \
      -backend-config="bucket=<bucket>" \
      -backend-config="key=ecs-taskdef/dev.tfstate" \
      -backend-config="region=cn-north-1" \
      -backend-config="dynamodb_table=<lock-table>" \
      -backend-config="encrypt=true"

    terraform plan -var-file=env/dev.tfvars

换环境只换 `-var-file` 和 backend 的 `key`。

前置：S3 bucket 和 DynamoDB 锁表已存在（1.6 没有 `use_lockfile`）；KMS CMK plan 时必须已存在，且 Key Policy 允许 `logs.<region>.amazonaws.com`。ECR 仓库不要求 plan 时存在。

## 流量路径与健康检查

    外部 ALB → frontend-ext
    内部 ALB → frontend-int   （路径 /）
             → backend        （路径 /api）

三个服务都挂 ALB 目标组，**健康检查全部由目标组做，配在 ALB 那边，不在这份代码里**。
所以这里没有容器健康检查，镜像也不需要 `curl`。

前端调后端走内部 ALB，地址从 `environment` 里的 `BACKEND_URL` 注入，分环境。

## 没支持的

挂卷（EFS / tmpfs）、ECS Exec、多容器 sidecar、SSM Parameter Store、服务发现（Service Connect / Cloud Map）。要哪个再加。

## 注意事项

- `readonly_root_filesystem` 默认 `false`。nginx 要写 `/var/cache/nginx`，设成 `true` 容器起不来。
- 镜像架构固定 `X86_64`，ARM64 镜像跑不起来，报 exec format error。
- Fargate 的 cpu/memory 是固定组合表，`main.tf` 有 precondition 在 plan 阶段拦。
- **三个环境互不影响**，各有独立的 state。但一个环境的 state 里装着它的三个服务，所以对 PRD 跑一次 apply，`frontend-ext`、`frontend-int`、`backend` 会出现在同一个 plan 里 —— 只想改一个服务，也要把整个 plan 看完。
- 第一次 apply 时镜像必须已经推到 ECR，否则服务起不来任务，部署熔断会回滚。
- Container Insights 默认开着，按指标量计费。DEV 要省钱改 `cluster.tf`。
- 服务名同时是容器名，所以只收小写字母数字连字符，有校验。
- **前端 nginx 必须用 `resolver` + 变量形式的 `proxy_pass`。** 默认只在启动时解析一次 ALB 的 DNS 然后永久缓存，ALB 换 IP 后就打到死地址。
- 任务起不来且报 AssumeRole 失败时，先看 `iam.tf` 里信任策略的 `aws:SourceArn` 条件。
- 改服务名（map 的 key）等于删一个建一个，角色和日志组一起重建。
- `ecr:GetAuthorizationToken` 只能用 `*`，API 不支持限定，安全扫描会报，走风险申请。
- `kms:ViaService` 在 aws-cn 的后缀没确认，`iam.tf` 里两种都列了，确认后删掉错的那组。
