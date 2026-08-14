
# assume we have already install acme.sh
# 获取 Makefile 的完整路径（包含文件名）
MKFILE_PATH := $(abspath $(lastword $(MAKEFILE_LIST)))

# 获取 Makefile 所在的目录路径（不包含文件名）
CUR_DIR := $(patsubst %/,%,$(dir $(MKFILE_PATH)))

CLIENT_RULESET_DIR := $(CUR_DIR)/client/config/rule-set
CLIENT_GEOSITE_CN_URL := https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs
CLIENT_GEOIP_CN_URL := https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs

-include .env
export

# 不指定目标时，默认显示帮助
.DEFAULT_GOAL := help

.PHONY: help init env clear clear-systemd clear-nginx-systemd \
	config-server config-client config-all config-check template \
	issue_cert install_cert up up-nginx up-hy2 up-xray up-singbox \
	restart-docker-nginx restart-docker-hy2 restart-docker-xray restart-docker-singbox \
	install-bin install-nginx install-systemd install-nginx-systemd \
	uninstall-systemd uninstall-nginx-systemd sys-template sys-template-nginx \
	start stop restart status start-nginx stop-nginx restart-nginx status-nginx \
	start-hy2 stop-hy2 restart-hy2 start-singbox stop-singbox restart-singbox \
	client-env client-template client-download-ruleset client-up client-down client-restart \
	client-start-singbox client-stop-singbox client-restart-singbox client-logs-singbox \
	client-start-hy2 client-stop-hy2 client-restart-hy2 client-logs-hy2 client-clear

help: ## 显示所有可用的 make 目标（默认目标）
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(firstword $(MAKEFILE_LIST)) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

init: ## 初始化目录结构与脚本权限（/var/www/cert、/etc/ssl、reload.sh）
	-mkdir -p /var/www/cert
	-mkdir -p /etc/ssl
	chmod +x $(CUR_DIR)/scripts/reload.sh

env: ## 生成 .env（复制自 .env.example）
	-mkdir -p /var/www/cert
	cp .env.example .env

clear: ## 清理服务端渲染产物与 .env
	rm -rf server/hy2/config/config.toml
	rm -rf server/nginx/conf/acme.conf
	rm -rf server/xray/config/config.json
	rm -rf server/sing-box/config/config.json
	rm -rf .env

clear-systemd: ## 清理 /usr/local/etc 下的 systemd 配置文件
	rm -rf /usr/local/etc/hysteria/config.toml
	rm -rf /usr/local/etc/sing-box/config.json

clear-nginx-systemd: ## 删除 /etc/nginx/conf.d/acme.conf
	rm -f /etc/nginx/conf.d/acme.conf

config-server: ## 统一生成服务端配置（需先 make env）
	bash "$(CUR_DIR)/scripts/config/render.sh" server

config-client: ## 统一生成客户端配置（需先 make client-env）
	bash "$(CUR_DIR)/scripts/config/render.sh" client

config-all: ## 同时生成服务端和客户端配置
	bash "$(CUR_DIR)/scripts/config/render.sh" all

config-check: ## 校验环境文件、已生成配置和可用的服务端语义
	bash "$(CUR_DIR)/scripts/config/render.sh" check

template: config-server ## 兼容旧命令：生成服务端配置

issue_cert: ## 用 acme.sh 签发证书（Let's Encrypt, EC-256）
	~/.acme.sh/acme.sh --issue --force \
	  -d "$(MYSITE)" \
	  --keylength ec-256 \
	  -w /var/www/cert \
	  --server letsencrypt

install_cert: ## 安装证书到 /etc/ssl 并挂接 reload.sh 续期重载钩子
	- mkdir -p /etc/ssl
	~/.acme.sh/acme.sh --install-cert \
	  -d "$(MYSITE)" \
	  --keylength ec-256 \
	  --fullchain-file /etc/ssl/cert.pem \
	  --key-file /etc/ssl/key.pem \
	  --reloadcmd "$(CUR_DIR)/scripts/reload.sh"

