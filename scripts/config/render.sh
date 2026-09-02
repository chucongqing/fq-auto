#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=validate.sh
source "$SCRIPT_DIR/validate.sh"

SERVER_ENV_FILE="$ROOT_DIR/.env"
CLIENT_ENV_FILE="$ROOT_DIR/.env.client"

SERVER_HY2_TEMPLATE="$ROOT_DIR/server/hy2/config/config.toml.template"
SERVER_NGINX_TEMPLATE="$ROOT_DIR/server/nginx/acme.conf.template"
SERVER_XRAY_TEMPLATE="$ROOT_DIR/server/xray/config/config.json.template"
SERVER_SINGBOX_TEMPLATE="$ROOT_DIR/server/sing-box/config/config.json.template"
CLIENT_SINGBOX_TEMPLATE="$ROOT_DIR/client/config/config.json.template"
CLIENT_HY2_TEMPLATE="$ROOT_DIR/client/hy2-config/config.yaml.template"

SERVER_HY2_OUTPUT="$ROOT_DIR/server/hy2/config/config.toml"
SERVER_NGINX_OUTPUT="$ROOT_DIR/server/nginx/conf/acme.conf"
SERVER_XRAY_OUTPUT="$ROOT_DIR/server/xray/config/config.json"
SERVER_SINGBOX_OUTPUT="$ROOT_DIR/server/sing-box/config/config.json"
CLIENT_SINGBOX_OUTPUT="$ROOT_DIR/client/config/config.json"
CLIENT_HY2_OUTPUT="$ROOT_DIR/client/hy2-config/config.yaml"

SERVER_XRAY_FILTER="$SCRIPT_DIR/filters/xray.jq"
SERVER_SINGBOX_FILTER="$SCRIPT_DIR/filters/sing-box-server.jq"
CLIENT_SINGBOX_FILTER="$SCRIPT_DIR/filters/sing-box-client.jq"

resolve_client_defaults() {
  CLIENT_VLESS_SERVER="${CLIENT_VLESS_SERVER:-${SERVER_ADDR:-}}"
  CLIENT_HY2_SERVER="${CLIENT_HY2_SERVER:-${SERVER_ADDR:-}}"
  CLIENT_TUIC_SERVER="${CLIENT_TUIC_SERVER:-${SERVER_ADDR:-}}"
  CLIENT_ANYTLS_SERVER="${CLIENT_ANYTLS_SERVER:-${SERVER_ADDR:-}}"

  CLIENT_HY2_SERVER_NAME="${CLIENT_HY2_SERVER_NAME:-$CLIENT_HY2_SERVER}"
  CLIENT_TUIC_SERVER_NAME="${CLIENT_TUIC_SERVER_NAME:-$CLIENT_TUIC_SERVER}"
  CLIENT_ANYTLS_SERVER_NAME="${CLIENT_ANYTLS_SERVER_NAME:-$CLIENT_ANYTLS_SERVER}"

  CLIENT_VLESS_PORT="${CLIENT_VLESS_PORT:-0}"
  CLIENT_TUIC_PORT="${CLIENT_TUIC_PORT:-0}"
  CLIENT_ANYTLS_PORT="${CLIENT_ANYTLS_PORT:-0}"
  CLIENT_WARP_PORT="${CLIENT_WARP_PORT:-0}"

  ENABLE_VLESS="${ENABLE_VLESS:-false}"
  ENABLE_HY2="${ENABLE_HY2:-false}"
  ENABLE_TUIC="${ENABLE_TUIC:-false}"
  ENABLE_ANYTLS="${ENABLE_ANYTLS:-false}"
  ENABLE_WARP="${ENABLE_WARP:-false}"

  export CLIENT_VLESS_SERVER CLIENT_HY2_SERVER CLIENT_TUIC_SERVER CLIENT_ANYTLS_SERVER
  export CLIENT_HY2_SERVER_NAME CLIENT_TUIC_SERVER_NAME CLIENT_ANYTLS_SERVER_NAME
  export CLIENT_VLESS_PORT CLIENT_TUIC_PORT CLIENT_ANYTLS_PORT CLIENT_WARP_PORT
  export ENABLE_VLESS ENABLE_HY2 ENABLE_TUIC ENABLE_ANYTLS ENABLE_WARP
}

