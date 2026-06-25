# Ephemeral Proxy on Vultr

这个项目用于按需创建 Vultr VPS，通过 Cloudflare 更新域名 A 记录，然后用 Docker Compose 部署可选的 `Trojan` 或 `AnyTLS` 代理。用完后可以一条命令销毁 VPS 和 DNS 记录。

## 设计

```text
local deploy.sh
  -> Vultr API creates Ubuntu VPS with cloud-init
  -> cloud-init installs Docker Engine and Compose plugin
  -> Cloudflare API updates DOMAIN A record, proxied=false
  -> local certbot issues/reuses a DNS-01 certificate through Cloudflare
  -> cloud-init unpacks the compose bundle and starts the selected proxy stack
```

本地敏感文件默认不提交：

- `.env`：Vultr / Cloudflare token 和域名配置
- `.state/`：VPS ID、DNS record ID、代理密码、客户端链接
- `.certs/`：Let's Encrypt 证书缓存

## 前置条件

本地需要：

- `bash`
- `curl`
- `jq`
- `ssh` / `scp`
- `openssl`
- `docker`，仅在需要自动签发证书时使用

Vultr 需要：

- API key
- 可用的 region / plan
- SSH key，默认使用 `~/.ssh/id_ed25519`，不存在时会自动生成

Cloudflare 需要：

- Zone ID
- API Token
- Token 至少需要该 zone 的 DNS edit 权限

代理流量不应打开 Cloudflare 橙云代理，脚本默认 `CF_PROXIED=false`。

## 配置

```bash
cp .env.example .env
chmod 600 .env
```

至少填写：

```bash
VULTR_API_KEY=...
CLOUDFLARE_API_TOKEN=...
CLOUDFLARE_ZONE_ID=...
DOMAIN=t.example.com
ACME_EMAIL=you@example.com
```

默认实例配置：

```bash
VULTR_REGION=nrt
VULTR_PLAN=vc2-1c-1gb
VULTR_OS_NAME="Ubuntu 24.04 x64"
VULTR_OS_QUERY="Ubuntu 24.04"
VULTR_ENABLE_IPV6=false
```

脚本会先按 `VULTR_OS_NAME` 精确匹配，再按 `VULTR_OS_QUERY` 模糊匹配。如果 Vultr 的 OS 名称匹配失败，可以直接设置：

```bash
VULTR_OS_ID=2284
```

实际 OS ID 以 Vultr `/v2/os` API 返回为准。

默认 SSH 配置：

```bash
VULTR_SSH_KEY_ID=
VULTR_SSH_PUBLIC_KEY_FILE=~/.ssh/id_ed25519.pub
SSH_PRIVATE_KEY_FILE=~/.ssh/id_ed25519
GENERATE_SSH_KEY=true
SSH_WAIT_INTERVAL=10
```

如果 `SSH_PRIVATE_KEY_FILE` 不存在，脚本会自动生成一个本地 ed25519 key，并把公钥上传到 Vultr。已有 key 不会被覆盖。

默认情况下，Vultr instance label 会自动带上创建时间，格式类似：

```text
trojan-example-com-202606150344
```

如果你需要固定名称，也可以在 `.env` 里显式设置 `VULTR_LABEL`。

默认部署方式：

```bash
PROXY_STACK=trojan
DEPLOY_METHOD=cloud-init
REMOTE_DIR=/opt/trojan
SUBSCRIPTION_PATH=/shuadhTrojan.123
```

可选协议：

```bash
# 保持现有 Trojan 流程
PROXY_STACK=trojan

# 启用 AnyTLS，默认会把协议监听在 8443，443 继续留给 HTTPS 订阅和伪装页
PROXY_STACK=anytls
ANYTLS_PORT=8443
```

`cloud-init` 模式会把 Docker Compose、协议配置和证书打包进 Vultr user-data，让服务器首启时自己完成部署，不依赖 SSH/SCP。对应的 `.state/cloud-init-rendered.yml` 和 `.state/proxy-bundle.tar.gz` 包含证书私钥，不要分享或提交。

订阅地址固定为：

```text
https://<DOMAIN><SUBSCRIPTION_PATH>
```

默认路径是 `/shuadhTrojan.123`，可在 `.env` 里通过 `SUBSCRIPTION_PATH` 调整。

## 部署

```bash
./deploy.sh
```

部署完成后会输出：

- 当前代理协议
- 域名
- VPS IP
- 订阅 URL
- state 文件位置
- 客户端 URI

客户端 URI 也会写入：

```text
.state/client-uri.txt
```

如果 `.state/trojan-state.json` 里已有实例 ID，`deploy.sh` 会复用该实例并检查服务可用性。强制创建新实例：

```bash
./deploy.sh --force-new
```

`cloud-init` 模式复用已有实例时不会重放 user-data，因此本地 Docker/nginx/协议配置变更需要用 `--force-new` 才会部署到新机器。`--force-new` 默认会在新机器健康检查通过、DNS 切换完成后销毁旧实例；如需保留旧实例，设置 `DESTROY_OLD_ON_FORCE_NEW=false`。

如果 macOS 在频繁切换域名 IP 后仍解析到旧地址，可以手动清理本机 DNS 缓存：

```bash
./scripts/flush-macos-dns.sh
```

如果 Linux 服务器无法访问 Docker Hub，可以配置 Docker registry mirror：

```bash
sudo ./scripts/configure-docker-mirror.sh https://your-id.mirror.aliyuncs.com
docker pull certbot/dns-cloudflare:latest
```

阿里云 ECS 建议使用阿里云控制台提供的个人镜像加速地址，不要直接照抄别人的 mirror URL。

## 证书