up: ## 重启全部 4 个 Docker 容器（调用 scripts/reload.sh）
	$(CUR_DIR)/scripts/reload.sh

up-nginx: ## 启动 nginx 容器
	docker compose -f server/nginx/docker-compose.yml up -d

up-hy2: ## 启动 hysteria2 容器
	docker compose -f server/hy2/docker-compose.yml up -d

up-xray: ## 启动 xray 容器
	docker compose -f server/xray/docker-compose.yml up -d

up-singbox: ## 启动 sing-box 容器
	docker compose -f server/sing-box/docker-compose.yml up -d

# Restart individual Docker containers to apply config changes
restart-docker-nginx: ## 重建 nginx 容器（配置变更后生效）
	docker compose -f server/nginx/docker-compose.yml down
	docker compose -f server/nginx/docker-compose.yml up -d

restart-docker-hy2: ## 重建 hysteria2 容器（配置变更后生效）
	docker compose -f server/hy2/docker-compose.yml down
	docker compose -f server/hy2/docker-compose.yml up -d

restart-docker-xray: ## 重建 xray 容器（配置变更后生效）
	docker compose -f server/xray/docker-compose.yml down
	docker compose -f server/xray/docker-compose.yml up -d

restart-docker-singbox: ## 重建 sing-box 容器（配置变更后生效）
	docker compose -f server/sing-box/docker-compose.yml down
	docker compose -f server/sing-box/docker-compose.yml up -d

# =============================================================================
# systemd targets (for low-end VPS without Docker)
# =============================================================================

install-bin: ## 下载并安装代理二进制到 /usr/local/bin（_DOWNLOAD_URL 为空则跳过）
	chmod +x $(CUR_DIR)/scripts/install-bin.sh
	$(CUR_DIR)/scripts/install-bin.sh proxies

install-nginx: ## 安装系统 Nginx（不装代理二进制）
	chmod +x $(CUR_DIR)/scripts/install-bin.sh
	$(CUR_DIR)/scripts/install-bin.sh nginx

install-systemd: ## 渲染并启用 hy2/sing-box 的 systemd 服务
	chmod +x $(CUR_DIR)/scripts/install-systemd.sh
	$(CUR_DIR)/scripts/install-systemd.sh proxies

install-nginx-systemd: ## 渲染并启用 Nginx 的 systemd 服务
	chmod +x $(CUR_DIR)/scripts/install-systemd.sh
	$(CUR_DIR)/scripts/install-systemd.sh nginx

uninstall-systemd: ## 卸载 hy2/sing-box 的 systemd 服务
	chmod +x $(CUR_DIR)/scripts/uninstall-systemd.sh
	$(CUR_DIR)/scripts/uninstall-systemd.sh proxies

uninstall-nginx-systemd: ## 卸载 Nginx 的 systemd 服务
	chmod +x $(CUR_DIR)/scripts/uninstall-systemd.sh
	$(CUR_DIR)/scripts/uninstall-systemd.sh nginx

sys-template: ## 复制 hy2/sing-box 配置到 /usr/local/etc/
	-mkdir -p /usr/local/etc/hysteria /usr/local/etc/sing-box
	cp server/hy2/config/config.toml /usr/local/etc/hysteria/config.toml
	cp server/sing-box/config/config.json /usr/local/etc/sing-box/config.json

sys-template-nginx: ## 复制 acme.conf 到 /etc/nginx/conf.d 并执行 nginx -t
	-mkdir -p /etc/nginx/conf.d
	cp server/nginx/conf/acme.conf /etc/nginx/conf.d/acme.conf
	nginx -t || true

start: ## 启动 hy2 与 sing-box 服务
	systemctl start hy2 sing-box || true

stop: ## 停止 hy2 与 sing-box 服务
	systemctl stop hy2 sing-box || true

restart: ## 重启 hy2 与 sing-box 服务
	systemctl restart hy2 sing-box || true

status: ## 查看 hy2 与 sing-box 服务状态
	@systemctl status hy2 --no-pager || true
	@systemctl status sing-box --no-pager || true

