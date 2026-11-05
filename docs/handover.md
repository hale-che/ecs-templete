# 交接清单

依据 SBP v3.4 第 2.4.2 节 Network Configuration Table。

## 架构

    公网用户  →443→  WAF + 外部 ALB  →8443 HTTPS→  frontend-ext (Nginx)
    内网用户  →443→  WAF + 内部 ALB  →8443 HTTPS→  frontend-int (Nginx)
                                                        │
                                            8002 HTTPS  │ 任务直连，不经 ALB
                                                        ▼
                                                  backend (Spring Boot)
                                                        │
                        ┌───────────────────────────────┼────────────────────┐
                   5432 TLS                        443 Endpoint          443 公网
                        ▼                               ▼                    ▼
                      RDS                        S3 / Secrets /        Entra ID /
                   PostgreSQL                    Logs / ECR            Graph API

- **全链路 HTTPS**：ALB 到前端、前端到后端都是 TLS，证书挂载进容器
- **后端不挂 ALB**：前端到后端是任务直连，安全组按前端服务的安全组限制
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

## 待确认 —— 全链路 HTTPS 相关（阻塞写代码）

SBP 定了「要 HTTPS、证书挂容器」，但没说怎么落地。第 2 条已确认，其余三条定不下来代码写不完。

**1. 证书从哪来？**

| 方案 | 影响 |
| --- | --- |
| ACM Private CA 签发 | 后端要权限从 ACM 导出证书，或由流水线导出后存 Secrets Manager |
| 内部 CA 签发，人工存进 Secrets Manager | 最简单。证书到期要人工轮换 |
| 自签 | 前端得跳过证书校验，等于只加密不验身份 |

**2. 证书怎么进容器？已定：Secrets Manager 注入，不用 EFS。**

PEM 存成 secret 的两个 JSON 字段，ECS 代理注入成环境变量 `TLS_CERT` / `TLS_KEY`，
entrypoint 写成文件。代码侧已就绪，`services.*.secrets` 填 ARN 即可，执行角色权限自动跟着生成。

还需要 AZ 给两样：**证书 Secret 的 ARN**，以及**加密它的 CMK ARN**（填 `secret_kms_key_arns`；
如果和日志用的是同一把，或者用 AWS 托管密钥，就不用填）。

**PEM 内容用 base64 存**（已确认），两个 JSON 字段 `cert` / `key` 各一份，命令见 `image-requirements.md` 第 5 节。

还剩一个细节：后端 Spring Boot 的版本 —— 2.7 以下只认 PKCS12，entrypoint 要多一步 `openssl pkcs12 -export`。

**3. 前端用什么主机名访问后端？** 这决定证书的 SAN，也决定服务发现方式。

后端不挂 ALB，所以要有服务发现。可选 ECS Service Connect（不需要 AZ 建额外资源）或 Cloud Map。
无论哪个，**后端证书的 SAN 必须包含前端实际使用的那个主机名**，否则 nginx 校验失败。

**4. 前端是否校验后端证书？** 校验的话，前端容器还要装 CA 根证书，又是一份要挂载的文件。

## 待确认 —— 其他

1. ECR 仓库的 tag 可变性：`MUTABLE` 还是 `IMMUTABLE`。`IMMUTABLE` 的话 DEV/PPD 用 `latest` 覆盖不成立
2. IAM 命名 / path 约束，是否和 `AZ-CNRDIT-` 前缀冲突
3. 是否强制 Permissions Boundary，ARN 是多少
4. `kms:ViaService` 在 aws-cn 的后缀形式（`iam.tf` 里两种都列了）
5. CodeBuild 在 cn-north-1 能不能用 CodeConnections 连 GitHub
6. ALB 访问日志、WAF 规则集等基线要求（WAF 本身 SBP 已明确要有）
7. 后端调 Graph API 发邮件：Entra ID 的 client credentials 存哪个 Secret
