# ECS Task Definition

三个服务（`frontend-ext` / `frontend-int` / `backend`）的 Task Definition，区域 `cn-north-1`。

管：ECS 集群、三个服务、Task Definition、日志组、应用文件桶、ECR 仓库、CodeBuild 项目、每服务的 IAM 角色、项目专用的 S3 / CloudWatch Logs 两把 CMK。
不管：安全组、ALB / 目标组 / 监听器、RDS、Secrets Manager 里的密钥、存 state 的 S3 桶和锁表。前三样由 AZ 创建，ID 填进 tfvars。

apply 完就是能跑起来的完整框架 —— 有集群、有服务、有任务在跑。

## 需要填写的内容

每个 `env/*.tfvars` 各填一遍：

| 位置 | 填什么 |
| --- | --- |
| `project` | 项目标识，小写，2–17 字符 |
| `mandatory_tags` | AZ 要求的七个标签；已填所提供的值，创建日期需填写实际值 |
| `repository` ×3 | 三个 ECR 仓库名，本模板按这个名字建仓库，只收小写 |
| `tag` ×3 | 各环境首次部署使用的已推送时间戳 tag，例如 `20261112153045`；不控制 CodeBuild 构建 tag |
| `subnet_ids` | AZ 给的私有子网，≥2 个 |
| `security_group_ids` ×3 | AZ 给的安全组 |
| `target_group_arn` ×2 | AZ 给的目标组，只有两个前端 |
| `repo_url` ×3 | GitHub 仓库地址 |
| `kms_administrator_arns` | AZ 密钥管理员及实际执行 Terraform 的 IAM 角色 ARN，每环境单独填写 |

S3 和日志组分别使用本项目创建的 CMK，自动开启轮换。TLS 等外部 Secret 如使用 CMK，接入方式见 `docs/kms.md`。任务数固定：DEV/PPD 每服务 1 个，PRD 每服务 2 个。

交接给 AZ 看 `docs/handover.md`：谁填什么、填在哪、不填会怎样。
开发打镜像看 `docs/image-requirements.md`。

AZ 运维人员的 Federated Role 只需交付 Policy，见 [运维权限交付说明](docs/federated-ops.md)。
`policies/federated-ops/dev/` 存放扩充后的三份 DEV 运维策略。
上级纯生成模块可离线生成标准只读及有限运维两份 JSON，**不参与主项目 apply**；DEV 那三份扩充文件由人工维护。
角色、SSO 和策略关联由 AZ 管理，本模板不创建人员角色。

## 结构

    versions.tf     TF 1.6 + Provider 5.x，空的 S3 backend
    providers.tf    强制 Tag 走 default_tags
    variables.tf    输入
    locals.tf       data 源 + 所有推导：命名、ARN、镜像地址、容器 JSON
    cluster.tf      ECS 集群，一个环境一个，三服务共用
    main.tf         Task Definition
    service.tf      ECS 服务，含 ignore_changes 和部署熔断
    iam.tf          执行角色 + 任务角色
    logs.tf         日志组
    ecr.tf          每服务一个镜像仓库 + untagged 清理
    codebuild.tf    每服务一个构建项目，不含触发器
    s3.tf           应用文件桶，Intelligent-Tiering
    kms.tf          创建每环境 S3 / Logs 两把 CMK、别名、轮换和项目隔离 Key Policy
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

CPU 单位 / 内存 MiB。三个环境均不创建 Auto Scaling：DEV/PPD 每服务固定 1 个任务，PRD 每服务固定 2 个任务。`desired_count` 由 Terraform 持续管理。

## 规范对照

| 要求 | 落点 |
| --- | --- |
| Terraform 1.6 | `versions.tf` `~> 1.6.0` |
| AWS Provider > 5.6 | `versions.tf` `>= 5.60.0, < 6.0.0` |
| 禁止硬编码 | 环境差异只在 `env/*.tfvars` |
| 命名规范 | `az-cn-rdit-<project>-<资源用途>-<dev|ppd|prd>` |
| 最小权限 IAM | 每服务一对角色，ARN 按该服务自己的仓库和密钥收口 |
| IAM 条件限制 | CodeBuild 信任精确限定项目 ARN；支持的操作增加项目标签/集群条件；ECS 信任限制见整改记录 |
| 强制 Tag | 七个字段必填且不许留空，走 `default_tags` |
| 密码不硬编码 | 只传 Secret ARN，密文不进 state |
| S3 加密 | SSE-KMS，使用本模板创建的项目 CMK；桶策略禁止显式改用其他加密方式或密钥 |
| Secrets 加密 | 密钥由外部创建，模板只引用 ARN；使用 CMK 的按实际 key ARN 配置执行角色权限 |

