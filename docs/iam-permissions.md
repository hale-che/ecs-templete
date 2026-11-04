# IAM 权限需求

项目组提出需求，AZ 按自己的模板落地。每条都给了用途，便于映射和逐条挑战。

**区域 `cn-north-1`，aws-cn 分区。** 所有 ARN 是 `arn:aws-cn:...`，AWS 官方文档里的策略示例照抄一个都对不上。
服务主体仍是 `ecs-tasks.amazonaws.com`（不带 `.cn`），ECR 镜像地址结尾是 `.amazonaws.com.cn`。

标 **`*` 必须** 的是 AWS API 不支持资源限定，换任何模板都绕不开，安全扫描报了走风险申请。

## 需求摘要

| 角色 | 个数 | 用途 | 现状 |
| --- | --- | --- | --- |
| ECS 执行角色 | 3（每服务一个） | ECS 代理拉镜像、写日志、取密钥 | 需求已明确，见第 1 节 |
| ECS 任务角色 | 3（每服务一个） | 业务代码调 AWS API | 待应用侧确认，**很可能确认为不需要**，见第 2 节 |
| CodeBuild 服务角色 | 1 | 构建、推镜像、触发部署 | 需求已明确，但依赖发布方案，见第 3 节 |
| 跑 Terraform 的身份 | 1 | 创建上面这些资源 | 需求已明确，见第 4 节 |

执行角色和任务角色**按服务拆开，不共用** —— 共用等于把三个服务的权限并集发给每一个。

## 1. ECS 执行角色

ECS 代理用，不是业务代码用。资源范围按**该服务自己的**仓库和密钥收口。

| Action | Resource | 为什么需要 |
| --- | --- | --- |
| `ecr:GetAuthorizationToken` | **`*` 必须** | 取 ECR 登录令牌，账号级操作 |
| `ecr:BatchCheckLayerAvailability` `ecr:BatchGetImage` `ecr:GetDownloadUrlForLayer` | 该服务自己那一个仓库 | 拉镜像。不用 `repository/*` |
| `logs:CreateLogStream` `logs:PutLogEvents` | `log-group:/ecs/<服务资源名>:log-stream:*` | awslogs driver 把容器 stdout 写进日志组。日志组由 Terraform 建，**不需要 `CreateLogGroup`** |
| `secretsmanager:GetSecretValue` | 该服务实际引用的 Secret ARN | 启动时把 RDS 密码等注入容器环境变量。没有 Secret 的服务整条不下发 |
| `kms:Decrypt` | 日志和 Secret 用的 CMK | 日志组和 Secret 都是 CMK 加密的。条件 `kms:ViaService` 限定 secretsmanager / logs |

信任策略：`ecs-tasks.amazonaws.com`，带 `aws:SourceAccount` 和 `aws:SourceArn`（防混淆代理）。

## 2. ECS 任务角色 —— 待应用侧确认

业务代码调 AWS API 用。三个角色现在都是空的。

**空角色是合法状态**，角色建出来不挂策略，apply 正常过，不阻塞任何节点。
漏了权限的表现也很明确：应用日志里出现 `AccessDenied` 并指明缺哪个 action，照着补。

**"不需要" 是个正常结论，不是缺口。** 两个前端（静态资源 + 反代）几乎确定为空；
后端如果只连 RDS 和 Redis 也是空的 —— 从 Secrets Manager 取密码注入环境变量是**执行角色**干的，不走任务角色。

真需要填的只有代码里直接调 AWS SDK 的场景。确认方式：在后端代码里 grep
`boto3.client(` / `software.amazon.awssdk` / `@aws-sdk/client-` / `aws-sdk-go`，一个都没有就是不需要。

有的话请应用侧回答：

- [ ] 读写 S3？哪个 bucket、哪些前缀
- [ ] 发送 SQS / SNS？哪个队列或主题
- [ ] 读写 DynamoDB？哪张表
- [ ] 调 Bedrock 或其他 AI 服务？
- [ ] 运行时动态读 Secrets Manager（而不是启动时注入）？
- [ ] RDS 走 IAM 认证（`rds-db:connect`）还是密码？
- [ ] 需要 `sts:AssumeRole` 跨账号或跨服务？

每条要给到**资源 ARN 粒度**，AZ 规范要求限定到项目自身资源。模板层面禁掉了 `actions = ["*"]` 和 `resources = ["*"]`，填通配 plan 阶段直接报错。

## 3. CodeBuild 服务角色

不在本模板里，项目组另外的代码目录。

**基础部分，两套发布方案都要：**

| Action | Resource | 为什么需要 |
| --- | --- | --- |
| `logs:CreateLogGroup` `logs:CreateLogStream` `logs:PutLogEvents` | `/aws/codebuild/<project>:*` | CodeBuild 自己的构建日志 |
| `ecr:GetAuthorizationToken` | **`*` 必须** | 取 ECR 登录令牌 |
| `ecr:BatchCheckLayerAvailability` `ecr:InitiateLayerUpload` `ecr:UploadLayerPart` `ecr:CompleteLayerUpload` `ecr:PutImage` `ecr:BatchGetImage` | 三个项目仓库 | push 镜像 |
| `codeconnections:UseConnection` | Connection ARN | 拉 GitHub 源码。**cn-north-1 是否支持 CodeConnections 待确认**；不支持就改用 token，换成对 token Secret 的 `secretsmanager:GetSecretValue` |
| `s3:GetObject` `s3:GetObjectVersion` `s3:PutObject` `s3:GetBucketAcl` `s3:GetBucketLocation` | artifact bucket | 没配 S3 artifact 可整段去掉 |

