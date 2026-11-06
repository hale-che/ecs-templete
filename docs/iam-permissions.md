# IAM 权限需求

项目组提出需求，AZ 按自己的模板落地。每条都给了用途，便于映射和逐条挑战。

**区域 `cn-north-1`，aws-cn 分区。** 所有 ARN 是 `arn:aws-cn:...`，AWS 官方文档里的策略示例照抄一个都对不上。
服务主体仍是 `ecs-tasks.amazonaws.com`（不带 `.cn`），ECR 镜像地址结尾是 `.amazonaws.com.cn`。

标 **`*` 必须** 的是 AWS API 不支持资源限定，换任何模板都绕不开，安全扫描报了走风险申请。

## 需求摘要

| 角色 | 个数 | 用途 | 现状 |
| --- | --- | --- | --- |
| ECS 执行角色 | 3（每服务一个） | ECS 代理拉镜像、写日志、取密钥 | 需求已明确，见第 1 节 |
| ECS 任务角色 | 3（每服务一个） | 业务代码调 AWS API | 当前为空，不阻塞首次部署。后续补 S3、邮件，见第 2 节 |
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

信任策略：`ecs-tasks.amazonaws.com`，带 `aws:SourceAccount` 和 `aws:SourceArn`（防混淆代理）。

## 2. ECS 任务角色 —— 当前为空，后续补

业务代码调 AWS API 用。三个角色现在都是空的，**首次部署不需要填**。
后端**后续**会用到 S3 和发邮件，到时再按下面的形状补。

两个前端（静态资源 + 反代）预计为空，请确认。

**空角色是合法状态**，角色建出来不挂策略，apply 正常过，不阻塞第一次创建。
漏了权限的表现也很明确：应用日志里出现 `AccessDenied` 并指明缺哪个 action。

### 后续会用到的

**S3** —— 需要 bucket 名和前缀。对象操作和 `ListBucket` 是两条，资源粒度不同：

    task_role_policy_statements = [
      {
        sid       = "ReadWriteOwnPrefix"
        actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        resources = ["arn:aws-cn:s3:::<bucket>/<前缀>/*"]
      },
      {
        sid       = "ListOwnPrefix"
        actions   = ["s3:ListBucket"]
        resources = ["arn:aws-cn:s3:::<bucket>"]
        conditions = [{
          test     = "StringLike"
          variable = "s3:prefix"
          values   = ["<前缀>/*"]
        }]
      },
    ]

`ListBucket` 的资源只能是 bucket 本身（不带 `/*`），所以靠 `s3:prefix` 条件收口到项目自己的前缀。
如果那个 bucket 用自管 CMK 加密，还要对那把 key 加 `kms:Decrypt` 和 `kms:GenerateDataKey`。

**发邮件 —— 大概率不需要 IAM 权限。**

**SES 在 cn-north-1 不可用。** 所以邮件要么走企业邮箱 / 内部 SMTP 中继，要么走第三方发信服务。
那些都是普通 TCP 连接，不是 AWS API，**任务角色不需要任何权限**。需要的是另外两样：

- 安全组放通出站到 SMTP 端口（25 / 465 / 587）
- SMTP 凭证放 Secrets Manager，填进 `services.backend.secrets`，由**执行角色**注入成环境变量

请确认邮件走哪条路 —— 如果真的打算跨区调用 global 的 SES，那是跨分区调用，需要另一套凭证和网络出口，要单独评估。

### 还需要确认的

- [ ] S3 的 bucket 名和前缀
- [ ] bucket 是否 CMK 加密，key ARN
- [ ] 邮件走 SMTP 还是别的
- [ ] 发送 SQS / SNS？哪个队列或主题
- [ ] 读写 DynamoDB？哪张表
- [ ] 调 Bedrock 或其他 AI 服务？
- [ ] 运行时动态读 Secrets Manager（而不是启动时注入）？
- [ ] RDS 走 IAM 认证（`rds-db:connect`）还是密码？
- [ ] 需要 `sts:AssumeRole` 跨账号或跨服务？

每条要给到**资源 ARN 粒度**。模板层面禁掉了 `actions = ["*"]` 和 `resources = ["*"]`，填通配 plan 阶段直接报错。

## 3. CodeBuild 服务角色

不在本模板里。**沿用贵方现成的 CodeBuild 模板**，下面只列和本项目相关的资源范围，
用来核对模板里的权限是否覆盖得到。源码接入方式（CodeConnections 或 token）按模板既有做法。

**基础部分，两套发布方案都要：**

| Action | Resource | 为什么需要 |
| --- | --- | --- |
| `logs:CreateLogGroup` `logs:CreateLogStream` `logs:PutLogEvents` | `/aws/codebuild/<project>:*` | CodeBuild 自己的构建日志 |
| `ecr:GetAuthorizationToken` | **`*` 必须** | 取 ECR 登录令牌 |
| `ecr:BatchCheckLayerAvailability` `ecr:InitiateLayerUpload` `ecr:UploadLayerPart` `ecr:CompleteLayerUpload` `ecr:PutImage` `ecr:BatchGetImage` | 三个项目仓库 | push 镜像 |
| 源码接入（`codeconnections:UseConnection` 或读 token 的 `secretsmanager:GetSecretValue`） | Connection ARN 或 token Secret | 拉 GitHub 源码，按贵方模板既有做法 |
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
| `logs:CreateLogGroup` `logs:DeleteLogGroup` `logs:DescribeLogGroups` `logs:PutRetentionPolicy` `logs:TagResource` `logs:ListTagsForResource` | `log-group:/ecs/*` | 建日志组 |
| `sts:GetCallerIdentity` | `*` | 取账号 ID 拼 ARN，无资源概念 |
| `s3:ListBucket` | state bucket | **不能漏。** 缺了 S3 对不存在的 key 返回 403 而不是 404，`terraform init` 报的错指向完全不相干的地方 |
| `s3:GetObject` `s3:PutObject` `s3:DeleteObject` | state key | 读写 state |
| `dynamodb:GetItem` `dynamodb:PutItem` `dynamodb:DeleteItem` | 锁表 ARN | state 锁。Terraform 1.6 没有 `use_lockfile`，锁表不是可选项 |

## 5. 需要 AZ 配置的项

这几条不是建角色能解决的：

1. **IAM 命名 / path 约束** —— 是否要求建在某个 path 下，和 `AZ-CNRDIT-` 前缀是否冲突。
2. **Permissions Boundary** —— 是否强制，强制的话 ARN 是多少。
3. **Secrets 一律用 AWS 托管密钥**（`aws/secretsmanager`）。换成自管 CMK 的话，要在 `iam.tf` 给执行角色补 `kms:Decrypt`，并在 Key Policy 里允许它。
4. **ECR 仓库的 tag 可变性** —— `MUTABLE` 还是 `IMMUTABLE`。决定第 3 节发布方案能不能选 A。

对应的 Terraform 实现在 `iam.tf`，可以直接 diff。
