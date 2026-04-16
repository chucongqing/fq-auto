#!/bin/bash

# 获取脚本真实路径（处理了软链接问题）
SCRIPT_PATH=$(readlink -f "$0")

# 获取脚本所在目录
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
ROOT_DIR=$(dirname "$SCRIPT_DIR")


compose="docker compose"

$compose -f ${ROOT_DIR}/server/nginx/docker-compose.yml down
$compose -f ${ROOT_DIR}/server/hy2/docker-compose.yml down
$compose -f ${ROOT_DIR}/server/xray/docker-compose.yml down

$compose -f ${ROOT_DIR}/server/nginx/docker-compose.yml up -d
$compose -f ${ROOT_DIR}/server/hy2/docker-compose.yml up -d
$compose -f ${ROOT_DIR}/server/xray/docker-compose.yml up -d