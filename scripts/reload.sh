#!/bin/bash

# 获取脚本真实路径（处理了软链接问题）
SCRIPT_PATH=$(readlink -f "$0")

# 获取脚本所在目录
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
ROOT_DIR=$(dirname "$SCRIPT_DIR")

# 判断环境是否有可用的 Docker：
# 有则用 docker compose 重建容器；没有则走 systemctl（systemd 模式，无 xray）
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "[reload.sh] Docker detected, reloading via docker compose..."
    compose="docker compose"

    $compose -f ${ROOT_DIR}/server/nginx/docker-compose.yml down
    $compose -f ${ROOT_DIR}/server/hy2/docker-compose.yml down
    $compose -f ${ROOT_DIR}/server/xray/docker-compose.yml down
    $compose -f ${ROOT_DIR}/server/sing-box/docker-compose.yml down

    $compose -f ${ROOT_DIR}/server/nginx/docker-compose.yml up -d
    $compose -f ${ROOT_DIR}/server/hy2/docker-compose.yml up -d
    $compose -f ${ROOT_DIR}/server/xray/docker-compose.yml up -d
    $compose -f ${ROOT_DIR}/server/sing-box/docker-compose.yml up -d
else
    echo "[reload.sh] Docker not found, reloading via systemctl..."
    # reload-or-restart：支持 ExecReload 的服务（nginx）走 reload，
    # 不支持的（hy2/sing-box 无 ExecReload）自动退化为 restart
    systemctl reload-or-restart nginx hy2 sing-box
fi
