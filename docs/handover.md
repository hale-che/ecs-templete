# 交接清单

依据 SBP v3.4 第 2.4.2 节 Network Configuration Table。

## 架构

    公网用户  →443→  WAF + 外部 ALB  →8443 HTTPS→  frontend-ext (Nginx)
    内网用户  →443→  WAF + 内部 ALB  →8443 HTTPS→  frontend-int (Nginx)
                                                        │
                                                        │ https://backend-service:8002
                                                        │ ECS Service Connect，任务直连
                                                        ▼
                                                  backend (Spring Boot)
                                                        │
                        ┌───────────────────────────────┼────────────────────┐
                   5432 TLS                        443 Endpoint          443 公网
                        ▼                               ▼                    ▼
                      RDS                        S3 / Secrets /        Entra ID /
                   PostgreSQL                    Logs / ECR            Graph API

- **全链路 HTTPS**：ALB 到前端、前端到后端都是 TLS，证书由 Secrets Manager 注入容器
- **三跳都不校验证书**，所以三张证书都可以自签，不必走 CA 流程
- **后端不挂 ALB**：走 ECS Service Connect，主机名 `backend-service`，安全组按前端服务的安全组限制
- 三个服务都跑 Fargate，在私有子网，不分配公网 IP
- 一个环境一个 ECS 集群，三个服务共用

### 出网：Endpoint 和 NAT 都要

| 走 VPC Endpoint | 走 NAT（公网出站） |
| --- | --- |
| ECR API、ECR dkr（接口型） | AstraZeneca IdP / Entra ID |
| S3（网关型，兼做 ECR 镜像层和业务文件） | Microsoft Graph API（发邮件） |
| Secrets Manager、CloudWatch Logs（接口型） | |

**不是二选一。** AWS 服务走 Endpoint，Entra ID 和 Graph API 是公网出站，必须有 NAT 或出站代理。

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
| ALB 目标组 | **2** | 只有两个前端。后端走 Service Connect，不挂 ALB |

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

对应 SBP 2.4.2。

| 源 | 目标 | 端口 | 协议 |
| --- | --- | --- | --- |
| 公网用户 | 外部 ALB（WAF 后） | 443 | HTTPS |
| 内网 / VPN 用户 | 内部 ALB（WAF 后） | 443 | HTTPS |
| 外部 ALB | `frontend-ext` | 8443 | HTTPS |
| 内部 ALB | `frontend-int` | 8443 | HTTPS |
| 两个前端的安全组 | `backend` | 8002 | HTTPS |
| `backend` | RDS PostgreSQL | 5432 | TLS |
| `backend` | S3 网关 Endpoint | 443 | HTTPS |
| 三个服务 | Secrets / Logs / ECR 接口 Endpoint | 443 | HTTPS |
| `backend` | Entra ID、Graph API | 443 出站 | HTTPS |

**「两个前端 → 后端」是任务到任务直连**，按安全组互引，不是 ALB 来源 —— 后端不在任何 ALB 后面。

## AZ 提供的值（填进代码）

| 要什么 | 填到哪 |
| --- | --- |
| KMS CMK 别名或 ARN | `kms_key_id` |
| 私有子网 ID | `subnet_ids` |
| 3 个安全组 ID | `services.*.security_group_ids` |
| **2 个**目标组 ARN（只有两个前端） | `services.*.target_group_arn` |
| 强制 Tag 的**真实键名** | `variables.tf` 的 `mandatory_tags` type + 三个 tfvars |
| RDS 密码的 Secret ARN | `services.backend.secrets` |
| **TLS 证书的 Secret ARN** | 三个服务的 `services.*.secrets` |
| **加密上面两个 Secret 的 CMK ARN** | `secret_kms_key_arns`（和日志同一把或用托管密钥则不填） |

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

## 全链路 HTTPS —— 已定方案

| 项 | 结论 |
| --- | --- |
| 证书怎么进容器 | Secrets Manager 注入成环境变量，entrypoint 落盘。不用 EFS |
| 存储格式 | PEM 用 base64 存，两个 JSON 字段 `cert` / `key` |
| 服务发现 | ECS Service Connect，主机名 `backend-service`，三个环境同名 |
| 是否校验证书 | **三跳都不校验** |

**不校验的直接后果：三张证书都可以自签，不需要走 CA 流程。**
ALB 到目标本来就不校验（AWS 既定行为），前端到后端由我们显式关掉。

两个格式要求，签发时就要满足：

- **私钥是未加密的 PKCS#8**（`-----BEGIN PRIVATE KEY-----`），否则 Spring Boot 4.1 读不了
- base64 编码时加 `-w0` 不折行

建议 **PRD 单独一张证书**。SAN 内容可以和 DEV/PPD 相同（主机名本来环境无关），但密钥分开 ——
共用一张的话，DEV 的私钥泄露会牵连生产。

主机名用连字符而不是下划线，是为了留后路：`backend-service` 是合法 DNS 主机名，
将来若要开启证书校验，直接申请一张 SAN 为 `backend-service` 的证书即可，不用改名重来。

## 待确认 —— 其他

1. ECR 仓库的 tag 可变性：`MUTABLE` 还是 `IMMUTABLE`。`IMMUTABLE` 的话 DEV/PPD 用 `latest` 覆盖不成立
2. IAM 命名 / path 约束，是否和 `AZ-CNRDIT-` 前缀冲突
3. 是否强制 Permissions Boundary，ARN 是多少
4. `kms:ViaService` 在 aws-cn 的后缀形式（`iam.tf` 里两种都列了）
5. ALB 访问日志、WAF 规则集等基线要求（WAF 本身 SBP 已明确要有）
6. 后端调 Graph API 发邮件：Entra ID 的 client credentials 存哪个 Secret
