#!/bin/bash

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")

ACTION="${1:-proxies}"

case "$ACTION" in
    nginx)
        SERVICES="nginx"
        ;;
    proxies)
        SERVICES="hy2 sing-box"
        ;;
    all)
        SERVICES="nginx hy2 sing-box"
        ;;
    *)
        echo "Usage: $0 [nginx|proxies|all]"
        exit 1
        ;;
esac

echo "[systemd] Installing service files for: $SERVICES ..."

for svc in $SERVICES; do
    SRC="$ROOT_DIR/systemd/${svc}.service"
    DST="/etc/systemd/system/${svc}.service"

    if [ ! -f "$SRC" ]; then
        echo "[WARN] $SRC not found, skipping ${svc}"
        continue
    fi

    install -m 0644 "$SRC" "$DST"
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
