#!/bin/bash

set -e

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

echo "[systemd] Stopping and disabling services: $SERVICES ..."

for svc in $SERVICES; do
    if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
        systemctl stop "${svc}.service" || true
        echo "[systemd] Stopped ${svc}.service"
    fi
    if systemctl is-enabled --quiet "${svc}.service" 2>/dev/null; then
        systemctl disable "${svc}.service" || true
        echo "[systemd] Disabled ${svc}.service"
    fi
    if [ -f "/etc/systemd/system/${svc}.service" ]; then
        rm -f "/etc/systemd/system/${svc}.service"
        echo "[systemd] Removed ${svc}.service"
    fi
done

systemctl daemon-reload

echo "[DONE] All systemd services uninstalled."
