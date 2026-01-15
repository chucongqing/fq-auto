
# assume we have already install acme.sh
# 获取 Makefile 的完整路径（包含文件名）
MKFILE_PATH := $(abspath $(lastword $(MAKEFILE_LIST)))

# 获取 Makefile 所在的目录路径（不包含文件名）
CUR_DIR := $(patsubst %/,%,$(dir $(MKFILE_PATH)))

-include .env
export

env:
	cp .env.example .env

issue_cert:
	~/.acme.sh/acme.sh --issue --force \
	  -d "$(MYSITE)" \
	  --keylength ec-256 \
	  -w /var/www/cert \
	  --server letsencrypt

install_cert:
	~/.acme.sh/acme.sh --install-cert \
	  -d "$(MYSITE)" \
	  --keylength ec-256 \
	  --fullchain-file /etc/ssl/cert.pem \
	  --key-file /etc/ssl/key.pem \
	  --reloadcmd "$(CUR_DIR)/reload.sh"

up:
	$(CUR_DIR)/reload.sh