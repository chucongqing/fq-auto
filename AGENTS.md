# AGENTS.md

> 本文件面向 AI 编码代理，描述本项目的结构、约定与操作方式。阅读前假设你对项目一无所知。

## 项目概览

**fq-auto (Fly-Auto)** 是一个一键自动化部署多协议代理服务的项目。它**不是传统意义上的应用程序代码库**——没有可编译的服务端源码，核心资产是**配置模板 + Bash 脚本 + Makefile**。

- 仓库地址：`git@github.com:chucongqing/fq-auto.git`
- License：MIT
- 主要语言：中文文档与注释（部分模板注释为英文）

### 技术栈

| 层面 | 技术 |
|------|------|
| 编排入口 | GNU Make（`Makefile`，唯一命令入口） |
| 配置渲染 | `scripts/config/render.sh` 统一入口；文本用受限 `envsubst`，JSON 用 `jq` |
| 服务端运行时 | Docker Compose **或** systemd（二选一） |
| 证书 | acme.sh（Let's Encrypt，EC-256，安装到 `/etc/ssl`，`--reloadcmd` 挂钩重载脚本） |
| 脚本 | Bash（`scripts/*.sh`，`set -e`） |

**没有** `package.json` / `pyproject.toml` / `Cargo.toml` 等包清单；项目本身不构建任何二进制。

## 架构

### 服务端（4 个服务）

| 服务 | 协议 | 默认端口 | 模板 |
|------|------|---------|------|
| Nginx | HTTP（ACME 验证 + 跳转 HTTPS） | 80 | `server/nginx/acme.conf.template` |
| Xray | VLESS + REALITY（`xtls-rprx-vision`） | 443 | `server/xray/config/config.json.template` |
| Hysteria 2 | UDP/QUIC | 10443 | `server/hy2/config/config.toml.template` |
| sing-box | TUIC / AnyTLS | 20443 / 24443 | `server/sing-box/config/config.json.template` |

两种部署模式共享同一份 `.env` 和同一套渲染产物：

- **Docker 模式**：`server/*/docker-compose.yml` 各自独立，`network_mode: host`，统一挂载 `/etc/ssl` 证书。
- **systemd 模式**：二进制装到 `/usr/local/bin`，配置复制到 `/usr/local/etc/`，unit 文件是**静态** `systemd/*.service`，由 `install-systemd.sh` 以 `install -m 0644` 原样安装到 `/etc/systemd/system/`，不做任何 envsubst 渲染。服务以 root 运行。

### 客户端（局域网共享代理，Docker Compose）

`client/docker-compose.yml` 定义两个独立容器，由 `scripts/config/render.sh client` 生成配置；`scripts/gen-client-config.sh` 仅保留为兼容包装：

- `sing-box-client`：Mixed 入站（SOCKS5+HTTP，:7890），VLESS/HY2/TUIC/AnyTLS 多协议出站 + 默认出口选择 + geoip/geosite-cn 分流。
- `hysteria2-client`：原生 HY2 客户端，SOCKS5 :7891 / HTTP :7892。

> 客户端 VLESS/HY2 outbound 是确认保留的行为范围：仓库说明与 `ENABLE_VLESS`/`ENABLE_HY2` 开关早已声明支持，统一化提交只是修复了既有实现缺口（超出"仅统一生成方式"的重构范围）。修改相关 jq filter 时必须回归全部协议组合（见下方"测试与验证"）。

### 目录速查

```
Makefile               # 所有操作的唯一入口
.env.example           # 服务端配置模板（make env 复制为 .env）
.env.client.template   # 客户端配置模板（make client-env 复制为 .env.client）
scripts/               # Bash 脚本（安装、渲染、重载）
server/                # 服务端 4 个服务的 docker-compose.yml + 配置模板
systemd/               # hy2 / nginx / sing-box 的静态 .service（注意：没有 xray）
client/                # 客户端 docker-compose.yml（生成物在 client/config、client/hy2-config）
doc/sing-box/          # sing-box 上游文档片段（参考用）
need/wrapit.md         # HY2 + WARP 解锁 Gemini 的排错笔记（参考用）
sing-box/              # 上游 sagernet/sing-box 的完整 Go 源码克隆（未跟踪、自带 .git，
                       # 仅供查阅协议实现，本项目不构建它，改动请勿提交到本仓库）
temp/                  # 本地日志（已 gitignore）
```

## 核心机制：配置渲染流程

1. `make env` 复制 `.env.example` → `.env`；用户填写域名、UUID、密码等。
2. `make config-server`（`make template` 仍是兼容别名）调用统一渲染入口。文本模板使用显式变量白名单传给受限 `envsubst`，保护模板中 Nginx 的 `$host` 等字面量；JSON 模板由独立 jq filter 注入字符串、数字和数组。生成：
   - `server/hy2/config/config.toml`
   - `server/nginx/conf/acme.conf`
   - `server/xray/config/config.json`
   - `server/sing-box/config/config.json`
3. `make config-client` 生成客户端 sing-box JSON 与 HY2 YAML；`make config-all` 要求两个 env 文件都存在。所有产物先渲染到临时 `.render.*` 目录，依次通过格式检查与可用的服务语义检查（sing-box `check`、xray `-test`、隔离配置下的 `nginx -t`，命令缺失时输出 `[SKIP]`），全部通过后才一次性替换正式输出；任一步失败都不覆盖旧配置。
4. 生成物全部被 `.gitignore` 排除，**绝不提交**。
5. 证书：`make issue_cert` + `make install_cert`（acme.sh → `/etc/ssl/{cert,key.pem}`，`--reloadcmd` 指向 `scripts/reload.sh`，续期后自动重载）。

## 常用命令