默认情况下，如果没有配置本地证书路径，脚本会用 Docker 运行 `certbot/dns-cloudflare`，通过 Cloudflare DNS-01 签发或复用证书：

```text
.certs/live/<DOMAIN>/fullchain.pem
.certs/live/<DOMAIN>/privkey.pem
```

如果你已经有证书，可以跳过 certbot：

```bash
CERT_FULLCHAIN_FILE=/path/to/fullchain.pem
CERT_PRIVATE_KEY_FILE=/path/to/privkey.pem
```

如果 `.certs/live/<DOMAIN>/fullchain.pem` 已存在且距离过期超过 `CERT_RENEW_BEFORE_SECONDS`，脚本会直接复用本地证书，不会启动 certbot 容器，也不会拉 Docker Hub 镜像。

测试证书签发流程时可以使用 Let's Encrypt staging：

```bash
ACME_STAGING=true ./deploy.sh
```

staging 证书不适合真实客户端使用。

## 销毁

交互确认：

```bash
./destroy.sh
```

非交互：

```bash
./destroy.sh --yes
```

只销毁 VPS，保留 DNS：

```bash
./destroy.sh --yes --keep-dns
```

销毁脚本默认根据 `.state/trojan-state.json` 删除对应 Vultr instance 和 Cloudflare DNS record。

## 状态检查

多台电脑共同管理时，可以用状态检查确认本机 state、Cloudflare DNS、系统 DNS 缓存和 Vultr 实例是否一致：

```bash
./status.sh
```

如果 `System resolver IP` 和 `Cloudflare A record` 不一致，说明本机或上游 DNS 仍缓存旧记录。macOS 可以运行：

```bash
./scripts/flush-macos-dns.sh
```

## Vultr 地区测速

可以直接用项目里的脚本对 Vultr Looking Glass 做本地测速，默认只测 `ping`，覆盖东京、大阪、首尔、新加坡、洛杉矶、纽约、德国、英国、悉尼：

```bash
./scripts/test-vultr-regions.sh
```

只测指定地区：

```bash
./scripts/test-vultr-regions.sh --regions nrt,sgp,icn,lax,nyc,fra,uk,syd
```

连下载测速一起测：

```bash
./scripts/test-vultr-regions.sh --speed
```

自定义下载测试大小：

```bash
./scripts/test-vultr-regions.sh --bytes 20971520
```

脚本会输出每个地区的：

- 国家
- 平均 `ping` 延迟
- 丢包率
- 可选的基于 Vultr `100MB.bin` 的分段下载速度
- 可选的 HTTP 返回码

## 客户端导入

`Trojan` 和 `AnyTLS` 的导入方式不同：

- `Trojan`：继续使用 `trojan://...`，也可以用下面的 Clash Verge Rev 增强脚本方式合并到现有订阅。
- `AnyTLS`：订阅地址会直接返回 Mihomo/Clash YAML，可在 Clash Verge Rev 里作为远程配置导入。

### Clash Verge Rev 合并

不要直接编辑订阅下载下来的 YAML；订阅更新时会覆盖。推荐生成增强脚本，把本项目的 Trojan 节点注入到现有订阅的策略组里：

```bash
./scripts/export-clash-verge-script.sh
```

脚本会生成：

```text
.state/clash-verge-script.js
```

在 Clash Verge Rev 里把这个文件作为当前订阅的 Script/脚本增强使用。订阅的 rules 和 proxy-groups 仍然来自原订阅；每次订阅更新后，这个本地节点会重新加回策略组。

这个脚本只适用于 `Trojan` 部署；`AnyTLS` 不生成 Clash Verge 节点增强脚本。

## 文件结构

```text
deploy.sh
destroy.sh
status.sh
scripts/lib.sh
scripts/export-clash-verge-script.sh
templates/cloud-init.yml
templates/docker-compose.yml
templates/docker-compose-anytls.yml
templates/nginx-default.conf
templates/nginx-default-tls.conf
templates/fallback-index.html
.env.example
```

远端 VPS 上的默认目录：

```text
/opt/trojan
```

包含：

```text
docker-compose.yml
certs/fullchain.pem
certs/privkey.pem
nginx/default.conf
nginx/html/index.html
```

如果是 `Trojan`：

```text
xray/config.json
```

如果是 `AnyTLS`：

```text
sing-box/config.json
```

## 注意

- 建议给 Vultr 配置 Cloud Firewall，只开放 `443/tcp` 和必要的 `22/tcp`。
- 如果使用 `AnyTLS`，还需要放行 `ANYTLS_PORT`，默认 `8443/tcp`。
- 如果需要普通 Web 外观，也开放 `80/tcp`；Trojan 模式下 HTTPS 由 Xray fallback 到 nginx，AnyTLS 模式下 HTTPS 由 nginx 直接提供。
- Cloudflare DNS record 必须是 DNS only，即 `proxied=false`。
- 订阅地址由 `.env` 里的 `SUBSCRIPTION_PATH` 控制，默认是 `https://<DOMAIN>/shuadhTrojan.123`，不要公开分享。
- `.state/trojan-state.json` 包含代理密码，不要上传或分享。
- `.certs/` 包含证书私钥，不要上传或分享。

## 参考

- [Vultr cloud-init user-data](https://docs.vultr.com/how-to-deploy-a-vultr-server-with-cloudinit-userdata)
- [Cloudflare DNS records API](https://developers.cloudflare.com/dns/manage-dns-records/how-to/create-dns-records/)
- [Xray Docker image layout](https://xtls.github.io/en/document/install.html#docker-installation)
- [sing-box AnyTLS inbound](https://sing-box.sagernet.org/configuration/inbound/anytls/)
- [sing-box remote profile import](https://sing-box.sagernet.org/clients/general/)
- [Docker Engine for Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
