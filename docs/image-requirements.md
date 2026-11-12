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
| 打进去就得一个环境一个镜像 | 无法把同一已构建镜像按时间戳 tag / digest 晋级到其他环境 |

后端地址从 `environment` 的 `BACKEND_URL` 读取。当前三个环境的两个前端均为
`https://backend-service:8002`，通过 ECS Service Connect 访问后端，不经内部 ALB。
Terraform 会拒绝前端缺失该地址、使用 HTTP，或在地址中加入路径 / 末尾斜杠的配置。

nginx 不会自己读环境变量，镜像要在 entrypoint 里做一次替换，例如：

    envsubst '$BACKEND_URL' < /etc/nginx/templates/default.conf.template \
      > /etc/nginx/conf.d/default.conf

变量名要和 `env/*.tfvars` 里 `environment` 的 key 一致，现在写的是 `BACKEND_URL`，按镜像实际用的改。

**在启动时用 envsubst 把地址写入静态 `proxy_pass`，保留 `/api` 请求路径：**

    location /api/ {
      proxy_pass ${BACKEND_URL};          # After envsubst: https://backend-service:8002 | envsubst 后是 https://backend-service:8002
      proxy_ssl_server_name on;           # The backend uses HTTPS; send SNI | 后端是 HTTPS，SNI 要带上
      proxy_ssl_verify off;               # Disable backend certificate verification explicitly; this is also the default | 不校验后端证书（这也是默认值，写出来明确意图）
    }

`backend-service` 是 Service Connect 注入前端任务的端点名，可在容器的 `/etc/hosts` 中查看，
不是 VPC DNS 中的 ALB 域名。上述静态地址由系统在 Nginx 启动时解析到本任务的代理端点，
后端任务 IP 的变化由 Service Connect 代理处理。
不要改成 Nginx 运行期 `$upstream` 变量加 VPC `resolver`：该解析会绕过系统 hosts，可能找不到端点。
首次部署须先创建后端端点，再启动前端任务；已有前端任务需要重新部署才能获得新增端点。

`service_connect_configuration.enabled = true` 仅开启服务通信代理，不能替代镜像的 TLS 配置。
本模板保持 `appProtocol` 未设置，代理按 TCP 转发应用自己的 TLS 流量；
未启用基于 AWS Private CA 的 Service Connect 原生 TLS。

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
当前前端 Nginx 示例设置 `proxy_ssl_verify off`，前端到后端仍使用 HTTPS 加密，允许自签证书，
但不验证后端身份。若改为 `proxy_ssl_verify on`，须同时配置 `proxy_ssl_trusted_certificate`，
并让后端证书的 SAN 包含 `backend-service`（或实际访问的主机名）。

### 部署后的 HTTPS 验收

部署后，通过现有的任务内调试方式，从两个前端容器分别执行：

    curl --fail --show-error --verbose --insecure https://backend-service:8002/health

确认 TLS 握手完成、返回后端健康响应，再通过前端实际 `/api` 路径验证反向代理。
`--insecure` 对应当前自签证书策略；它仍使用 TLS，不代表证书信任校验通过。
最后检查后端没有额外开放 HTTP connector，不能仅凭 HTTPS 健康检查认定所有调用均已加密。
Terraform 只注入证书变量，不会替镜像生成这些文件或开启 Spring Boot / Nginx 的 TLS。

## 6. 启动命令固化在 Dockerfile

模板没有 `command` / `entrypoint` 字段，不覆盖镜像的 `ENTRYPOINT` / `CMD`。启动逻辑全部写进 Dockerfile。

## 7. 日志只走 stdout / stderr

用 awslogs driver。写进文件的日志进不了 CloudWatch，而且没挂卷，会把 20 GiB 临时盘写满。

## 8. tag 约定

| 环境 | tag |
| --- | --- |
| DEV / PPD / PRD 构建 | 构建时生成北京时间 `yyyyMMddHHmmss`，例如 `20261112153045` |
| 各环境首次部署 | 将已推送的实际时间戳 tag 填入 `env/*.tfvars` 的 `services.*.tag` |

三个 buildspec 在 `pre_build` 执行 `export IMAGE_TAG="$(TZ=Asia/Shanghai date +%Y%m%d%H%M%S)"`，
同一次构建的 build / push / 元数据记录复用该值。不要在 Terraform 中使用 `timestamp()`，否则 tag 会随 apply 改变而不是随构建改变。
现有构建脚本继续记录源提交、构建 ID 和 digest，并保留 `sha-<commit>` 辅助标签。
同仓库同一秒并发构建可能重名；IMMUTABLE 仓库重复推送相同 tag 会失败，发布流程应避免同仓库同秒并发，且辅助 SHA 标签的重复推送也受不可变规则约束。
构建仍只推送镜像；独立发布流程需选取实际 tag / 已批准 digest 注册新 revision 并更新 ECS 服务。

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
- **健康检查端点**：三个服务都要提供 **HTTPS** 的 `/health`。前端由 ALB 目标组检查；**后端不挂 ALB，靠容器健康检查，所以后端镜像里必须有 `curl`** —— 命令是 `curl -fsSk https://localhost:8002/health`，`-k` 是跳过自签证书校验。没有 curl 会变成无限 crashloop。
- **基础镜像来源待确认**：cn-north-1 直连 Docker Hub 不稳，内部是否有 artifact 镜像源要问 AZ。
- **镜像不要太大**：Fargate 临时盘 20 GiB（模板没开 `ephemeral_storage`），大镜像还会拖慢扩容时的拉取。

参考：[Service Connect 配置](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-connect-concepts.html)、
[AWS 端点解析排查](https://repost.aws/knowledge-center/ecs-troubleshoot-service-connect)、
[Nginx HTTPS 上游配置](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_pass)。