`mandatory_tags` 使用 AZ 提供的七个键名：`applicationname`、`applicationowner`、`Cost Center`、`IDMD No`、`applicationid`、`environment`、`creationdate`。
实际值填写在各环境的 `env/*.tfvars`；`applicationid` 只填 `SNSVC0008172`，不包含链接格式。
`creationdate` 当前为占位值，部署前填写实际日期；环境标签统一用小写 `dev` / `ppd` / `prd`，和 `var.environment` 一致，**AZ 若规定了别的写法以他们为准**。
另外加两个内部标签 `Project`、`ManagedBy`，其中 `Project` 用于 IAM / KMS 授权条件。环境标签用 AZ 的 `environment`，不再额外加大写的 `Environment`（标签键区分大小写，会变成两个）。
IAM 权限清单见 `docs/iam-permissions.md`。

## 发布流程

### 首次部署

`terraform apply` 本身不会失败（服务不等任务就绪），但有两样东西 Terraform 给不了，
缺了任务就起不来：**Secrets Manager 里的密钥**和**镜像**。

1. **确认 `tls_secret_arn` 指向的密钥已有 `cert` / `key` 两个 JSON 键**，值是 base64：

       aws secretsmanager get-secret-value --secret-id aiec/personal/tls \
         --query SecretString --output text | jq 'keys'

2. `terraform apply` —— 集群、服务、ECR、CodeBuild、两把 CMK 全部建好，服务此时跑不起任务
3. 触发 CodeBuild 构建推镜像，把实际生成的时间戳 tag 填进 tfvars 的 `services.*.tag`
4. 部署 ECS（`update-service` 指向对应 revision），任务起来

第 1、3 步漏了的表现分别是 `ResourceInitializationError`（取不到密钥）和
`CannotPullContainerError`（拉不到镜像），都只在任务启动时暴露，plan 和 apply 都不报。

### 之后发版

当前统一使用北京时间 `yyyyMMddHHmmss` 的构建时间戳 tag。发布使用下面的方案 B，
或按构建记录中的已批准 digest 注册新 revision；方案 A 的同 tag 覆盖不适用于当前约定。

| | A 覆盖同 tag | B 注册新 revision |
| --- | --- | --- |
| CodeBuild 做什么 | push 同 tag → `update-service --force-new-deployment` | push 新 tag → describe → register → `update-service --task-definition` |
| revision | 永远停在 1 | 递增 |
| ECR tag 要求 | 不适用 —— 时间戳 tag 不覆盖 | 当前默认 `MUTABLE`；时间戳 tag 唯一，也可改 `IMMUTABLE` |
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

## Terraform 与发版的边界

Terraform 管配置，CodeBuild 管镜像和部署，互不覆盖。靠两个设置撑着：

- **Task Definition 不设 `ignore_changes`，但 `track_latest` 必须是 `false`。**
  revision 不可变，state 里记的那个一直存在，CodeBuild 新注册的 revision 在 plan 里根本不出现。
  `track_latest = true` 会变成按 family 读最新，于是天天有偏移。
- **服务设 `ignore_changes = [task_definition]`。**
  让 CodeBuild 指定的 revision 不被 apply 拽回去。自动扩缩容已关闭，任务数由 Terraform 维护。

改动这两处会直接破坏上面的发布流程。

## 应用文件桶

一个环境一个，名字 `az-cn-rdit-<project>-files-<environment>`（S3 桶名只收小写）。
后端读写它，任务角色权限由 `file_bucket_access = true` 自动生成 —— 对象操作限在桶内，
`ListBucket` 的资源只能是桶本身，这是 S3 的规则。

按最新 PR 评审，本模板为每个环境创建专用 S3 CMK 和 CloudWatch Logs CMK；密钥由 AZ 管理员运维。
S3 开启 SSE-KMS 和 Bucket Key，后端任务角色获得限定到文件桶、密钥和 S3 服务上下文的权限。
两把 CMK 均开启自动轮换、配置 30 天删除等待期，并设置 Terraform `prevent_destroy`。
部署前填 `kms_administrator_arns`，其中必须包含实际部署角色的 IAM ARN。详见 `docs/kms.md`。

上传不带加密请求头时使用桶默认值；显式指定加密时必须同时指定 `aws:kms` 和上述完整 key ARN。
SSE-S3、SSE-C、其他密钥，以及只指定 `aws:kms` 而不指定 key ARN 的上传会被拒绝。
修改默认加密不会重加密已有对象或历史版本；迁移和验收步骤见 `docs/kms.md`。

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

## ECR 仓库

一服务一个，名字取 `services.*.repository`，由 `ecr.tf` 创建。两个服务填同一个名字就只建一个仓库。