```bash
# 初始化与渲染
make init / env / template
make config-server / config-client / config-all / config-check

# Docker 模式
make up                    # 重启全部 4 个容器（调用 scripts/reload.sh）
make up-nginx|up-xray|up-hy2|up-singbox
make restart-docker-<svc>  # 单容器重建（配置变更后）

# systemd 模式（需 sudo）
make install-bin           # 按 .env 中 *_DOWNLOAD_URL 下载二进制到 /usr/local/bin
make install-systemd       # 安装并启用 hy2/sing-box 的静态 service
make sys-template          # 复制配置到 /usr/local/etc/
make start|stop|restart|status
make start-nginx 等        # Nginx 单独一组命令（避免破坏系统已有 Nginx）

# 客户端
make client-env            # 生成 .env.client
make client-template       # 生成 client/config/config.json + client/hy2-config/config.yaml
make client-up / client-down / client-logs-singbox 等
```

## 测试与验证

项目**没有自动化测试**。修改后的验证手段：

- `bash -n scripts/xxx.sh` —— Shell 语法检查。
- `make template` 后人工检查生成物变量是否替换完全（不应残留 `$VAR`）。
- `bash -n scripts/config/render.sh`、`bash -n scripts/config/lib.sh`、`bash -n scripts/config/validate.sh`、`bash -n scripts/gen-client-config.sh` —— 逐脚本做 Shell 语法检查（不要写成 `bash scripts/*.sh -n`：通配符展开后 `-n` 会被当成位置参数）；`jq empty` 检查生成 JSON；`make config-check` 会在可用时追加 sing-box/xray/nginx 语义检查。
- `make sys-template-nginx` 会跑 `nginx -t`（容错 `|| true`）。
- 端到端验证只能在真实 Linux 服务器上做：`docker ps` / `systemctl status` + `journalctl -u <svc> -f`。

## 代码与配置约定

- **行尾**：`.gitattributes` 强制脚本、模板、service、`*.yml`、`*.json`、`*.toml`、`*.md`、`*.conf`、`Makefile` 全部 LF。在 Windows 上编辑必须保持 LF，否则脚本和模板会在 Linux 上损坏。
- **模板命名**：应用配置待渲染文件叫 `*.template`，渲染产物与模板同目录、去掉后缀；systemd unit 是不经过渲染的静态 `*.service`。
- **Shell 脚本**：`set -e`，通过 `SCRIPT_DIR`/`ROOT_DIR` 定位仓库根（`reload.sh` 额外用 `readlink -f` 处理软链）；需要 `.env` 的脚本用 `set -a; source .env; set +a` 导入变量。
- **脚本可执行位**：`scripts/config/render.sh` 与 `scripts/gen-client-config.sh` 已提交可执行位，可直接运行（如 `scripts/config/render.sh server`）；`make init` 会再次 `chmod +x`。`make config-server` 等目标直接调用脚本，不再经 `bash` 包一层。
- **envsubst 陷阱**：文本模板中的项目变量统一使用 `${VAR}`；Nginx `$host`、systemd `$MAINPID` 等程序变量必须保持字面量。Xray 的 `XRAY_SERVERNAMES` / `XRAY_SHORTIDS` 是不带 JSON 引号的逗号分隔数据，由 jq filter 转成数组。
- **安装脚本的包类型判断**：`install-bin.sh` 按 URL 后缀（`.tar.gz`/`.zip`/`.deb`/裸二进制）走不同解压分支；将某个 `*_DOWNLOAD_URL` 留空即跳过该组件。
- **systemd 模式没有 Xray**：`systemd/` 只有 hy2/nginx/sing-box 三个静态 unit，`install-systemd.sh` 的服务集合固定为 `nginx hy2 sing-box`。Xray 仅 Docker 模式支持。

## 已知陷阱（改动前必读）

- **HY2 ACL 语法**：是 `outbound_name(matcher)`（如 `warp_proxy(suffix:google.com)`），**不是** `outbound(matcher, outbound_name)`，写错会报 `outbound not found`。
- **sing-box 路由顺序**：`{ "action": "sniff" }` 必须是 `route.rules` 第一条，否则域名分流（WARP 规则）失效；规则按数组顺序匹配。
- **不要动 `$host` 等 Nginx 变量**：统一渲染器只对白名单变量执行 `envsubst`，不能改成全量替换。
- **客户端 JSON 由 jq filter 处理**：`scripts/config/filters/sing-box-client.jq` 负责协议裁剪、DNS 对象、默认出口和 WARP 规则；修改后必须保持 sniff 规则第一条以及 JSON 类型正确。
- **客户端 REALITY 公钥**：`.env.client` 的 `CLIENT_VLESS_REALITY_PUBLIC_KEY` 填服务端 `xray x25519` 输出的 **Public key**，不是私钥。
- **同一台机器不要混跑两种模式的同一服务**（端口冲突）。
- `scripts/easysetup.sh` 与代理部署无关，是个人 dotfiles（bashrc/tmux/vim）安装器，别把它接进部署流程。

## 安全注意事项

- `.env`、`.env.client` 及所有渲染产物含密钥/密码，已在 `.gitignore` 中，**严禁提交**；示例值（`HY2_PASSWORD=123` 等）仅限演示，部署必须换成强随机值。
- 二进制下载 URL（`*_DOWNLOAD_URL`）和镜像版本（`*_IMAGE`）需随上游定期更新。
- systemd 模式服务以 root 运行（需绑定特权端口）；unit 已带 `NoNewPrivileges=true`，可进一步加 `CapabilityBoundingSet`。
- 建议防火墙只放行 80/443/10443/20443(/24443)。
- 不要在修改中把真实域名、UUID、私钥写进任何会被提交的文件。