resolve_client_default_outbound() {
  local tag
  ENABLED_TAGS=()
  for tag in vless hy2 tuic anytls; do
    case "$tag" in
      vless) [ "$ENABLE_VLESS" = true ] && ENABLED_TAGS+=("$tag") ;;
      hy2) [ "$ENABLE_HY2" = true ] && ENABLED_TAGS+=("$tag") ;;
      tuic) [ "$ENABLE_TUIC" = true ] && ENABLED_TAGS+=("$tag") ;;
      anytls) [ "$ENABLE_ANYTLS" = true ] && ENABLED_TAGS+=("$tag") ;;
    esac
  done

  CLIENT_DEFAULT_OUTBOUND="${ENABLED_TAGS[0]:-}"
  for tag in "${ENABLED_TAGS[@]}"; do
    if [ "${DEFAULT_OUTBOUND:-}" = "$tag" ]; then
      CLIENT_DEFAULT_OUTBOUND="$tag"
      break
    fi
  done
}

validate_client_json_output() {
  local file="$1"
  local tag enabled

  if ! jq -e --arg tag "$CLIENT_DEFAULT_OUTBOUND" '.outbounds | any(.tag == $tag)' "$file" >/dev/null; then
    echo "Error: DEFAULT_OUTBOUND does not exist in the rendered client outbounds." >&2
    return 1
  fi
  if ! jq -e '.route.rules[0] == {"action":"sniff"}' "$file" >/dev/null; then
    echo "Error: client route.rules must keep the sniff rule first." >&2
    return 1
  fi
  for tag in vless hy2 tuic anytls; do
    case "$tag" in
      vless) enabled="$ENABLE_VLESS" ;;
      hy2) enabled="$ENABLE_HY2" ;;
      tuic) enabled="$ENABLE_TUIC" ;;
      anytls) enabled="$ENABLE_ANYTLS" ;;
    esac
    if [ "$enabled" = true ] && ! jq -e --arg tag "$tag" '.outbounds | any(.tag == $tag)' "$file" >/dev/null; then
      echo "Error: enabled client protocol outbound is missing: $tag." >&2
      return 1
    fi
    if [ "$enabled" = false ] && jq -e --arg tag "$tag" '.outbounds | any(.tag == $tag)' "$file" >/dev/null; then
      echo "Error: disabled client protocol outbound remains: $tag." >&2
      return 1
    fi
  done
  if [ "$ENABLE_WARP" = false ] && jq -e '.outbounds | any(.tag == "warp")' "$file" >/dev/null; then
    echo "Error: WARP outbound remains while ENABLE_WARP=false." >&2
    return 1
  fi
  if [ "$ENABLE_WARP" = false ] && jq -e '.route.rules | any(.outbound == "warp")' "$file" >/dev/null; then
    echo "Error: a route rule still points to WARP while ENABLE_WARP=false." >&2
    return 1
  fi
  if [ "$ENABLE_WARP" = true ] && ! jq -e '.outbounds | any(.tag == "warp")' "$file" >/dev/null; then
    echo "Error: WARP outbound is missing while ENABLE_WARP=true." >&2
    return 1
  fi
}

