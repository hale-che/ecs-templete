# ECS Task Definition

三个服务（`frontend-ext` / `frontend-int` / `backend`）的 Task Definition，区域 `cn-north-1`。

管：ECS 集群、三个服务、Task Definition、日志组、应用文件桶、TLS 证书的 Secret 容器、CodeBuild 项目、每服务的 IAM 角色、PRD 的自动扩缩容。
不管：安全组、ALB / 目标组 / 监听器、ECR 仓库、RDS。前三样由 AZ 创建，ID 填进 tfvars。

apply 完就是能跑起来的完整框架 —— 有集群、有服务、有任务在跑。

## 需要填写的内容

每个 `env/*.tfvars` 各填一遍：

| 位置 | 填什么 |
| --- | --- |
| `project` | 项目标识，小写，≤20 字符 |
| `mandatory_tags` | AZ 下发的五个字段 |
| `repository` ×3 | 三个 ECR 仓库名 |
| `tag` ×3 | 只有 PRD 要填，DEV/PPD 是 `latest` |
| `subnet_ids` | AZ 给的私有子网，≥2 个 |
| `security_group_ids` ×3 | AZ 给的安全组 |
| `target_group_arn` ×2 | AZ 给的目标组，只有两个前端 |
| `repo_url` ×3 | GitHub 仓库地址 |

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
    codebuild.tf    每服务一个构建项目 + webhook
    s3.tf           应用文件桶，Intelligent-Tiering
    secrets.tf      TLS 证书的 Secret 容器（不含值）
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
| IAM 条件限制 | 信任策略带 `aws:SourceAccount` / `aws:SourceArn` |
| 强制 Tag | 五个字段必填且不许留空，走 `default_tags` |
| 密码不硬编码 | 只传 Secret ARN，密文不进 state |
| 加密 | 日志和密钥都用 AWS 托管密钥，不配自管 CMK |

`mandatory_tags` 的键名是我按理解写的，**拿到 AZ 清单后要核对改名**。IAM 权限清单见 `docs/iam-permissions.md`。

## 发布流程

### 首次部署

`terraform apply` 本身不会失败（服务不等任务就绪），但有两样东西 Terraform 给不了，
缺了任务就起不来：**TLS 证书的值**和**镜像**。

1. `terraform apply` —— 集群、服务、Secret 容器、CodeBuild 全部建好，服务此时跑不起任务
2. **填 TLS 证书的值**（Terraform 只建了容器）：

       aws secretsmanager put-secret-value --secret-id "$(terraform output -raw tls_secret_arn)" \
         --secret-string "$(jq -n --arg cert "$(base64 -w0 tls.crt)" \
                                 --arg key  "$(base64 -w0 tls.key)" '{cert:$cert,key:$key}')"

3. 触发 CodeBuild 构建推镜像，tag 和 tfvars 里的一致
4. `aws ecs update-service --force-new-deployment`，任务起来

第 2、3 步漏了的表现分别是 `ResourceInitializationError`（取不到密钥）和
`CannotPullContainerError`（拉不到镜像），都只在任务启动时暴露，plan 和 apply 都不报。

### 之后发版，两种方式代码都支持

| | A 覆盖同 tag | B 注册新 revision |
| --- | --- | --- |
| CodeBuild 做什么 | push 同 tag → `update-service --force-new-deployment` | push 新 tag → describe → register → `update-service --task-definition` |
| revision | 永远停在 1 | 递增 |
| ECR tag 要求 | **必须 `MUTABLE`** | `IMMUTABLE` 也行 |
| 回滚 | 重新 push 旧镜像覆盖 | `update-service` 指回旧 revision |
| 额外 IAM | 无 | `iam:PassRole` |
| **Terraform 改了配置** | **不会自动生效** | 下次发版自动带上 |

最后一行差别最大。服务有 `ignore_changes = [task_definition]`，所以 Terraform 改了
cpu / 内存 / 环境变量 / 证书 ARN 之后虽然会注册新 revision，服务却不会自己切过去。两种方式的区别：

**A 不会自动生效。** `--force-new-deployment` 不带 `--task-definition`，服务保持当前 revision，
新任务只是重新拉了同一个 tag 的镜像。Terraform 那个新 revision 要手动切一次：

    aws ecs update-service --cluster <集群> --service <服务> --task-definition <新 arn>

**B 会自动带上。** `describe-task-definition --task-definition <family>` 不指定 revision 号时
返回的是最新的 ACTIVE revision，也就是 Terraform 刚注册的那个，改完 image 再注册就把改动带进去了。

B 还必须带 `--include TAGS`，否则新 revision 丢掉强制 Tag。

### 证书轮换

改 Secrets Manager 里的值 → `update-service --force-new-deployment` → 新任务拿到新证书。
不用改 Terraform，不用重新打镜像。

## 为什么 Terraform 和发版互不干扰

两个设置撑着这件事，改动它们会直接破坏上面的流程：

- **Task Definition 不设 `ignore_changes`，但 `track_latest` 必须是 `false`。**
  revision 不可变，state 里记的那个一直存在，CodeBuild 新注册的 revision 在 plan 里根本不出现。
  `track_latest = true` 会变成按 family 读最新，于是天天有偏移。
- **服务设 `ignore_changes = [task_definition, desired_count]`。**
  前者让 CodeBuild 指定的 revision 不被 apply 拽回去，后者让 Auto Scaling 能改任务数。

## 应用文件桶

一个环境一个，名字 `az-cnrdit-<env>-<project>-files`（S3 桶名只收小写）。
后端读写它，任务角色权限由 `file_bucket_access = true` 自动生成 —— 对象操作限在桶内，
`ListBucket` 的资源只能是桶本身，这是 S3 的规则。

存储策略按需求配的：

