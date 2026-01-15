
# assume we have already install acme.sh
# 获取 Makefile 的完整路径（包含文件名）
MKFILE_PATH := $(abspath $(lastword $(MAKEFILE_LIST)))

# 获取 Makefile 所在的目录路径（不包含文件名）
CUR_DIR := $(patsubst %/,%,$(dir $(MKFILE_PATH)))

-include .env
export

env:
	-mkdir -p /var/www/cert
	cp .env.example .env

clear:
	rm -rf server/hy2/config/config.toml
	rm -rf server/nginx/conf/acme.conf
	rm -rf server/xray/config/config.json
	rm -rf .env

# 自动从 .env 中提取所有变量名并拼接成 $VAR1,$VAR2 的格式
VARS_EXTRACTED := $(shell grep -v '^#' .env | cut -d= -f1 | sed 's/^/$$/' | paste -sd, -)

template:
	envsubst '$(VARS_EXTRACTED)' < server/hy2/config/config.toml.template > server/hy2/config/config.toml
	envsubst '$(VARS_EXTRACTED)' < server/nginx/acme.conf.template > server/nginx/conf/acme.conf
	envsubst '$(VARS_EXTRACTED)' < server/xray/config/config.json.template > server/xray/config/config.json

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
	  --reloadcmd "$(CUR_DIR)/reload.sh"

up:
	$(CUR_DIR)/reload.sh

up-nginx:
	docker compose -f server/nginx/docker-compose.yml up -d

up-hy2:
	docker compose -f server/hy2/docker-compose.yml up -d

up-xray:
	docker compose -f server/xray/docker-compose.yml up -d