render_server() {
  load_env "$SERVER_ENV_FILE" "make env"
  require_commands envsubst jq
  validate_server_env

  local staged

  staged="$(stage_path "$SERVER_HY2_OUTPUT")"
  render_text "$SERVER_ENV_FILE" "$SERVER_HY2_TEMPLATE" "$staged" \
    '${HY2_ADDR} ${HY2_PASSWORD} ${HY2_WARP_ADDR}'
  validate_hy2_toml "$staged" || return
  register_output "$staged" "$SERVER_HY2_OUTPUT"

  staged="$(stage_path "$SERVER_NGINX_OUTPUT")"
  render_text "$SERVER_ENV_FILE" "$SERVER_NGINX_TEMPLATE" "$staged" '${MYSITE}'
  register_output "$staged" "$SERVER_NGINX_OUTPUT"

  staged="$(stage_path "$SERVER_XRAY_OUTPUT")"
  render_json "$SERVER_ENV_FILE" "$SERVER_XRAY_TEMPLATE" "$SERVER_XRAY_FILTER" "$staged" \
    --argjson port "$(decimal_port "$XRAY_VLESS_PORT")" \
    --arg uuid "$XRAY_UUID" \
    --arg target "$XRAY_TARGET" \
    --arg servernames "$XRAY_SERVERNAMES" \
    --arg shortids "$XRAY_SHORTIDS" \
    --arg private_key "$XRAY_REALITY_PRIVATE_KEY" \
    --arg mldsa65_seed "$XRAY_REALITY_MLDSA65_SEED"
  register_output "$staged" "$SERVER_XRAY_OUTPUT"

  staged="$(stage_path "$SERVER_SINGBOX_OUTPUT")"
  render_json "$SERVER_ENV_FILE" "$SERVER_SINGBOX_TEMPLATE" "$SERVER_SINGBOX_FILTER" "$staged" \
    --argjson tuic_port "$(decimal_port "$SINGBOX_TUIC_PORT")" \
    --arg tuic_uuid "$SINGBOX_TUIC_UUID" \
    --arg tuic_password "$SINGBOX_TUIC_PASSWORD" \
    --arg site "$MYSITE" \
    --argjson anytls_port "$(decimal_port "$SINGBOX_ANYTLS_PORT")" \
    --arg anytls_username "$SINGBOX_ANYTLS_USERNAME" \
    --arg anytls_password "$SINGBOX_ANYTLS_PASSWORD" \
    --arg warp_server "${SINGBOX_WARP_SERVER:-}" \
    --argjson warp_port "$(decimal_port "${SINGBOX_WARP_PORT:-0}")"
  register_output "$staged" "$SERVER_SINGBOX_OUTPUT"
}

