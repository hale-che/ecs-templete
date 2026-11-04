# 镜像要求

开发打包上传 ECR 前对一遍。标「plan 不报」的都是只有任务启动时才暴露的。

## 1. 架构必须 linux/amd64

`main.tf` 固定 `cpu_architecture = "X86_64"`。Apple Silicon 上 `docker build` 默认出 arm64，任务启动报 `exec format error`，**plan 不报**。

    docker buildx build --platform linux/amd64 -t <镜像> .

或者全局设 `DOCKER_DEFAULT_PLATFORM=linux/amd64`。

## 2. 必须监听 0.0.0.0

awsvpc 网络模式下 ALB 访问任务 ENI 的 IP。只绑 `127.0.0.1` 的进程收不到流量，健康检查全挂，**plan 不报**。

## 3. 端口要和 tfvars 对上

| 服务 | 端口 |
| --- | --- |
| `frontend-ext` | 80 |
| `frontend-int` | 80 |
| `backend` | 8080 |

改端口要同时改 tfvars、镜像和 ALB 目标组。

## 4. 前端镜像：后端地址要从环境变量读

前端 JS 里**写相对路径 `/api/xxx`**，不要写后端的绝对地址。nginx 把 `/api` 反代到后端。

| 为什么不能在构建时打进去 | |
| --- | --- |
| 外部用户的浏览器到不了内部 ALB | 后端只挂内部 ALB，公网浏览器直连不了 |
| 打进去就得一个环境一个镜像 | 和 DEV/PPD 共用 `latest` 的 tag 约定冲突 |

后端地址是内部 ALB 的 DNS 名，分环境，从 `environment` 的 `BACKEND_URL` 进来。

nginx 不会自己读环境变量，镜像要在 entrypoint 里做一次替换，例如：

    envsubst '$BACKEND_URL' < /etc/nginx/templates/default.conf.template \
      > /etc/nginx/conf.d/default.conf

变量名要和 `env/*.tfvars` 里 `environment` 的 key 一致，现在写的是 `BACKEND_URL`，按镜像实际用的改。

**必须用 `resolver` + 变量形式的 `proxy_pass`。** nginx 默认只在启动时解析一次上游 DNS
然后永久缓存，而 ALB 的 IP 会变 —— 缓存住就打到死地址，表现是间歇性 502，很难查。

    resolver 169.254.169.253 valid=10s;   # VPC 内置 DNS

    location /api/ {
      set $upstream "${BACKEND_URL}";     # 变量形式才会重新解析
      proxy_pass $upstream;
    }

直接写 `proxy_pass http://alb-dns/` 是**不行**的 —— 那是启动时解析一次的写法。

## 5. 启动命令固化在 Dockerfile

模板没有 `command` / `entrypoint` 字段，不覆盖镜像的 `ENTRYPOINT` / `CMD`。启动逻辑全部写进 Dockerfile。

## 6. 日志只走 stdout / stderr

用 awslogs driver。写进文件的日志进不了 CloudWatch，而且没挂卷，会把 20 GiB 临时盘写满。

## 7. tag 约定

| 环境 | tag |
| --- | --- |
| DEV / PPD | `latest`，每次覆盖 |
| PRD | 确定版本号，填进 `env/prd.tfvars` |

**待确认**：ECR 仓库若开了 `IMMUTABLE` tag，`latest` 第二次 push 直接失败，DEV/PPD 这套就不成立，得改成每次新 tag。问 AZ。

## 8. 推送

仓库地址结尾是 `.amazonaws.com.cn`，不是 `.amazonaws.com`。确切地址用 `terraform output image_urls`。

    aws ecr get-login-password --region cn-north-1 \
      | docker login --username AWS --password-stdin \
        <账号>.dkr.ecr.cn-north-1.amazonaws.com.cn

    docker tag <本地> <账号>.dkr.ecr.cn-north-1.amazonaws.com.cn/<仓库>:<tag>
    docker push <账号>.dkr.ecr.cn-north-1.amazonaws.com.cn/<仓库>:<tag>

## 9. 其他

- **非 root 运行**：Dockerfile 里写 `USER`，安全扫描常卡这条。
- **密码不打进镜像层**：敏感值放 Secrets Manager，在 tfvars 的 `secrets` 里引用。非敏感配置放 `environment`。
- **健康检查端点**：三个服务都要提供一个 HTTP 端点（如 `/health`），由 ALB 目标组检查，路径要和 AZ 配的目标组一致。镜像里**不需要** curl —— 检查是 ALB 发起的，不在容器里跑。
- **基础镜像来源待确认**：cn-north-1 直连 Docker Hub 不稳，内部是否有 artifact 镜像源要问 AZ。
- **镜像不要太大**：Fargate 临时盘 20 GiB（模板没开 `ephemeral_storage`），大镜像还会拖慢扩容时的拉取。
