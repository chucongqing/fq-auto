#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/.env.client"
TEMPLATE_FILE="$ROOT_DIR/client/config/config.json.template"
OUTPUT_FILE="$ROOT_DIR/client/config/config.json"

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: .env.client file not found!"
  echo "Please run 'make client-env' and configure .env.client first."
  exit 1
fi

if ! command -v envsubst >/dev/null 2>&1; then
  echo "Error: envsubst not found. Please install gettext-base first."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq not found. jq is required to apply client protocol switches."
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

# Resolve per-protocol server addresses (fallback to default SERVER_ADDR).
CLIENT_VLESS_SERVER="${CLIENT_VLESS_SERVER:-${SERVER_ADDR:-}}"
CLIENT_HY2_SERVER="${CLIENT_HY2_SERVER:-${SERVER_ADDR:-}}"
CLIENT_TUIC_SERVER="${CLIENT_TUIC_SERVER:-${SERVER_ADDR:-}}"
CLIENT_ANYTLS_SERVER="${CLIENT_ANYTLS_SERVER:-${SERVER_ADDR:-}}"

# Resolve per-protocol TLS server names (fallback to corresponding server address).
CLIENT_HY2_SERVER_NAME="${CLIENT_HY2_SERVER_NAME:-$CLIENT_HY2_SERVER}"
CLIENT_TUIC_SERVER_NAME="${CLIENT_TUIC_SERVER_NAME:-$CLIENT_TUIC_SERVER}"
CLIENT_ANYTLS_SERVER_NAME="${CLIENT_ANYTLS_SERVER_NAME:-$CLIENT_ANYTLS_SERVER}"

# Keep the complete template valid while jq removes disabled protocol blocks.
# Enabled protocols still need their real values in .env.client.
CLIENT_VLESS_PORT="${CLIENT_VLESS_PORT:-0}"
CLIENT_HY2_PORT="${CLIENT_HY2_PORT:-0}"
CLIENT_TUIC_PORT="${CLIENT_TUIC_PORT:-0}"
CLIENT_ANYTLS_PORT="${CLIENT_ANYTLS_PORT:-0}"
CLIENT_MIXED_PORT="${CLIENT_MIXED_PORT:-0}"
CLIENT_WARP_PORT="${CLIENT_WARP_PORT:-0}"
export CLIENT_VLESS_PORT CLIENT_HY2_PORT CLIENT_TUIC_PORT CLIENT_ANYTLS_PORT
export CLIENT_MIXED_PORT CLIENT_WARP_PORT
export CLIENT_VLESS_SERVER CLIENT_HY2_SERVER CLIENT_TUIC_SERVER CLIENT_ANYTLS_SERVER
export CLIENT_HY2_SERVER_NAME CLIENT_TUIC_SERVER_NAME CLIENT_ANYTLS_SERVER_NAME

ENABLED_TAGS=()
if [ "${ENABLE_VLESS:-false}" = "true" ]; then ENABLED_TAGS+=("vless"); fi
if [ "${ENABLE_HY2:-false}" = "true" ]; then ENABLED_TAGS+=("hy2"); fi
if [ "${ENABLE_TUIC:-false}" = "true" ]; then ENABLED_TAGS+=("tuic"); fi
if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then ENABLED_TAGS+=("anytls"); fi