render_client() {
  load_env "$CLIENT_ENV_FILE" "make client-env"
  require_commands envsubst jq
  resolve_client_defaults
  resolve_client_default_outbound
  validate_client_env

  local staged

  staged="$(stage_path "$CLIENT_SINGBOX_OUTPUT")"
  render_json "$CLIENT_ENV_FILE" "$CLIENT_SINGBOX_TEMPLATE" "$CLIENT_SINGBOX_FILTER" "$staged" \
    --arg mixed_listen "$CLIENT_MIXED_LISTEN" \
    --argjson mixed_port "$(decimal_port "$CLIENT_MIXED_PORT")" \
    --arg vless_server "$CLIENT_VLESS_SERVER" \
    --argjson vless_port "$(decimal_port "$CLIENT_VLESS_PORT")" \
    --arg vless_uuid "${CLIENT_VLESS_UUID:-}" \
    --arg vless_server_name "${CLIENT_VLESS_SERVER_NAME:-}" \
    --arg vless_public_key "${CLIENT_VLESS_REALITY_PUBLIC_KEY:-}" \
    --arg vless_short_id "${CLIENT_VLESS_REALITY_SHORT_ID:-}" \
    --arg hy2_server "$CLIENT_HY2_SERVER" \
    --argjson hy2_port "$(decimal_port "$CLIENT_HY2_PORT")" \
    --arg hy2_password "$CLIENT_HY2_PASSWORD" \
    --arg hy2_server_name "$CLIENT_HY2_SERVER_NAME" \
    --arg tuic_server "$CLIENT_TUIC_SERVER" \
    --argjson tuic_port "$(decimal_port "$CLIENT_TUIC_PORT")" \
    --arg tuic_uuid "${CLIENT_TUIC_UUID:-}" \
    --arg tuic_password "${CLIENT_TUIC_PASSWORD:-}" \
    --arg tuic_server_name "$CLIENT_TUIC_SERVER_NAME" \
    --arg anytls_server "$CLIENT_ANYTLS_SERVER" \
    --argjson anytls_port "$(decimal_port "$CLIENT_ANYTLS_PORT")" \
    --arg anytls_password "${CLIENT_ANYTLS_PASSWORD:-}" \
    --arg anytls_server_name "$CLIENT_ANYTLS_SERVER_NAME" \
    --arg warp_server "${CLIENT_WARP_SERVER:-}" \
    --argjson warp_port "$(decimal_port "$CLIENT_WARP_PORT")" \
    --arg enable_vless "$ENABLE_VLESS" \
    --arg enable_hy2 "$ENABLE_HY2" \
    --arg enable_tuic "$ENABLE_TUIC" \
    --arg enable_anytls "$ENABLE_ANYTLS" \
    --arg enable_warp "$ENABLE_WARP" \
    --arg default_outbound "$CLIENT_DEFAULT_OUTBOUND" \
    --arg remote_dns "$REMOTE_DNS" \
    --arg local_dns "$LOCAL_DNS"
  validate_client_json_output "$staged"
  register_output "$staged" "$CLIENT_SINGBOX_OUTPUT"

  staged="$(stage_path "$CLIENT_HY2_OUTPUT")"
  render_text "$CLIENT_ENV_FILE" "$CLIENT_HY2_TEMPLATE" "$staged" \
    '${CLIENT_HY2_SERVER} ${CLIENT_HY2_PORT} ${CLIENT_HY2_PASSWORD} ${CLIENT_HY2_SOCKS5_PORT} ${CLIENT_HY2_HTTP_PORT} ${CLIENT_HY2_SERVER_NAME}'
  register_output "$staged" "$CLIENT_HY2_OUTPUT"
}

check_existing_outputs() {
  local file
  local missing=0
  local text_outputs=("$SERVER_HY2_OUTPUT" "$SERVER_NGINX_OUTPUT" "$CLIENT_HY2_OUTPUT")
  local json_outputs=("$SERVER_XRAY_OUTPUT" "$SERVER_SINGBOX_OUTPUT" "$CLIENT_SINGBOX_OUTPUT")

  for file in "${text_outputs[@]}" "${json_outputs[@]}"; do
    if [ ! -f "$file" ]; then
      echo "Error: generated output is missing: $file" >&2
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || return 1

  for file in "${json_outputs[@]}"; do
    validate_json "$file"
  done
  for file in "${text_outputs[@]}"; do
    if grep -Eq '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$file"; then
      echo "Error: unresolved template expression remains in $file." >&2
      return 1
    fi
  done
  validate_hy2_toml "$SERVER_HY2_OUTPUT" || return

  if ! grep -Fq '$host' "$SERVER_NGINX_OUTPUT"; then
    echo "Error: Nginx output no longer contains the literal \$host variable." >&2
    return 1
  fi
  if ! grep -Fq '$MAINPID' "$ROOT_DIR/systemd/nginx.service"; then
    echo "Error: static Nginx systemd unit no longer contains the literal \$MAINPID variable." >&2
    return 1
  fi
  validate_client_json_output "$CLIENT_SINGBOX_OUTPUT"
}

# Resolve the path a semantic check must read: the staged file while
# generating, or the committed output when re-checking with `check`. This
# guarantees checks never silently read the previous committed outputs.
semantic_path() {
  local mode="$1"
  local final="$2"
  local i

  if [ "$mode" = final ]; then
    printf '%s\n' "$final"
    return 0
  fi

  for i in "${!FINAL_OUTPUTS[@]}"; do
    if [ "${FINAL_OUTPUTS[$i]}" = "$final" ]; then
      printf '%s\n' "${STAGED_OUTPUTS[$i]}"
      return 0
    fi
  done
  echo "Error: no staged output registered for $final" >&2
  return 1
}

