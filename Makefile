
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

init:
	-mkdir -p /var/www/cert
	-mkdir -p /etc/ssl
	chmod +x $(CUR_DIR)/scripts/reload.sh

env:
	-mkdir -p /var/www/cert
	cp .env.example .env

clear:
	rm -rf server/hy2/config/config.toml
	rm -rf server/nginx/conf/acme.conf
	rm -rf server/xray/config/config.json
	rm -rf server/sing-box/config/config.json
	rm -rf .env

clear-systemd:
	rm -rf /usr/local/etc/hysteria/config.toml
	rm -rf /usr/local/etc/sing-box/config.json

clear-nginx-systemd:
	rm -f /etc/nginx/conf.d/acme.conf

template:
	-mkdir -p server/hy2/config server/nginx/conf server/xray/config server/sing-box/config
	VARS_EXTRACTED=$$(grep -v '^#' .env | cut -d= -f1 | sed 's/^/$$/' | paste -sd, -) && \
	envsubst "$$VARS_EXTRACTED" < server/hy2/config/config.toml.template > server/hy2/config/config.toml && \
	envsubst "$$VARS_EXTRACTED" < server/nginx/acme.conf.template > server/nginx/conf/acme.conf && \
	envsubst "$$VARS_EXTRACTED" < server/xray/config/config.json.template > server/xray/config/config.json && \
	envsubst "$$VARS_EXTRACTED" < server/sing-box/config/config.json.template > server/sing-box/config/config.json

issue_cert:
	~/.acme.sh/acme.sh --issue --force \
	  -d "$(MYSITE)" \
	  --keylength ec-256 \
	  -w /var/www/cert \
	  --server letsencrypt

install_cert:
	- mkdir -p /etc/ssl
	~/.acme.sh/acme.sh --install-cert \
	  -d "$(MYSITE)" \
	  --keylength ec-256 \
	  --fullchain-file /etc/ssl/cert.pem \
	  --key-file /etc/ssl/key.pem \
	  --reloadcmd "$(CUR_DIR)/scripts/reload.sh"

up:
	$(CUR_DIR)/scripts/reload.sh

up-nginx:
	docker compose -f server/nginx/docker-compose.yml up -d

up-hy2:
	docker compose -f server/hy2/docker-compose.yml up -d

up-xray:
	docker compose -f server/xray/docker-compose.yml up -d

up-singbox:
	docker compose -f server/sing-box/docker-compose.yml up -d

# Restart individual Docker containers to apply config changes
restart-docker-nginx:
	docker compose -f server/nginx/docker-compose.yml down
	docker compose -f server/nginx/docker-compose.yml up -d

restart-docker-hy2:
	docker compose -f server/hy2/docker-compose.yml down
	docker compose -f server/hy2/docker-compose.yml up -d

restart-docker-xray:
	docker compose -f server/xray/docker-compose.yml down
	docker compose -f server/xray/docker-compose.yml up -d

restart-docker-singbox:
	docker compose -f server/sing-box/docker-compose.yml down
	docker compose -f server/sing-box/docker-compose.yml up -d

# =============================================================================
# systemd targets (for low-end VPS without Docker)
# =============================================================================

install-bin:
	chmod +x $(CUR_DIR)/scripts/install-bin.sh
	$(CUR_DIR)/scripts/install-bin.sh proxies

install-nginx:
	chmod +x $(CUR_DIR)/scripts/install-bin.sh
	$(CUR_DIR)/scripts/install-bin.sh nginx

install-systemd:
	chmod +x $(CUR_DIR)/scripts/install-systemd.sh
	$(CUR_DIR)/scripts/install-systemd.sh proxies

install-nginx-systemd:
	chmod +x $(CUR_DIR)/scripts/install-systemd.sh
	$(CUR_DIR)/scripts/install-systemd.sh nginx

uninstall-systemd:
	chmod +x $(CUR_DIR)/scripts/uninstall-systemd.sh
	$(CUR_DIR)/scripts/uninstall-systemd.sh proxies

uninstall-nginx-systemd:
	chmod +x $(CUR_DIR)/scripts/uninstall-systemd.sh
	$(CUR_DIR)/scripts/uninstall-systemd.sh nginx

sys-template:
	-mkdir -p /usr/local/etc/hysteria /usr/local/etc/sing-box
	cp server/hy2/config/config.toml /usr/local/etc/hysteria/config.toml
	cp server/sing-box/config/config.json /usr/local/etc/sing-box/config.json

sys-template-nginx:
	-mkdir -p /etc/nginx/conf.d
	cp server/nginx/conf/acme.conf /etc/nginx/conf.d/acme.conf
	nginx -t || true

start:
	systemctl start hy2 sing-box || true

stop:
	systemctl stop hy2 sing-box || true

restart:
	systemctl restart hy2 sing-box || true

status:
	@systemctl status hy2 --no-pager || true
	@systemctl status sing-box --no-pager || true

start-nginx:
	systemctl start nginx

stop-nginx:
	systemctl stop nginx

restart-nginx:
	systemctl restart nginx

status-nginx:
	@systemctl status nginx --no-pager || true

start-hy2:
	systemctl start hy2

stop-hy2:
	systemctl stop hy2

restart-hy2:
	systemctl restart hy2

start-singbox:
	systemctl start sing-box

stop-singbox:
	systemctl stop sing-box

restart-singbox:
	systemctl restart sing-box

# =============================================================================
# Client targets (sing-box + hysteria2 standalone clients)
# =============================================================================

client-env:
	cp .env.client.template .env.client

client-template:
	chmod +x $(CUR_DIR)/scripts/gen-client-config.sh
	$(CUR_DIR)/scripts/gen-client-config.sh

client-download-ruleset:
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

client-up:
	docker compose -f client/docker-compose.yml --env-file .env.client up -d

client-down:
	docker compose -f client/docker-compose.yml --env-file .env.client down

client-restart:
	docker compose -f client/docker-compose.yml --env-file .env.client down
	docker compose -f client/docker-compose.yml --env-file .env.client up -d

# --- sing-box client ---
client-start-singbox:
	docker compose -f client/docker-compose.yml --env-file .env.client up -d sing-box-client

client-stop-singbox:
	docker compose -f client/docker-compose.yml --env-file .env.client stop sing-box-client

client-restart-singbox:
	docker compose -f client/docker-compose.yml --env-file .env.client restart sing-box-client

client-logs-singbox:
	docker logs -f sing-box-client

# --- hysteria2 client ---
client-start-hy2:
	docker compose -f client/docker-compose.yml --env-file .env.client up -d hysteria2-client

client-stop-hy2:
	docker compose -f client/docker-compose.yml --env-file .env.client stop hysteria2-client

client-restart-hy2:
	docker compose -f client/docker-compose.yml --env-file .env.client restart hysteria2-client

client-logs-hy2:
	docker logs -f hysteria2-client

client-clear:
	rm -rf client/config/config.json
	rm -rf client/config/rule-set
	rm -rf client/hy2-config/config.yaml
	rm -rf .env.client
