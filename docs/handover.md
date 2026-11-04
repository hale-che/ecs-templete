# 交接清单

## 架构

    用户（公网）  →  外部 ALB  →  frontend-ext  (80)
    用户（内网）  →  内部 ALB  →  frontend-int  (80)   监听规则 /
                              →  backend       (8080)  监听规则 /api
                                      ↓
                                     RDS

- 前端 nginx 把 `/api` 反代到**内部 ALB**，地址从 `BACKEND_URL` 环境变量进来
- 三个服务都跑 Fargate，在私有子网，不分配公网 IP
- 健康检查全部由 **ALB 目标组**做，配在 ALB 那边，不在这份代码里
- 一个环境一个 ECS 集群，三个服务共用

**这份代码建：** ECS 集群、3 个服务、3 个 Task Definition、3 个 KMS 加密日志组、6 个 IAM 角色、PRD 的自动扩缩容。
**这份代码不建：** VPC / 子网、安全组、ALB / 监听器 / 目标组、ECR 仓库、RDS、CodeBuild。

## AZ 需要创建的资源

按**不给就卡在哪一步**排序。

### A. 缺失会导致 `terraform init` 失败

| 资源 | 说明 |
| --- | --- |
| S3 state bucket | 带版本控制。`init` 不会建 |
| DynamoDB 锁表 | Terraform 1.6 没有 `use_lockfile`，锁表不是可选项 |
| 跑 Terraform 的 IAM 身份 | 权限见 `iam-permissions.md` 第 4 节。**`s3:ListBucket` 不能漏** |

### B. 缺失会导致 `terraform plan` 失败

| 资源 | 说明 |
| --- | --- |
| KMS CMK（日志加密用） | plan 阶段 `data.aws_kms_key` 要解析它，必须已存在 |

### C. 缺失会导致 `terraform apply` 失败

| 资源 | 数量 | 说明 |
| --- | --- | --- |
| 私有子网 | ≥2，跨可用区 | 代码里有校验，少于两个直接报错 |
| 安全组 | 3（一服务一个） | 流向见下文 |
| ALB 目标组 | 3 | 两个前端 + 后端。健康检查路径配在这里 |

### D. apply 成功但任务无法启动

**这一组最危险：plan 和 apply 都显示成功，服务却一直起不来任务。**

| 资源 | 说明 |
| --- | --- |
| 子网的出站能力 | **NAT 网关**，或 **VPC Endpoint**：`ecr.api`、`ecr.dkr`、`logs`、`secretsmanager`、`kms`（接口型）+ `s3`（网关型，ECR 镜像层存在 S3）。两样都没有报 `CannotPullContainerError` |
| 3 个 ECR 仓库 | 一服务一个。仓库里还得先有镜像，否则熔断回滚 |
| 日志 CMK 的 Key Policy | 要允许 `logs.<region>.amazonaws.com`，否则建日志组就报 AccessDenied |

### E. 任务已启动但用户无法访问

| 资源 | 说明 |
| --- | --- |
| 外部 ALB + 监听器 | 转发到 `frontend-ext` 的目标组 |
| 内部 ALB + 监听器 | 两条路径规则：`/` → `frontend-int`，`/api` → `backend` |
| ACM 证书 | 外部 ALB 要 HTTPS 就得有。中国区证书签发流程另算 |
| 域名解析 | 指向外部 ALB。SSO 回调域名也在这一步 |

### F. 用户可访问但后端连不上数据库

| 资源 | 说明 |
| --- | --- |
| RDS 实例 | AZ 复用内部模板 |
| 密码所在的 Secrets Manager Secret | ARN 要给我们，填进 `services.backend.secrets` |
| **该 Secret 的 CMK Key Policy** | 必须显式允许本项目执行角色 `kms:Decrypt`。AZ 建库、我们读密码，**这个跨团队依赖最容易漏到联调才发现** |

## 安全组需放通的流向

| 源 | 目标 | 端口 | 为什么 |
| --- | --- | --- | --- |
| 外部 ALB | `frontend-ext` | 80 | 外部用户访问 |
| 内部 ALB | `frontend-int` | 80 | 内部用户访问 |
| 内部 ALB | `backend` | 8080 | 按 `/api` 路径转给后端 |
| 两个前端 | 内部 ALB | 80 / 443 | 前端 nginx 反代 `/api` |
| `backend` | RDS | 5432 / 3306 | 访问数据库 |
| `backend` | SMTP 服务器 | 25 / 465 / 587 | 发邮件。**待确认走哪个 SMTP** —— SES 在 cn-north-1 不可用 |
| 三个服务 | 出站 443 | | 拉镜像、写日志、取密钥 |

后端和 `frontend-int` 共用内部 ALB，两个目标组靠监听规则的路径分流。

## AZ 提供的值（填进代码）

| 要什么 | 填到哪 |
| --- | --- |
| KMS CMK 别名或 ARN | `kms_key_id` |
| 私有子网 ID | `subnet_ids` |
| 3 个安全组 ID | `services.*.security_group_ids` |
| 3 个目标组 ARN | `services.*.target_group_arn` |
| 内部 ALB 的 DNS 名 | 两个前端的 `environment.BACKEND_URL` |
| 强制 Tag 的**真实键名** | `variables.tf` 的 `mandatory_tags` type + 三个 tfvars |
| RDS 密码的 Secret ARN | `services.backend.secrets` |

## 项目组填写（代码里）

三个 `env/*.tfvars` 各填一遍。

| 字段 | 填什么 | 不填的后果 |
| --- | --- | --- |
| `project` | 项目标识，小写，≤20 字符 | plan 报错 |
| `mandatory_tags` 五个字段 | AZ 清单上的值 | plan 报错，不许留空 |
| `services.*.repository` ×3 | 三个 ECR 仓库名 | plan 过，任务起不来 |
| `services.*.tag` ×3 | **只有 PRD 要填**，DEV/PPD 是 `latest` | 同上 |

已填好不用动：`region`、`environment`、`cpu`、`memory`、`port`、`desired_count`、`min/max_capacity`、`log_retention_days`。

## 权限需求

见 `docs/iam-permissions.md` —— 四个角色、每条 action 的用途和资源范围。对应实现在 `iam.tf`。

**IAM 角色不用 AZ 新建**：六个角色（每服务一对执行 + 任务）由 `iam.tf` 创建。

## 待确认

1. ECR 仓库的 tag 可变性：`MUTABLE` 还是 `IMMUTABLE`。`IMMUTABLE` 的话 DEV/PPD 用 `latest` 覆盖不成立
2. IAM 命名 / path 约束，是否和 `AZ-CNRDIT-` 前缀冲突
3. 是否强制 Permissions Boundary，ARN 是多少
4. `kms:ViaService` 在 aws-cn 的后缀形式（`iam.tf` 里两种都列了）
5. CodeBuild 在 cn-north-1 能不能用 CodeConnections 连 GitHub
6. 是否有 WAF、ALB 访问日志之类的安全基线要求