if [ ${#ENABLED_TAGS[@]} -eq 0 ]; then
  echo "Error: No protocols enabled. Please enable at least one protocol in .env.client"
  exit 1
fi

# The old generator falls back to auto when DEFAULT_OUTBOUND is disabled/unknown.
CLIENT_DEFAULT_OUTBOUND="auto"
for tag in "${ENABLED_TAGS[@]}"; do
  if [ "${DEFAULT_OUTBOUND:-}" = "$tag" ]; then
    CLIENT_DEFAULT_OUTBOUND="$tag"
    break
  fi
done
export CLIENT_DEFAULT_OUTBOUND

# Parse DNS values into the sing-box DNS server object accepted by the template.
parse_dns_server() {
  local tag="$1"
  local dns_val="$2"
  local detour="$3"
  local type=""
  local server=""
  local server_port=""
  local path=""

  if [[ "$dns_val" =~ ^(tls|https|quic|h3|tcp|udp)://([^/]+)(/.*)?$ ]]; then
    type="${BASH_REMATCH[1]}"
    local host_port="${BASH_REMATCH[2]}"
    path="${BASH_REMATCH[3]}"
    [ "$path" = "/" ] && path=""

    if [[ "$host_port" =~ ^([^:]+):([0-9]+)$ ]]; then
      server="${BASH_REMATCH[1]}"
      server_port="${BASH_REMATCH[2]}"
    else
      server="$host_port"
    fi
  else
    type="udp"
    if [[ "$dns_val" =~ ^([^:]+):([0-9]+)$ ]]; then
      server="${BASH_REMATCH[1]}"
      server_port="${BASH_REMATCH[2]}"
    else
      server="$dns_val"
    fi
  fi

  local json="      {\n        \"tag\": \"$tag\",\n        \"type\": \"$type\",\n        \"server\": \"$server\""
  if [ -n "$server_port" ]; then
    json="$json,\n        \"server_port\": $server_port"
  fi
  if [ -n "$path" ]; then
    json="$json,\n        \"path\": \"$path\""
  fi
  if [ -n "$detour" ]; then
    json="$json,\n        \"detour\": \"$detour\""
  fi
  json="$json\n      }"
  printf -v "$4" '%b' "$json"
}

parse_dns_server remote-dns "${REMOTE_DNS:-}" proxy REMOTE_DNS_JSON
parse_dns_server local-dns "${LOCAL_DNS:-}" "" LOCAL_DNS_JSON
export REMOTE_DNS_JSON LOCAL_DNS_JSON

mkdir -p "$ROOT_DIR/client/config"
RENDERED_FILE="$(mktemp)"
trap 'rm -f "$RENDERED_FILE"' EXIT

# Keep envsubst restricted to variables declared by .env.client plus derived values.
VARS_EXTRACTED="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" | cut -d= -f1 | sed 's/^/\$/')"
VARS_EXTRACTED="$VARS_EXTRACTED \$REMOTE_DNS_JSON \$LOCAL_DNS_JSON \$CLIENT_DEFAULT_OUTBOUND"
envsubst "$VARS_EXTRACTED" < "$TEMPLATE_FILE" > "$RENDERED_FILE"

# Apply ENABLE_* and ENABLE_WARP without putting conditional JSON construction in Bash.
jq \
  --arg enable_vless "${ENABLE_VLESS:-false}" \
  --arg enable_hy2 "${ENABLE_HY2:-false}" \
  --arg enable_tuic "${ENABLE_TUIC:-false}" \
  --arg enable_anytls "${ENABLE_ANYTLS:-false}" \
  --arg enable_warp "${ENABLE_WARP:-false}" \
  --arg default_outbound "$CLIENT_DEFAULT_OUTBOUND" \
  '
    def enabled($tag):
      ($tag == "vless" and $enable_vless == "true") or
      ($tag == "hy2" and $enable_hy2 == "true") or
      ($tag == "tuic" and $enable_tuic == "true") or
      ($tag == "anytls" and $enable_anytls == "true");

    .outbounds |= map(
      if .tag == "proxy" or .tag == "auto" then
        .outbounds |= map(select(. == "auto" or enabled(.))) |
        if .tag == "proxy" then .default = $default_outbound else . end
      elif (.tag == "vless" or .tag == "hy2" or .tag == "tuic" or .tag == "anytls") and
           (enabled(.tag) | not) then
        empty
      elif .tag == "warp" and $enable_warp != "true" then
        empty
      else
        .
      end
    ) |
    .route.rules |= map(select($enable_warp == "true" or .outbound != "warp"))
  ' "$RENDERED_FILE" > "$OUTPUT_FILE"

echo "Client sing-box config generated successfully at: $OUTPUT_FILE"

# ============================================================
# Generate Hysteria 2 client config (standalone client mode)
# ============================================================
HY2_CONFIG_DIR="$ROOT_DIR/client/hy2-config"
HY2_OUTPUT_FILE="$HY2_CONFIG_DIR/config.yaml"
HY2_TEMPLATE_FILE="$ROOT_DIR/client/hy2-config/config.yaml.template"
mkdir -p "$HY2_CONFIG_DIR"
envsubst "$VARS_EXTRACTED" < "$HY2_TEMPLATE_FILE" > "$HY2_OUTPUT_FILE"

echo "Hysteria 2 client config generated successfully at: $HY2_OUTPUT_FILE"
echo "JSON validation passed."
