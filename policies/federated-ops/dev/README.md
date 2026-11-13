# AIEC DEV Federated Role Policy

本目录是扩充后的 DEV 运维交付策略，JSON 以 `.txt` 保存，文件名及排版参考 `../examples/`。
账号 `332091793104`，分区 `aws-cn`，区域 `cn-north-1`，项目 `aiec`，环境 `dev`。
资源命名依据 `env/dev.tfvars`、`locals.tf`、`s3.tf`、`kms.tf`、`iam.tf` 和 `cluster.tf`。

| 文件 | 用途 |
| --- | --- |
| `AWS_CN_RDIT_AIEC_DEVOPS_DEV-policy01.txt` | 只读排查：ECS、日志、镜像、构建结果、指标；网络、RDS、ALB、Cloud Map、KMS、Secret 和 IAM 配置查询 |
| `AWS_CN_RDIT_AIEC_DEVOPS_DEV-policy02.txt` | DEV 应用资源管理：ECS 发布/回滚/任务操作、ECR 仓库及镜像、CodeBuild 项目/构建、S3 桶及对象、日志、Secret、监控，以及 ECS / CodeBuild PassRole |
| `AWS_CN_RDIT_AIEC_DEVOPS_DEV-policy03.txt` | DEV 基础权限：项目服务角色及内联策略、必要的服务关联角色、带 DEV 标签的 KMS key、DEV alias、Cloud Map HTTP namespace 及带 DEV 标签的服务发现资源 |

只读人员关联 policy01；完整 DEV 运维关联三份。扩充后按职责拆成三份，避免两份合并时接近 IAM 单个托管策略的 6144 字符上限。
`Version` 固定为 `2012-10-17`，它是 IAM 策略语言版本，不是文件修改日期。

## 主要资源范围

- ECS 集群 `az-cn-rdit-aiec-ecs-fargate-dev`，其中的服务、任务及任务集，以及 `az-cn-rdit-aiec-*-dev` Task Definition family。
  可直接注册新的 revision，切换镜像、调整服务、运行/停止任务及请求 ECS Exec；有 `ecs:cluster` 请求上下文时必须是本 DEV 集群。
- 三个 ECR 仓库按实际仓库 ARN 列出；支持创建仓库、推拉和删除镜像、调整仓库配置。
- CodeBuild 项目和构建限定 `az-cn-rdit-aiec-*-build-dev`；允许修改项目、触发/停止构建及使用构建覆盖参数。
- 应用文件桶 `az-cn-rdit-aiec-files-dev` 和代码桶 `az-cn-rdit-aiec-s3-codebase-dev`，同时覆盖桶 ARN 和对象 ARN。
- ECS / CodeBuild 日志组按 DEV 名称限定，允许写入、查询、调整保留期和删除。
- Secret 名称限定 `az-cn-rdit-aiec-*-dev`（ARN 另有 AWS 自动追加的六位后缀）；包含读取/修改 Secret 值、版本和资源策略等管理操作。
- 监控告警和 dashboard 限定 `az-cn-rdit-aiec-*-dev` 名称。
- IAM 角色限定 `az-cn-rdit-aiec-*-dev`，允许角色生命周期、信任策略和内联权限策略管理；PassRole 分别限定给 ECS Tasks 和 CodeBuild。
- KMS 创建要求请求标签 `Project=aiec`、`Environment=dev`；已有 key 管理及使用要求相同资源标签，alias 限定 `az-cn-rdit-aiec-*-dev`。
  创建时打标签允许标签尚不存在的 key，但不能把已有其他 Project / Environment 标签的 key 改标为 DEV。
- HTTP namespace 创建要求上述请求标签；已有 namespace / service 的管理要求相同资源标签。

区域级查询可查看该账号 `cn-north-1` 的部分其他项目元数据，IAM 查询覆盖账号级角色和策略配置。
ECR 登录、带标签的 KMS key 创建、HTTP namespace 创建等不能预先限定生成后的资源 ID，分别以区域或请求标签约束。
没有授予账号级 `Action: "*"`，也没有复制样例中的 EC2 主机/共享安全组修改、其他项目共享 RDS、SQS、SNS、Lambda 等操作。

## ECR 仓库名称

| 服务 | 仓库名 |
| --- | --- |
| `backend` | `az-cn-rdit-aiec-backend-dev` |
| `frontend-ext` | `az-cn-rdit-aiec-frontend-ext-dev` |
| `frontend-int` | `az-cn-rdit-aiec-frontend-int-dev` |

policy01 和 policy02 已按 `env/dev.tfvars` 同步填写上述仓库名；后续改名时须同步更新两份策略。仓库名不带 registry 域名、tag 或 ARN。
若后续覆盖了 `file_bucket_name` / `codebase_bucket_name`，须同步改 policy02 中的桶和对象 ARN。
外部 RDS Secret、其他业务 Secret 或外部 CMK 若不符合当前命名/标签范围，需按实际 ARN 另补，不套用其他项目的 ARN。

## 落地前提与未覆盖项

- 本目录是身份权限策略，不创建 Federated Role 或信任策略；由 AZ 关联。
- KMS 仍需对应 Key Policy 授权。当前模板仅向指定管理员及任务/执行角色开放对应操作，添加这三份身份策略不会自动获得 key 使用权。
  仅把人员角色加入 `kms_administrator_arns` 也不等同于开放文件桶 CMK 的数据解密；AZ 需分别核对管理和数据使用授权。
- ECS Exec 仍需服务/任务启用 Exec、任务角色具有 SSM Messages 通道权限并满足网络和容器条件；本次不改变运行中的服务配置。
- Cloud Map 的按标签管理依赖资源实际具备 `Project=aiec`、`Environment=dev`；ECS 自动创建的服务应先核对标签。未附带这些标签的服务不能按本策略直接修改。
- `ecs:DeregisterTaskDefinition` 不支持资源级限定，未额外授予整个区域的注销权限；需要清理旧 revision 时由 AZ 使用适当角色处理。
- 共享子网/安全组/ALB/WAF/RDS 只提供查询。Terraform backend 的 state 桶及锁表未配置在项目文件中，须 AZ 按实际 ARN 另授予访问权。
- 角色和内联策略管理、构建脚本修改、Secret 和数据访问均属于较高权限；这些 Allow 策略不构成权限边界，AZ 的 SCP、Boundary、资源策略及角色其他授权共同决定最终权限。

## 维护与验证

DEV 扩充策略以本目录文件为准。上级 Terraform 纯生成模块、`export.py` 和主项目的两个 Federated outputs
继续提供原有的标准只读 / 服务更新策略，不会生成这份扩充交付；不要用它们覆盖本目录。
PPD / PRD 的标准生成逻辑未调整。

在项目根目录执行：

```bash
python3 tests/check-dev-federated-policies.py
```

本地检查验证 JSON、大小及典型权限边界，不等于 AWS IAM Policy Simulator 或真实账号验收。
完整交付说明见[运维权限交付](../../../docs/federated-ops.md)。
