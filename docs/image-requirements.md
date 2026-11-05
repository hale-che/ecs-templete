# 镜像要求

开发打包上传 ECR 前对一遍。标「plan 不报」的都是只有任务启动时才暴露的。

## 1. 架构必须 linux/amd64

`main.tf` 固定 `cpu_architecture = "X86_64"`。Apple Silicon 上 `docker build` 默认出 arm64，任务启动报 `exec format error`，**plan 不报**。

    docker buildx build --platform linux/amd64 -t <镜像> .

或者全局设 `DOCKER_DEFAULT_PLATFORM=linux/amd64`。

## 2. 必须监听 0.0.0.0

awsvpc 网络模式下 ALB 访问任务 ENI 的 IP。只绑 `127.0.0.1` 的进程收不到流量，健康检查全挂，**plan 不报**。

## 3. 端口需与 tfvars 一致

| 服务 | 端口 | 协议 |
| --- | --- | --- |
| `frontend-ext` | 8443 | HTTPS |
| `frontend-int` | 8443 | HTTPS |
| `backend` | 8002 | HTTPS |

改端口要同时改 tfvars、镜像和 ALB 目标组。

## 4. 前端镜像：后端地址要从环境变量读

前端 JS 里**写相对路径 `/api/xxx`**，不要写后端的绝对地址。nginx 把 `/api` 反代到后端。

| 为什么不能在构建时打进去 | |
| --- | --- |
| 浏览器到不了后端 | 后端不挂任何 ALB，只在私有子网里被前端直连 |
| 打进去就得一个环境一个镜像 | 和 DEV/PPD 共用 `latest` 的 tag 约定冲突 |

后端地址是内部 ALB 的 DNS 名，分环境，从 `environment` 的 `BACKEND_URL` 进来。

nginx 不会自己读环境变量，镜像要在 entrypoint 里做一次替换，例如：

    envsubst '$BACKEND_URL' < /etc/nginx/templates/default.conf.template \
      > /etc/nginx/conf.d/default.conf

变量名要和 `env/*.tfvars` 里 `environment` 的 key 一致，现在写的是 `BACKEND_URL`，按镜像实际用的改。

**用 `resolver` + 变量形式的 `proxy_pass`。** nginx 默认只在启动时解析一次上游 DNS 然后永久缓存，
而后端任务的 IP 会随发布和扩缩容变 —— 缓存住就打到死地址，表现是间歇性 502，很难查。

    resolver 169.254.169.253 valid=10s;   # VPC 内置 DNS

    location /api/ {
      set $upstream "${BACKEND_URL}";     # 变量形式才会重新解析
      proxy_pass $upstream;
      proxy_ssl_server_name on;           # 后端是 HTTPS，SNI 要带上
    }

直接写 `proxy_pass https://backend:8002/` 是启动时解析一次的写法，**不要用**。

（如果最后定了用 ECS Service Connect，Envoy 会接管端点变化，这段可以简化 —— 服务发现方式还没定。）

## 5. TLS 证书从环境变量写成文件

全链路 HTTPS：ALB 到前端是 8443，前端到后端是 8002，**三个容器都要自己终止 TLS**。

证书走 Secrets Manager，**内容用 base64 存**（已和 AZ 确认），注入成环境变量后由 entrypoint 落盘。

Secret 是一个 JSON，两个字段都是 base64：

    aws secretsmanager create-secret --name <secret 名> --secret-string "$(jq -n \
      --arg cert "$(base64 -w0 tls.crt)" \
      --arg key  "$(base64 -w0 tls.key)" \
      '{cert:$cert, key:$key}')"

`-w0` 不能漏，否则 base64 自己会折行，塞进 JSON 还要再处理一轮转义。

entrypoint 解码写文件：

    #!/bin/sh
    set -e
    umask 077
    mkdir -p /etc/ssl/app
    printf '%s' "$TLS_CERT" | base64 -d > /etc/ssl/app/tls.crt
    printf '%s' "$TLS_KEY"  | base64 -d > /etc/ssl/app/tls.key
    chmod 600 /etc/ssl/app/tls.key
    exec "$@"