| 项 | 值 | 说明 |
| --- | --- | --- |
| tag 可变性 | `ecr_image_tag_mutability`，默认 `MUTABLE` | 时间戳 tag 唯一，可改 `IMMUTABLE`；辅助 `sha-<commit>` 标签重复推送会被拒 |
| 推送时扫描 | 开 | 基础扫描，不额外计费 |
| 加密 | AES256 | 不用 CMK —— `aws_kms_key.files` 的 key policy 限定了 `kms:ViaService = s3`，ECR 用不了 |
| untagged 清理 | `ecr_untagged_expire_days`，默认 30 天 | 覆盖推送同一 tag 会把旧镜像变成 untagged，不清理会一直计费 |
| 镜像数上限 | `ecr_max_image_count`，默认 30 | tag 唯一时镜像只增不减；超出 30 个按推送时间从旧到新删 |

`force_delete` 没开，所以仓库里有镜像时 `terraform destroy` 会失败 —— 这是刻意的。

tag 约定见 `docs/image-requirements.md` 第 8 节：主 tag 是 buildspec 生成的北京时间 `yyyyMMddHHmmss`，
另带 `sha-<commit>` 辅助标签。`services.*.tag` 只是首次部署引用的那个已存在 tag。

仓库名含大写会在 plan 阶段报错（`variables.tf` 的 validation），ECR 不收大写。

## 密钥

**密钥全部在 Terraform 之外创建，模板只引用 ARN，值不进 state。**

| 密钥 | 密钥键 | 注入成 | 形式 |
| --- | --- | --- | --- |
| TLS 证书 | `aiec/personal/tls` | 三个服务的 `TLS_CERT` / `TLS_KEY` | 取 `cert` / `key` 两个 JSON 键 |
| 后端各项配置 | `aiec/personal/backend-runtime` | backend 的 `BACKEND_RUNTIME` | 整段 JSON |
| 数据库帐号密码 | `aiec/personal/database` | backend 的 `DATABASE` | 整段 JSON |

TLS 单独做成变量而不是塞进每个服务的 `secrets`，因为三个服务都要用，统一注入省得重复填。

ARN 必须是完整形式，**结尾那 6 位随机后缀不能省** —— 名字推不出来，从控制台复制或者：

    aws secretsmanager describe-secret --secret-id aiec/personal/tls --query ARN --output text

引用 JSON 里的某个键，在 ARN 后面接 `:键名::`，例如 `...:secret:aiec/personal/database-AbCdEf:password::`。
`locals.tf:72` 会按冒号截取前 7 段还原出 Secret 本体 ARN，用来生成 IAM 权限。

执行角色的 `secretsmanager:GetSecretValue` 按实际引用的 ARN 自动生成，不会给到别的 Secret。
这些 Secret 如果用了 CMK，在引用它的服务里填 `secrets_kms_key_arns`，执行角色会拿到限定到
具体 key、Secrets Manager 服务和实际 Secret 上下文的 `kms:Decrypt`；AZ 那边要为这些 key 配好 Key Policy。

## CodeBuild

一个服务一个项目，`for_each` 出来。**buildspec 放应用仓库**，Terraform 只注入它要的值：

同一个 Git 仓库可以构建多个服务：各服务填写相同的 `repo_url`，并用 `buildspec` 指定
相对于仓库根目录的构建文件路径。不填 `buildspec` 时默认使用根目录的 `buildspec.yml`。
DEV 已配置为同一个 `https://github.com/AZU-RDIT/AIEC.git` 仓库，分别读取：

| 服务 | 构建文件 |
| --- | --- |
| 外网前端 `frontend-ext` | `frontend-ext/buildspec.yml` |
| 内网前端 `frontend-int` | `frontend-int/buildspec.yml` |
| 后端 `backend` | `backend/buildspec.yml` |

以上目录及文件需要在应用仓库对应分支中存在：DEV 使用 `dev`，PPD / PRD 使用 `main`。
三个环境已使用同一个 AZ 仓库及上述 buildspec 路径；ECR 仓库名及首次部署镜像 tag 仍需填写。
`frontend-ext` / `frontend-int` 仅存构建入口，两者都使用仓库根目录的 `frontend` 共享源码。
`backend` 存后端源码和构建入口。交付布局及运行变量见应用交付包 `doc/container-images.md`。
`buildspec` 文件放在子目录不会自动切换构建工作目录，构建命令须明确指定目录或先 `cd`。
例如后端的 Dockerfile 不依赖仓库根目录文件时，可使用：

```yaml
version: 0.2
phases:
  pre_build:
    commands:
      - export IMAGE_TAG="$(TZ=Asia/Shanghai date +%Y%m%d%H%M%S)"
  build:
    commands:
      - docker build -f backend/Dockerfile -t "$ECR_REPO:$IMAGE_TAG" backend
```