# Run `nginx -t` against an isolated config that includes the target acme.conf,
# so the check never depends on the machine's system Nginx configuration.
nginx_check_config() {
  local conf="$1"
  local conf_abs test_conf prefix_dir

  if [ ! -f "$conf" ]; then
    echo "Error: Nginx config to check not found: $conf" >&2
    return 1
  fi
  conf_abs="$(cd "$(dirname "$conf")" && pwd)/$(basename "$conf")"
  prefix_dir="$STAGE_DIR/nginx-prefix"
  test_conf="$STAGE_DIR/nginx-test.conf"
  mkdir -p "$prefix_dir"
  {
    echo 'events {}'
    echo 'http {'
    echo "    include $conf_abs;"
    echo '}'
  } > "$test_conf"
  nginx -t -c "$test_conf" -p "$prefix_dir/"
}

# Run available service semantic checks against staged (or committed) configs.
# Missing commands are reported with [SKIP]; the renderer never claims a
# semantic check ran when the command is absent. Failures abort before
# commit_staged_outputs, preserving the previous committed configuration.
validate_semantics() {
  local mode="$1"   # staged | final
  local scope="$2"  # server | client | both
  local server_singbox_path client_singbox_path server_xray_path nginx_path

  case "$scope" in
    server|both)
      server_singbox_path="$(semantic_path "$mode" "$SERVER_SINGBOX_OUTPUT")" || return
      server_xray_path="$(semantic_path "$mode" "$SERVER_XRAY_OUTPUT")" || return
      nginx_path="$(semantic_path "$mode" "$SERVER_NGINX_OUTPUT")" || return
      ;;
  esac
  case "$scope" in
    client|both)
      client_singbox_path="$(semantic_path "$mode" "$CLIENT_SINGBOX_OUTPUT")" || return
      ;;
  esac

  if command -v sing-box >/dev/null 2>&1; then
    case "$scope" in
      server|both) sing-box check -c "$server_singbox_path" ;;
    esac
    case "$scope" in
      client|both) sing-box check -c "$client_singbox_path" ;;
    esac
  else
    echo "[SKIP] sing-box semantic checks: sing-box command not found."
  fi

  if command -v xray >/dev/null 2>&1; then
    case "$scope" in
      server|both) xray run -test -config "$server_xray_path" ;;
    esac
  else
    echo "[SKIP] xray semantic check: xray command not found."
  fi

  if command -v nginx >/dev/null 2>&1; then
    case "$scope" in
      server|both) nginx_check_config "$nginx_path" ;;
    esac
  else
    echo "[SKIP] nginx semantic check: nginx command not found."
  fi
}

check_config() {
  require_commands jq
  load_env "$SERVER_ENV_FILE" "make env"
  validate_server_env
  load_env "$CLIENT_ENV_FILE" "make client-env"
  resolve_client_defaults
  resolve_client_default_outbound
  validate_client_env
  init_stage
  check_existing_outputs
  validate_semantics final both
  echo "Configuration checks passed."
}

main() {
  local action="${1:-}"
  case "$action" in
    server)
      init_stage
      render_server
      validate_semantics staged server
      commit_staged_outputs
      echo "Server configuration generated successfully."
      ;;
    client)
      init_stage
      render_client
      validate_semantics staged client
      commit_staged_outputs
      echo "Client configuration generated successfully."
      ;;
    all)
      init_stage
      render_server
      render_client
      validate_semantics staged both
      commit_staged_outputs
      echo "Server and client configurations generated successfully."
      ;;
    check)
      check_config
      ;;
    *)
      echo "Usage: $0 {server|client|all|check}" >&2
      return 2
      ;;
  esac
}

trap cleanup_stage EXIT
main "$@"