变量名要和 `env/*.tfvars` 里 `secrets` 的 key 一致，现在写的是 `TLS_CERT` / `TLS_KEY`。

**为什么用 base64**：PEM 原文有换行，存进 JSON 字段要转义成 `\n`，手工创建 secret 时极易弄错，
而且错了的表现是「证书格式非法」，不会指向转义。base64 是单行 ASCII，对转义完全免疫。

写文件需要可写的根文件系统 —— `readonly_root_filesystem` 已经是 `false`。

### 应用怎么读这两个文件

nginx（两个前端）：

    listen 8443 ssl;
    ssl_certificate     /etc/ssl/app/tls.crt;
    ssl_certificate_key /etc/ssl/app/tls.key;

Spring Boot 4.1（后端）—— 直接读 PEM，**不用转 PKCS12**：

    server:
      port: 8002
      ssl:
        bundle: server
    spring:
      ssl:
        bundle:
          pem:
            server:
              keystore:
                certificate: file:/etc/ssl/app/tls.crt
                private-key: file:/etc/ssl/app/tls.key

**私钥必须是未加密的 PKCS#8**，也就是 `-----BEGIN PRIVATE KEY-----` 开头。
CA 给的是 PKCS#1（`-----BEGIN RSA PRIVATE KEY-----`）或者带密码的话，先转一次再 base64：

    openssl pkcs8 -topk8 -nocrypt -in old.key -out tls.key

这条要在**签发证书时就跟 CA 说清楚**，不然拿到手才发现格式不对，又得走一轮。

**前端的证书可以自签**：ALB 到目标的 HTTPS 连接**不校验目标证书**，这是 ALB 的既定行为。
真正需要被信任的是后端那张 —— 前端 nginx 会校验它，所以它的 **SAN 必须包含前端实际访问的主机名**。

## 6. 启动命令固化在 Dockerfile

模板没有 `command` / `entrypoint` 字段，不覆盖镜像的 `ENTRYPOINT` / `CMD`。启动逻辑全部写进 Dockerfile。

## 7. 日志只走 stdout / stderr

用 awslogs driver。写进文件的日志进不了 CloudWatch，而且没挂卷，会把 20 GiB 临时盘写满。

## 8. tag 约定

| 环境 | tag |
| --- | --- |
| DEV / PPD | `latest`，每次覆盖 |
| PRD | 确定版本号，填进 `env/prd.tfvars` |

**待确认**：ECR 仓库若开了 `IMMUTABLE` tag，`latest` 第二次 push 直接失败，DEV/PPD 这套就不成立，得改成每次新 tag。问 AZ。

## 9. 推送

仓库地址结尾是 `.amazonaws.com.cn`，不是 `.amazonaws.com`。确切地址用 `terraform output image_urls`。

    aws ecr get-login-password --region cn-north-1 \
      | docker login --username AWS --password-stdin \
        <账号>.dkr.ecr.cn-north-1.amazonaws.com.cn

    docker tag <本地> <账号>.dkr.ecr.cn-north-1.amazonaws.com.cn/<仓库>:<tag>
    docker push <账号>.dkr.ecr.cn-north-1.amazonaws.com.cn/<仓库>:<tag>

## 10. 其他

- **非 root 运行**：Dockerfile 里写 `USER`，安全扫描常卡这条。
- **密码不打进镜像层**：敏感值放 Secrets Manager，在 tfvars 的 `secrets` 里引用。非敏感配置放 `environment`。
- **健康检查端点**：两个前端要提供 **HTTPS** 端点（如 `/health`），由 ALB 目标组检查，路径和 AZ 配的目标组一致。后端不挂 ALB，健康检查方式待定。
- **基础镜像来源待确认**：cn-north-1 直连 Docker Hub 不稳，内部是否有 artifact 镜像源要问 AZ。
- **镜像不要太大**：Fargate 临时盘 20 GiB（模板没开 `ephemeral_storage`），大镜像还会拖慢扩容时的拉取。
