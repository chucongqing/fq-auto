#!/bin/bash

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")

# 加载 .env 变量供 envsubst 使用
if [ -f "$ROOT_DIR/.env" ]; then
    set -a
    source "$ROOT_DIR/.env"
    set +a
fi

ACTION="${1:-proxies}"

case "$ACTION" in
    nginx)
        SERVICES="nginx"
        ;;
    proxies)
        SERVICES="hy2 sing-box mosdns"
        ;;
    all)
        SERVICES="nginx hy2 sing-box mosdns"
        ;;
    *)
        echo "Usage: $0 [nginx|proxies|all]"
        exit 1
        ;;
esac

echo "[systemd] Installing service files for: $SERVICES ..."

for svc in $SERVICES; do
    SRC="$ROOT_DIR/systemd/${svc}.service.template"
    DST="/etc/systemd/system/${svc}.service"

    if [ ! -f "$SRC" ]; then
        echo "[WARN] $SRC not found, skipping ${svc}"
        continue
    fi

    envsubst < "$SRC" > "$DST"
    chmod 644 "$DST"
    echo "[systemd] Installed ${svc}.service"
done

systemctl daemon-reload

for svc in $SERVICES; do
    if [ -f "/etc/systemd/system/${svc}.service" ]; then
        systemctl enable "${svc}.service" || true
        echo "[systemd] Enabled ${svc}.service"
    fi
done

echo "[DONE] All systemd services installed and enabled."
echo "       Run 'make start' or 'systemctl start <service>' to start."