**跑在 VPC 里才需要**（要访问私有子网里的资源时）：

| Action | Resource | 为什么需要 |
| --- | --- | --- |
| `ec2:DescribeDhcpOptions` `ec2:DescribeNetworkInterfaces` `ec2:DescribeSubnets` `ec2:DescribeSecurityGroups` `ec2:DescribeVpcs` | **`*` 必须** | Describe 类不支持资源限定 |
| `ec2:CreateNetworkInterface` `ec2:DeleteNetworkInterface` | **`*` 必须** | CodeBuild 为构建容器建 ENI |
| `ec2:CreateNetworkInterfacePermission` | 子网 ARN | 条件 `ec2:AuthorizedService = codebuild.amazonaws.com` |

**发布部分，二选一（方案未定）：**

| 方案 | Action | Resource |
| --- | --- | --- |
| A 固定 tag + 强制重部署 | `ecs:UpdateService` `ecs:DescribeServices` | 服务 ARN |
| B 注册新 revision | A 的两条，加 `ecs:DescribeTaskDefinition` `ecs:RegisterTaskDefinition` | **`*` 必须** |
| B 注册新 revision | 再加 `iam:PassRole` | 六个 ECS 角色，条件 `iam:PassedToService = ecs-tasks.amazonaws.com` |

**方案 A 权限明显更小，而且不需要 `PassRole`。** 前提是 ECR 仓库允许 `MUTABLE` tag。

## 4. 执行 Terraform 的身份

可以就是 CodeBuild 角色，也可以单独一个。**这个要先有，才能跑第一次 apply。**

| Action | Resource | 为什么需要 |
| --- | --- | --- |
| `iam:CreateRole` `iam:DeleteRole` `iam:GetRole` `iam:UpdateRole` `iam:UpdateAssumeRolePolicy` `iam:TagRole` `iam:UntagRole` `iam:ListInstanceProfilesForRole` | `role/AZ-CNRDIT-*` | 建那六个角色。按名称前缀限定 |
| `iam:PutRolePolicy` `iam:DeleteRolePolicy` `iam:GetRolePolicy` `iam:ListRolePolicies` `iam:ListAttachedRolePolicies` | `role/AZ-CNRDIT-*` | 角色的内联策略 |
| `iam:PassRole` | `role/AZ-CNRDIT-*-ecs-*-role` | 注册 Task Definition 时把角色传给 ECS |
| `ecs:RegisterTaskDefinition` `ecs:DeregisterTaskDefinition` `ecs:DescribeTaskDefinition` `ecs:ListTaskDefinitions` `ecs:TagResource` | **`*` 必须** | Task Definition 的 API 不支持资源限定 |
| `ecs:CreateCluster` `ecs:DeleteCluster` `ecs:DescribeClusters` `ecs:UpdateClusterSettings` | 集群 ARN | 建集群、开 Container Insights |
| `ecs:CreateService` `ecs:DeleteService` `ecs:UpdateService` `ecs:DescribeServices` | 服务 ARN | 建三个服务 |
| `application-autoscaling:RegisterScalableTarget` `DeregisterScalableTarget` `DescribeScalableTargets` `PutScalingPolicy` `DeleteScalingPolicy` `DescribeScalingPolicies` | **`*` 必须** | PRD 的 2-4 扩缩容 |
| `iam:CreateServiceLinkedRole` | 条件 `iam:AWSServiceName` 限定 `ecs.amazonaws.com` 和 `ecs.application-autoscaling.amazonaws.com` | ECS 和自动扩缩容的服务关联角色，账号里已有就不会调 |
| `elasticloadbalancing:DescribeTargetGroups` `DescribeLoadBalancers` | 目标组 / ALB ARN | 服务关联目标组时可能需要，不确定则先给 |
| `logs:CreateLogGroup` `logs:DeleteLogGroup` `logs:DescribeLogGroups` `logs:PutRetentionPolicy` `logs:AssociateKmsKey` `logs:TagResource` `logs:ListTagsForResource` | `log-group:/ecs/*` | 建带 CMK 加密的日志组 |
| `kms:DescribeKey` | CMK ARN | 把别名解析成 ARN |
| `sts:GetCallerIdentity` | `*` | 取账号 ID 拼 ARN，无资源概念 |
| `s3:ListBucket` | state bucket | **不能漏。** 缺了 S3 对不存在的 key 返回 403 而不是 404，`terraform init` 报的错指向完全不相干的地方 |
| `s3:GetObject` `s3:PutObject` `s3:DeleteObject` | state key | 读写 state |
| `dynamodb:GetItem` `dynamodb:PutItem` `dynamodb:DeleteItem` | 锁表 ARN | state 锁。Terraform 1.6 没有 `use_lockfile`，锁表不是可选项 |

## 5. 需要 AZ 配置的项

这几条不是建角色能解决的：

1. **IAM 命名 / path 约束** —— 是否要求建在某个 path 下，和 `AZ-CNRDIT-` 前缀是否冲突。
2. **Permissions Boundary** —— 是否强制，强制的话 ARN 是多少。
3. **日志 CMK 的 key policy** —— 要允许 `logs.<region>.amazonaws.com`，否则建加密日志组直接 AccessDenied。
4. **RDS 密码所在 Secret 的 CMK key policy** —— 要显式允许本项目的执行角色 `kms:Decrypt`。AZ 建 RDS、我们读密码，这个跨团队依赖最容易漏到联调才发现。
5. **ECR 仓库的 tag 可变性** —— `MUTABLE` 还是 `IMMUTABLE`。决定第 3 节发布方案能不能选 A。

对应的 Terraform 实现在 `iam.tf`，可以直接 diff。
