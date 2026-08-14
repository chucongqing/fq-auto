#!/bin/bash

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")

# 加载 .env
if [ -f "$ROOT_DIR/.env" ]; then
    set -a
    source "$ROOT_DIR/.env"
    set +a
else
    echo "[ERROR] .env not found. Run 'make env' first."
    exit 1
fi

ARCH=$(uname -m)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')

echo "Detected OS: $OS, ARCH: $ARCH"

# 映射 arch 到常用名称
case "$ARCH" in
    x86_64)  ARCH_SHORT="amd64" ;;
    aarch64) ARCH_SHORT="arm64" ;;
    armv7l)  ARCH_SHORT="armv7" ;;
    *)       ARCH_SHORT="$ARCH" ;;
esac

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p /usr/local/bin

# =============================================================================
# 通用下载函数
# =============================================================================
_download() {
    local url="$1"
    local dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url"
    else
        echo "[ERROR] Neither curl nor wget found. Please install one."
        exit 1
    fi
}

# =============================================================================
# 通用安装函数
# 用法: install_binary <name> <url> <bin_name> [<bin_name_in_archive>]
#   name               : 显示名称（如 sing-box）
#   url                : 下载 URL
#   install_path       : 安装到的完整路径（如 /usr/local/bin/sing-box）
#   bin_in_archive     : 压缩包内的二进制文件名（可选，默认与 name 同名）
# =============================================================================
install_from_url() {
    local name="$1"
    local url="$2"
    local install_path="$3"
    local bin_in_archive="${4:-$name}"

    local workdir="$TMPDIR/${name}_work"
    mkdir -p "$workdir"
    cd "$workdir"

    echo "[${name}] Downloading from $url ..."

    # 根据 URL 后缀判断包类型
    case "$url" in
        *.tar.gz|*.tgz)
            local pkg_file="${name}.tar.gz"
            _download "$url" "$pkg_file"
            echo "[${name}] Detected archive type: tar.gz / tgz"
            tar -xzf "$pkg_file"
            local bin_path
            bin_path=$(find . -name "$bin_in_archive" -type f | head -n1)
            if [ -z "$bin_path" ]; then
                echo "[ERROR] Binary '$bin_in_archive' not found in archive"
                exit 1
            fi
            install -m 755 "$bin_path" "$install_path"
            ;;

        *.zip)
            local pkg_file="${name}.zip"
            _download "$url" "$pkg_file"
            echo "[${name}] Detected archive type: zip"
            if ! command -v unzip >/dev/null 2>&1; then
                echo "[ERROR] 'unzip' is required but not installed."
                exit 1
            fi
            unzip -q "$pkg_file" -d extracted
            local bin_path
            bin_path=$(find extracted -name "$bin_in_archive" -type f | head -n1)
            if [ -z "$bin_path" ]; then
                echo "[ERROR] Binary '$bin_in_archive' not found in archive"
                exit 1
            fi
            install -m 755 "$bin_path" "$install_path"
            ;;

        *.deb)
            local pkg_file="${name}.deb"
            _download "$url" "$pkg_file"
            echo "[${name}] Detected package type: deb"
            if command -v dpkg >/dev/null 2>&1; then
                dpkg -i "$pkg_file"
            elif command -v apt >/dev/null 2>&1; then
                apt install -y "$pkg_file"
            else
                echo "[ERROR] dpkg/apt not found, cannot install .deb package"
                exit 1
            fi
            # .deb 安装由包管理器处理，不需要手动 install
            echo "[${name}] Installed via dpkg: $pkg_file"
            return
            ;;

        *)
            # 假定是裸二进制（无扩展名或其它后缀）
            local pkg_file="${name}.bin"
            _download "$url" "$pkg_file"
            echo "[${name}] Detected package type: plain binary"
            install -m 755 "$pkg_file" "$install_path"
            ;;
    esac

    echo "[${name}] Installed to $install_path"
}

# =============================================================================
# 各软件安装
# =============================================================================

install_hy2() {
    if [ -z "$HY2_DOWNLOAD_URL" ]; then
        echo "[SKIP] HY2_DOWNLOAD_URL not set, skipping hysteria"
        return
    fi
    install_from_url "hysteria" "$HY2_DOWNLOAD_URL" "/usr/local/bin/hysteria" "hysteria"
    mkdir -p /usr/local/etc/hysteria
}

install_singbox() {
    if [ -z "$SINGBOX_DOWNLOAD_URL" ]; then
        echo "[SKIP] SINGBOX_DOWNLOAD_URL not set, skipping sing-box"
        return
    fi
    install_from_url "sing-box" "$SINGBOX_DOWNLOAD_URL" "/usr/local/bin/sing-box" "sing-box"
    mkdir -p /usr/local/etc/sing-box
}

install_mosdns() {
    if [ -z "$MOSDNS_DOWNLOAD_URL" ]; then
        echo "[SKIP] MOSDNS_DOWNLOAD_URL not set, skipping mosdns"
        return
    fi
    install_from_url "mosdns" "$MOSDNS_DOWNLOAD_URL" "/usr/local/bin/mosdns" "mosdns"
    mkdir -p /usr/local/etc/mosdns
}

install_nginx() {
    if command -v nginx >/dev/null 2>&1; then
        echo "[nginx] Already installed: $(which nginx)"
        return
    fi
    echo "[nginx] Installing via system package manager ..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y nginx
    elif command -v yum >/dev/null 2>&1; then
        yum install -y nginx
    elif command -v apk >/dev/null 2>&1; then
        apk add nginx
    else
        echo "[WARN] Unknown package manager, please install nginx manually"
    fi
}

# =============================================================================
# 执行安装
# =============================================================================
ACTION="${1:-proxies}"

case "$ACTION" in
    nginx)
        install_nginx
        echo "[DONE] Nginx installed."
        ;;
    proxies)
        install_hy2
        install_singbox
        install_mosdns
        echo "[DONE] Proxy binaries installed."
        ;;
    all)
        install_hy2
        install_singbox
        install_mosdns
        install_nginx
        echo "[DONE] All binaries installed."
        ;;
    *)
        echo "Usage: $0 [nginx|proxies|all]"
        exit 1
        ;;
esac