| 项 | 实现 |
| --- | --- |
| 存储方式 | 生命周期规则 day 0 转 Intelligent-Tiering，不依赖应用上传时指定存储类 |
| 未访问降级 | **Intelligent-Tiering 内置 30 天转 Infrequent Access、90 天转 Archive Instant Access，阈值不可配** |
| Archive / Deep Archive Access | 不启用（没写 intelligent_tiering_configuration），所以取回不需要恢复 |
| 版本过期删除 | 不启用，保留规则由业务侧处理 |
| 失败的分片上传 | 7 天后清理。这不是删文件 —— 未完成的分片看不见但一直计费 |

原始需求写的是 60 天 / 120 天，**已确认按 30/90 执行**。Intelligent-Tiering 的三个自动层
（Frequent、30 天转 Infrequent Access、90 天转 Archive Instant Access）是 AWS 内置行为，
阈值不可配置；可配的只有 Archive Access 和 Deep Archive Access，而这两个按要求不启用。

降级没有副作用：这两层都是毫秒级读取、无取回费、无最短存储时长，对象被访问后自动回到 Frequent 层。
所以 30 天和 60 天的差别只是前者更早开始省钱。

## 密钥

| 密钥 | 谁建 | 怎么接 |
| --- | --- | --- |
| TLS 证书（cert / key，base64） | **Terraform 建容器，值人工填** | 自动注入三个服务的 `TLS_CERT` / `TLS_KEY` |
| RDS 密码 | AZ 建 RDS 时生成 | ARN 填进 `services.backend.secrets` |
| Entra ID client credentials | 后续用到再建 | 同上 |

**Terraform 只建 `aws_secretsmanager_secret`，不建 `secret_version`** —— 值不进 state。
代价是首次部署要手工填一次，见上面的第 2 步。

这是刻意的取舍。写 `secret_version` 的话值**一定会进 state**（Terraform 机制，没法规避），
而 state 是 S3 里的对象，读者范围比项目成员列表宽得多。按密钥的实际价值分别决定：

| 密钥 | 能否进 state |
| --- | --- |
| RDS 密码、Entra ID credentials | **不能**。真凭证，泄露等于直接被用 |
| TLS 私钥 | 代价较小（自签且不被校验，安全价值只有加密传输），但为了口径统一也不进 |

考虑过让 Terraform 用 `tls_private_key` + `tls_self_signed_cert` 直接生成证书、省掉手工步骤，
`private_key_pem_pkcs8` 正好是 Spring Boot 要的格式。**没采用**，原因同上：私钥会进 state。
以后要换这个方案，改动只在 `secrets.tf`。

TLS 的 ARN 由 Terraform 产生，没法写进 tfvars，所以在 `locals.tf` 里合进每个服务的 `secrets`。
**tfvars 的 `secrets` 只放 AZ 给的那些**，不用再手抄 ARN 末尾的 6 位随机后缀。

执行角色的 `secretsmanager:GetSecretValue` 权限按实际引用的 ARN 自动生成，加密钥不用改 IAM。

非生产的 `recovery_window_in_days = 0`：否则 destroy 之后同名 Secret 在 30 天恢复期内重建会被拒。

## CodeBuild

一个服务一个项目，`for_each` 出来。**buildspec 放应用仓库**，Terraform 只注入它要的值：

| 环境变量 | 内容 |
| --- | --- |
| `ECR_REPO` | 完整镜像地址，不含 tag |
| `IMAGE_TAG` | tfvars 里的 `tag`。方案 B 可改用 CodeBuild 自带的 `CODEBUILD_RESOLVED_SOURCE_VERSION`（git sha） |
| `CLUSTER` / `SERVICE` | 部署目标 |
| `TASK_FAMILY` | 方案 B 注册新 revision 用 |

**GitHub 凭证是账号级的，Terraform 不管** —— 一次性手工建，避免 token 落进 state：

    aws codebuild import-source-credentials --server-type GITHUB \
      --auth-type PERSONAL_ACCESS_TOKEN --token <PAT>

没有这一步，构建拉不到代码，webhook 也建不出来。

**触发**：`enable_build_webhook` 只在 DEV 开（推 `dev` 分支自动构建部署）。
PPD / PRD 关闭，手工或外部流水线触发：

    aws codebuild start-build --project-name <terraform output codebuild_projects>

**IAM 按方案 B 的权限写的**（B 是 A 的超集）。定了方案 A 就删 `iam.tf` 里
`RegisterTaskDefinition` 和 `PassExecutionAndTaskRoles` 两条语句。

## 执行

    terraform init \
      -backend-config="bucket=<bucket>" \
      -backend-config="key=ecs-taskdef/dev.tfstate" \
      -backend-config="region=cn-north-1" \
      -backend-config="dynamodb_table=<lock-table>" \
      -backend-config="encrypt=true"

    terraform plan -var-file=env/dev.tfvars

换环境只换 `-var-file` 和 backend 的 `key`。

前置：S3 bucket 和 DynamoDB 锁表已存在（1.6 没有 `use_lockfile`）。ECR 仓库不要求 plan 时存在。

## 流量路径与健康检查

    外部 ALB  →8443 HTTPS→  frontend-ext
    内部 ALB  →8443 HTTPS→  frontend-int
                              └─8002 HTTPS─→  backend   （Service Connect，不经 ALB）

全链路 HTTPS，证书由 Secrets Manager 注入容器，三跳都不校验证书。

- 两个前端挂 ALB 目标组，健康检查由目标组做，配在 ALB 那边
- **后端不挂 ALB**，健康检查靠 `health_check_command`，所以**后端镜像里必须有 `curl`**
- 前端调后端用 `https://backend-service:8002`，三个环境同名

## 暂不支持

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
