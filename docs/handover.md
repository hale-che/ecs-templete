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

- **全链路 HTTPS 要求**：ALB 到前端、前端到后端均须使用 TLS；证书由 Secrets Manager 注入，镜像负责落盘并开启 TLS，部署后须实测
- 前端到后端使用 `https://backend-service:8002`；Service Connect 按 TCP 透传应用 TLS，不会自动将 HTTP 升级为 HTTPS
- 前端 Nginx 示例不校验后端证书，支持自签；浏览器访问 ALB 的证书仍需满足客户端的信任要求
- **后端不挂 ALB**：走 ECS Service Connect，主机名 `backend-service`，安全组按前端服务的安全组限制
- 三个服务都跑 Fargate，在私有子网，不分配公网 IP
- 一个环境一个 ECS 集群，三个服务共用

### 出网：Endpoint 和 NAT 都要

| 走 VPC Endpoint | 走 NAT（公网出站） |
| --- | --- |
| ECR API、ECR dkr（接口型） | AstraZeneca IdP / Entra ID |
| S3（网关型，兼做 ECR 镜像层和业务文件） | Microsoft Graph API（发邮件） |
| Secrets Manager、CloudWatch Logs（接口型） | |

当前无需新增 KMS 接口 Endpoint：S3 和 Secrets Manager 都在服务端调用 KMS，
即使使用 customer managed key，也不会因此从应用子网直接调用 KMS。
应用以后若直接调用 KMS API，需另行配置 KMS Endpoint 或相应出网能力。

**不是二选一。** AWS 服务走 Endpoint，Entra ID 和 Graph API 是公网出站，必须有 NAT 或出站代理。

**这份代码建：** ECS 集群、3 个服务、3 个 Task Definition、ECS / CodeBuild 日志组、应用文件桶、TLS Secret 容器、CodeBuild 项目、每服务的执行 / 任务 / 构建角色、每环境两把项目专用 CMK（S3 / TLS Secret）。
**这份代码不建：** VPC / 子网、安全组、ALB / 监听器 / 目标组、ECR 仓库、RDS。

## AZ 需要创建的资源

按**不给就卡在哪一步**排序。

### A. 缺失会导致 `terraform init` 失败

| 资源 | 说明 |
| --- | --- |
| S3 state bucket | 带版本控制。`init` 不会建 |
| DynamoDB 锁表 | Terraform 1.6 没有 `use_lockfile`，锁表不是可选项 |
| 跑 Terraform 的 IAM 身份 | 权限见 `iam-permissions.md` 第 4 节。**`s3:ListBucket` 不能漏** |

### B. 缺失会导致 `terraform apply` 失败

| 资源 | 数量 | 说明 |
| --- | --- | --- |
| 私有子网 | ≥2，跨可用区 | 代码里有校验，少于两个直接报错 |
| 安全组 | 当前共用 1 个 | 已填 `sg-0960c20f67f17cb68`；三个环境的三个服务共用，流向见下文，规则由 AZ 管理 |
| ALB 目标组 | **2** | 只有两个前端。后端走 Service Connect，不挂 ALB |
| KMS 管理员 / 部署角色 | 每环境提供实际 IAM role ARN | 填 `kms_administrator_arns`；本模板创建两把 CMK，部署身份须具备创建 key / alias 的权限，见 `kms.md` |

### C. apply 成功但任务无法启动

**这一组最危险：plan 和 apply 都显示成功，服务却一直起不来任务。**

| 资源 | 说明 |
| --- | --- |
| 子网的出站能力 | **NAT 网关**，或 **VPC Endpoint**：`ecr.api`、`ecr.dkr`、`logs`、`secretsmanager`（接口型）+ `s3`（网关型，ECR 镜像层存在 S3）。两样都没有报 `CannotPullContainerError` |
| 3 个 ECR 仓库 | 一服务一个。仓库里还得先有镜像，否则熔断回滚 |

### D. 任务已启动但用户无法访问

| 资源 | 说明 |
| --- | --- |
| 外部 ALB + HTTPS 监听器 | 转发到 `frontend-ext` 的 HTTPS 8443 目标组，目标组健康检查也用 HTTPS |
| 内部 ALB + HTTPS 监听器 | 转发到 `frontend-int` 的 HTTPS 8443 目标组；`/api` 由前端 Nginx 经 Service Connect 反代到后端，不直接路由到后端 |
| ALB 监听器证书 | 两个 ALB 的 HTTPS 监听器均须配置有效证书。中国区证书接入方式由 AZ 确认 |
| 域名解析 | 指向外部 ALB。SSO 回调域名也在这一步 |

### E. 用户可访问但后端连不上数据库