start-nginx: ## 启动 Nginx 服务
	systemctl start nginx

stop-nginx: ## 停止 Nginx 服务
	systemctl stop nginx

restart-nginx: ## 重启 Nginx 服务
	systemctl restart nginx

status-nginx: ## 查看 Nginx 服务状态
	@systemctl status nginx --no-pager || true

start-hy2: ## 启动 hy2 服务
	systemctl start hy2

stop-hy2: ## 停止 hy2 服务
	systemctl stop hy2

restart-hy2: ## 重启 hy2 服务
	systemctl restart hy2

start-singbox: ## 启动 sing-box 服务
	systemctl start sing-box

stop-singbox: ## 停止 sing-box 服务
	systemctl stop sing-box

restart-singbox: ## 重启 sing-box 服务
	systemctl restart sing-box

# =============================================================================
# Client targets (sing-box + hysteria2 standalone clients)
# =============================================================================

client-env: ## 生成 .env.client（复制自 .env.client.template）
	cp .env.client.template .env.client

client-template: config-client ## 兼容旧命令：生成客户端配置

client-download-ruleset: ## 下载 geosite-cn / geoip-cn 规则集到 client/config/rule-set
	set -e; \
	mkdir -p $(CLIENT_RULESET_DIR); \
	if command -v curl >/dev/null 2>&1; then \
		curl -fsSL --retry 3 -o $(CLIENT_RULESET_DIR)/geosite-cn.srs $(CLIENT_GEOSITE_CN_URL); \
		curl -fsSL --retry 3 -o $(CLIENT_RULESET_DIR)/geoip-cn.srs $(CLIENT_GEOIP_CN_URL); \
	elif command -v wget >/dev/null 2>&1; then \
		wget -q --tries=3 -O $(CLIENT_RULESET_DIR)/geosite-cn.srs $(CLIENT_GEOSITE_CN_URL); \
		wget -q --tries=3 -O $(CLIENT_RULESET_DIR)/geoip-cn.srs $(CLIENT_GEOIP_CN_URL); \
	else \
		echo "Error: Neither curl nor wget found. Please install one first."; \
		exit 1; \
	fi
	@echo "Client rule sets downloaded to $(CLIENT_RULESET_DIR)"

client-up: ## 启动客户端全部容器（sing-box + hysteria2）
	docker compose -f client/docker-compose.yml --env-file .env.client up -d

client-down: ## 停止并移除客户端容器
	docker compose -f client/docker-compose.yml --env-file .env.client down

client-restart: ## 重启客户端全部容器
	docker compose -f client/docker-compose.yml --env-file .env.client down
	docker compose -f client/docker-compose.yml --env-file .env.client up -d

# --- sing-box client ---
client-start-singbox: ## 启动 sing-box 客户端容器
	docker compose -f client/docker-compose.yml --env-file .env.client up -d sing-box-client

client-stop-singbox: ## 停止 sing-box 客户端容器
	docker compose -f client/docker-compose.yml --env-file .env.client stop sing-box-client

client-restart-singbox: ## 重启 sing-box 客户端容器
	docker compose -f client/docker-compose.yml --env-file .env.client restart sing-box-client

client-logs-singbox: ## 跟踪 sing-box 客户端日志
	docker logs -f sing-box-client

# --- hysteria2 client ---
client-start-hy2: ## 启动 hysteria2 客户端容器
	docker compose -f client/docker-compose.yml --env-file .env.client up -d hysteria2-client

client-stop-hy2: ## 停止 hysteria2 客户端容器
	docker compose -f client/docker-compose.yml --env-file .env.client stop hysteria2-client

client-restart-hy2: ## 重启 hysteria2 客户端容器
	docker compose -f client/docker-compose.yml --env-file .env.client restart hysteria2-client

client-logs-hy2: ## 跟踪 hysteria2 客户端日志
	docker logs -f hysteria2-client

client-clear: ## 清理客户端渲染产物与 .env.client
	rm -rf client/config/config.json
	rm -rf client/config/rule-set
	rm -rf client/hy2-config/config.yaml
	rm -rf .env.client