这只展示构建步骤。应用交付包的 buildspec 已包含 ECR 登录、构建、推送及 digest 记录，
**当前不执行 ECS 部署**。上文的后续发版 A / B 是独立发布流程说明，不是当前 buildspec 的行为。
如需读取根目录的共享文件，按实际 Dockerfile 调整构建上下文。
`repository` 仍填写各服务自己的 ECR 镜像仓库名，与 Git 仓库及源码目录分别配置。

| 环境变量 | 内容 |
| --- | --- |
| `ECR_REPO` | 完整镜像地址，不含 tag |
| `IMAGE_TAG` | **Terraform 不注入** —— 由 buildspec 在 `pre_build` 生成一次，北京时间 `yyyyMMddHHmmss`，构建/推送/记录复用同一个值 |
| `CLUSTER` / `SERVICE` | 部署目标 |
| `TASK_FAMILY` | 方案 B 注册新 revision 用 |

**GitHub 凭证是账号级的，Terraform 不管** —— 一次性手工建，避免 token 落进 state：

    aws codebuild import-source-credentials --server-type GITHUB \
      --auth-type PERSONAL_ACCESS_TOKEN --token <PAT>

没有这一步，构建拉不到代码 —— 私有仓库不管用什么方式触发都要这个凭证。

**触发**：模板不建任何触发器，没有 webhook。手工或外部流水线调 API：

    aws codebuild start-build --project-name <terraform output codebuild_projects> \
      --source-version <分支或 commit>

`--source-version` 可覆盖 tfvars 里的 `branch`，发指定 commit 用它。外部流水线（GitHub Actions
之类）调同一个 API，需要一个有 `codebuild:StartBuild` 权限的身份。按目录判断该构建哪个服务的逻辑
放在流水线里，比 webhook 的 filter 灵活 —— 三个服务共用一个仓库，webhook 按分支过滤会一次触发三个。

**IAM 按方案 B 的权限写的**。注册新 revision 时必须保留 `Project`、`environment` 和其余强制标签；
注册和 TagResource 权限只限定本服务 family。若采用方案 A，可移除注册/打标签/角色传递权限。

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

目标是全链路 HTTPS，证书由 Secrets Manager 注入容器；镜像须加载证书并开启 TLS。
Service Connect 当前按 TCP 透传应用 TLS，开启代理本身不会启用 HTTPS。
前端 Nginx 到后端沿用 `proxy_ssl_verify off` 的自签证书方案，传输加密但不验证后端身份。

- 两个前端挂 ALB 目标组，健康检查由目标组做，配在 ALB 那边
- **后端不挂 ALB**，健康检查靠 `health_check_command`，所以**后端镜像里必须有 `curl`**
- 前端调后端用 `https://backend-service:8002`，三个环境同名
- Terraform 校验两个前端的 `BACKEND_URL` 必须使用 HTTPS；镜像配置和部署后验收见 [镜像要求](docs/image-requirements.md)

## 暂不支持

挂卷（EFS / tmpfs）、ECS Exec、自定义多容器 sidecar、SSM Parameter Store。Service Connect 及其托管代理已启用。

## 注意事项

- `readonly_root_filesystem` 默认 `false`。nginx 要写 `/var/cache/nginx`，设成 `true` 容器起不来。
- 镜像架构固定 `X86_64`，ARM64 镜像跑不起来，报 exec format error。
- Fargate 的 cpu/memory 是固定组合表，`main.tf` 有 precondition 在 plan 阶段拦。
- **三个环境互不影响**，各有独立的 state。但一个环境的 state 里装着它的三个服务，所以对 PRD 跑一次 apply，`frontend-ext`、`frontend-int`、`backend` 会出现在同一个 plan 里 —— 只想改一个服务，也要把整个 plan 看完。
- 第一次 apply 时镜像必须已经推到 ECR，否则服务起不来任务，部署熔断会回滚。
- Container Insights 默认开着，按指标量计费。DEV 要省钱改 `cluster.tf`。
- 服务名同时是容器名，所以只收小写字母数字连字符，有校验。
- **前端 Nginx 在启动时将 `BACKEND_URL` 渲染到静态 `proxy_pass`。** Service Connect 的端点通过任务内 hosts 解析，不使用旧的 ALB 动态 DNS 模板；先创建后端端点，再启动或重新部署前端任务。
- 任务起不来且报 AssumeRole 失败时，先看 `iam.tf` 里信任策略的 `aws:SourceArn` 条件。
- 改服务名（map 的 key）等于删一个建一个，角色和日志组一起重建。
- `ecr:GetAuthorizationToken` 只能用 `*`，API 不支持限定，安全扫描会报，走风险申请。

## 本轮 PR findings

逐项整改、AWS 权限限制及部署迁移注意事项见 [评审整改记录](review-findings.md)。