| 资源 | 说明 |
| --- | --- |
| RDS 实例 | AZ 复用内部模板 |
| 密码所在的 Secrets Manager Secret | ARN 要给我们，填进 `services.backend.secrets` |
| 该 Secret 的加密方式 | 默认 `aws/secretsmanager`。若使用 CMK，将 key ARN 填入 `services.backend.secrets_kms_key_arns`；代码补齐执行角色解密权限，AZ 配置 Key Policy |

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
| 私有子网 ID（已提供） | 三环境 `subnet_ids` 均已填 `subnet-8c4c1efb`、`subnet-0886d048a9ec36d81` |
| 安全组 ID（已提供） | 三环境的 `services.*.security_group_ids` 均已填 `sg-0960c20f67f17cb68` |
| **2 个**目标组 ARN（只有两个前端） | `services.*.target_group_arn` |
| 强制 Tag 的实际值及创建日期 | 七个键名已在 `variables.tf` 定义，值填写在三个 tfvars 的 `mandatory_tags` 中 |
| RDS 密码的 Secret ARN | `services.backend.secrets` |
| KMS 管理员和实际部署角色的 IAM ARN | `kms_administrator_arns`；本模板创建 S3 和 TLS Secret 的 CMK |
| RDS 等外部 Secret 的 CMK ARN（如使用） | 引用该 Secret 的服务的 `secrets_kms_key_arns` |
| **TLS 证书内容** | Terraform 创建 Secret 容器并自动注入其 ARN；证书值由人工录入，见 README |

## 项目组填写（代码里）

三个 `env/*.tfvars` 各填一遍。

| 字段 | 填什么 | 不填的后果 |
| --- | --- | --- |
| `project` | 项目标识，小写，2–17 字符 | plan 报错 |
| `mandatory_tags` 七个字段 | 已填所提供的值；创建日期需填写实际值 | 空值会导致 plan 报错；非空占位值仍需人工替换 |
| `services.*.repository` ×3 | 三个 ECR 仓库名 | plan 过，任务起不来 |
| `services.*.tag` ×3 | **只有 PRD 要填**，DEV/PPD 是 `latest` | 同上 |

已填好不用动：`region`、`environment`、`cpu`、`memory`、`port`、`desired_count`、`log_retention_days`。

## KMS 与存量文件

按最新 PR 评审，S3 与 TLS Secret 的 CMK 均由本模板创建，每环境各两把，由 AZ 接管运维。
轮换自动开启，删除等待期 30 天，并设置 `prevent_destroy`。Aurora / RDS 密钥仍由 AZ 的数据库模板管理。
上线前按 `kms.md` 核对管理员角色、部署权限和真实读写；已有对象及历史版本不会自动换 key，需单独迁移。

三个环境均不启用自动扩缩容；DEV/PPD 每服务 1 个任务，PRD 每服务 2 个任务。
DEV 构建分支为 `dev`，PPD/PRD 为 `main`，均已显式写入环境文件。

## 权限需求

**AZ 人员运维角色：** 项目组只提供 Policy JSON，AZ 负责 Federated Role、SSO、信任策略和关联。
离线生成方法、两份策略的权限范围和交付示例见 [Federated Role 运维权限](federated-ops.md)。

运行、构建和执行 Terraform 的权限见 `docs/iam-permissions.md`，服务角色对应实现在 `iam.tf`。

**应用服务角色由 Terraform 创建**：每服务的执行、任务、CodeBuild 角色在 `iam.tf` 中定义。
人员使用的 Federated Role 仍由 AZ 管理，不包含在这些服务角色中。

## 全链路 HTTPS —— 已定方案

| 项 | 结论 |
| --- | --- |
| 证书怎么进容器 | Secrets Manager 注入成环境变量，entrypoint 落盘。不用 EFS |
| 存储格式 | PEM 用 base64 存，两个 JSON 字段 `cert` / `key` |
| 服务发现 | ECS Service Connect，主机名 `backend-service`，三个环境同名 |
| 是否校验证书 | ALB 不校验前端目标证书；前端 Nginx 使用 `proxy_ssl_verify off`，不校验后端证书 |

三个应用容器的证书支持自签。浏览器到 ALB 的 HTTPS 监听器证书另由 AZ 配置，
仍须满足客户端的信任要求。当前方案要求加密传输，前端到后端不做证书身份校验。

两个格式要求，签发时就要满足：

- **私钥是未加密的 PKCS#8**（`-----BEGIN PRIVATE KEY-----`），否则 Spring Boot 4.1 读不了
- base64 编码时加 `-w0` 不折行

建议 **PRD 单独一张证书**。SAN 内容可以和 DEV/PPD 相同（主机名本来环境无关），但密钥分开 ——
共用一张的话，DEV 的私钥泄露会牵连生产。

主机名用连字符而不是下划线，是为了留后路：`backend-service` 是合法 DNS 主机名，
将来若要开启证书校验，需要为后端申请 SAN 包含 `backend-service` 的证书，
同时在前端配置可信 CA 和 `proxy_ssl_verify on`，无需改变服务名。

## 待确认 —— 其他

1. ECR 仓库的 tag 可变性：`MUTABLE` 还是 `IMMUTABLE`。`IMMUTABLE` 的话 DEV/PPD 用 `latest` 覆盖不成立
2. IAM 命名 / path 约束，是否和 `az-cn-rdit-` 前缀冲突
3. 是否强制 Permissions Boundary，ARN 是多少
4. ALB 访问日志、WAF 规则集等基线要求（WAF 本身 SBP 已明确要有）
5. 后端调 Graph API 发邮件：Entra ID 的 client credentials 存哪个 Secret
