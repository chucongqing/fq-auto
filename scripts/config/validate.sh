#!/usr/bin/env bash

# Validation helpers for the unified renderer. This file is sourced by
# render.sh after lib.sh.

validation_error() {
  echo "Error: $*" >&2
  return 1
}

require_nonempty() {
  local variable_name
  for variable_name in "$@"; do
    if [ -z "${!variable_name:-}" ]; then
      validation_error "$variable_name must be set and non-empty."
      return 1
    fi
  done
}

validate_bool() {
  local variable_name="$1"
  local value="${!variable_name:-}"
  case "$value" in
    true|false) ;;
    *) validation_error "$variable_name must be true or false." ;;
  esac
}

validate_port() {
  local variable_name="$1"
  local value="${!variable_name:-}"
  local port

  if [ -z "$value" ] || [[ "$value" == *[!0-9]* ]]; then
    validation_error "$variable_name must be a decimal port in the range 1..65535."
    return
  fi
  port=$((10#$value))
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    validation_error "$variable_name must be a decimal port in the range 1..65535."
  fi
}

validate_optional_port() {
  local variable_name="$1"
  if [ -n "${!variable_name:-}" ]; then
    validate_port "$variable_name"
  fi
}

validate_uuid() {
  local variable_name="$1"
  local value="${!variable_name:-}"
  if ! [[ "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; then
    validation_error "$variable_name must be a canonical UUID."
  fi
}

validate_safe_text() {
  local variable_name="$1"
  local value="${!variable_name:-}"
  if [[ "$value" == *'"'* || "$value" == *'\'* || "$value" == *'${'* || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    validation_error "$variable_name contains a quote, backslash, or line break that is unsafe for its text template."
  fi
}

validate_csv_values() {
  local variable_name="$1"
  local value="${!variable_name:-}"
  local item trimmed
  local -a items

  require_nonempty "$variable_name" || return
  IFS=',' read -r -a items <<< "$value"
  if [ "${#items[@]}" -eq 0 ]; then
    validation_error "$variable_name must contain at least one comma-separated value."
    return
  fi
  for item in "${items[@]}"; do
    trimmed="$(printf '%s' "$item" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ -z "$trimmed" ]; then
      validation_error "$variable_name must not contain empty values."
      return
    fi
  done
}

validate_short_ids() {
  local variable_name="$1"
  local value="${!variable_name:-}"
  local item trimmed
  local -a items

  validate_csv_values "$variable_name" || return
  IFS=',' read -r -a items <<< "$value"
  for item in "${items[@]}"; do
    trimmed="$(printf '%s' "$item" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if ! [[ "$trimmed" =~ ^[0-9a-fA-F]{1,16}$ ]] || (( ${#trimmed} % 2 != 0 )); then
      validation_error "$variable_name contains a short ID that is not an even-length hexadecimal value of 1..16 characters."
      return
    fi
  done
}

warn_example_value() {
  local variable_name="$1"
  case "${!variable_name:-}" in
    123|your-strong-password)
      echo "[WARN] $variable_name still uses an example value; replace it before deployment." >&2
      ;;
  esac
}

validate_server_env() {
  local variable_name
  local required=(
    MYSITE HY2_ADDR HY2_PASSWORD HY2_WARP_ADDR
    XRAY_UUID XRAY_VLESS_PORT XRAY_TARGET XRAY_SERVERNAMES XRAY_SHORTIDS
    XRAY_REALITY_PRIVATE_KEY XRAY_REALITY_MLDSA65_SEED
    SINGBOX_TUIC_PORT SINGBOX_TUIC_UUID SINGBOX_TUIC_PASSWORD
    SINGBOX_ANYTLS_PORT SINGBOX_ANYTLS_USERNAME SINGBOX_ANYTLS_PASSWORD
  )

  for variable_name in "${required[@]}"; do
    require_nonempty "$variable_name" || return
  done

  validate_port XRAY_VLESS_PORT || return
  validate_port SINGBOX_TUIC_PORT || return
  validate_port SINGBOX_ANYTLS_PORT || return
  if ! [[ "${HY2_ADDR:-}" =~ :[0-9]+$ ]]; then
    validation_error "HY2_ADDR must end with a decimal port, for example :10443."
    return
  fi
  local hy2_port="${HY2_ADDR##*:}"
  if [ "$hy2_port" -lt 1 ] || [ "$hy2_port" -gt 65535 ]; then
    validation_error "HY2_ADDR port must be in the range 1..65535."
    return
  fi

  validate_uuid XRAY_UUID || return
  validate_uuid SINGBOX_TUIC_UUID || return
  validate_csv_values XRAY_SERVERNAMES || return
  validate_short_ids XRAY_SHORTIDS || return
  validate_safe_text MYSITE || return
  validate_safe_text HY2_ADDR || return
  validate_safe_text XRAY_SERVERNAMES || return
  validate_safe_text HY2_PASSWORD || return
  validate_safe_text HY2_WARP_ADDR || return
  validate_optional_port SINGBOX_WARP_PORT || return

  if [ -n "${SINGBOX_WARP_SERVER:-}" ]; then
    require_nonempty SINGBOX_WARP_SERVER || return
    require_nonempty SINGBOX_WARP_PORT || return
    validate_port SINGBOX_WARP_PORT || return
  fi

  for variable_name in HY2_PASSWORD SINGBOX_TUIC_PASSWORD SINGBOX_ANYTLS_PASSWORD XRAY_REALITY_PRIVATE_KEY XRAY_REALITY_MLDSA65_SEED; do
    warn_example_value "$variable_name"
  done
}

validate_client_env() {
  local variable_name
  local enabled_count=0

  # SERVER_ADDR is optional: resolve_client_defaults already fell back to it for
  # protocols that did not set their own address. Each enabled protocol is
  # validated below against the resolved value, so an empty SERVER_ADDR is fine
  # when every enabled protocol sets its own address. The standalone Hysteria 2
  # client always needs a HY2 address.
  for variable_name in ENABLE_VLESS ENABLE_HY2 ENABLE_TUIC ENABLE_ANYTLS ENABLE_WARP; do
    validate_bool "$variable_name" || return
  done

  for variable_name in ENABLE_VLESS ENABLE_HY2 ENABLE_TUIC ENABLE_ANYTLS; do
    if [ "${!variable_name}" = true ]; then
      enabled_count=$((enabled_count + 1))
    fi
  done
  if [ "$enabled_count" -eq 0 ]; then
    validation_error "at least one of ENABLE_VLESS, ENABLE_HY2, ENABLE_TUIC, ENABLE_ANYTLS must be true."
    return
  fi

  require_nonempty CLIENT_MIXED_LISTEN || return
  validate_port CLIENT_MIXED_PORT || return
  validate_port CLIENT_HY2_PORT || return
  validate_port CLIENT_HY2_SOCKS5_PORT || return
  validate_port CLIENT_HY2_HTTP_PORT || return
  require_nonempty CLIENT_HY2_SERVER || return
  require_nonempty CLIENT_HY2_PASSWORD || return
  require_nonempty CLIENT_HY2_SERVER_NAME || return
  validate_safe_text CLIENT_HY2_SERVER || return
  validate_safe_text CLIENT_HY2_PASSWORD || return
  validate_safe_text CLIENT_HY2_SERVER_NAME || return

  if [ "${ENABLE_VLESS}" = true ]; then
    require_nonempty CLIENT_VLESS_SERVER CLIENT_VLESS_PORT CLIENT_VLESS_UUID \
      CLIENT_VLESS_REALITY_PUBLIC_KEY CLIENT_VLESS_REALITY_SHORT_ID CLIENT_VLESS_SERVER_NAME || return
    validate_port CLIENT_VLESS_PORT || return
    validate_uuid CLIENT_VLESS_UUID || return
    require_nonempty CLIENT_VLESS_REALITY_SHORT_ID || return
    if ! [[ "$CLIENT_VLESS_REALITY_SHORT_ID" =~ ^[0-9a-fA-F]{1,16}$ ]] || (( ${#CLIENT_VLESS_REALITY_SHORT_ID} % 2 != 0 )); then
      validation_error "CLIENT_VLESS_REALITY_SHORT_ID must be an even-length hexadecimal value of 1..16 characters."
      return
    fi
  fi
  if [ "${ENABLE_HY2}" = true ]; then
    require_nonempty CLIENT_HY2_SERVER CLIENT_HY2_PASSWORD CLIENT_HY2_SERVER_NAME || return
  fi
  if [ "${ENABLE_TUIC}" = true ]; then
    require_nonempty CLIENT_TUIC_SERVER CLIENT_TUIC_PORT CLIENT_TUIC_UUID CLIENT_TUIC_PASSWORD CLIENT_TUIC_SERVER_NAME || return
    validate_port CLIENT_TUIC_PORT || return
    validate_uuid CLIENT_TUIC_UUID || return
  fi
  if [ "${ENABLE_ANYTLS}" = true ]; then
    require_nonempty CLIENT_ANYTLS_SERVER CLIENT_ANYTLS_PORT CLIENT_ANYTLS_PASSWORD CLIENT_ANYTLS_SERVER_NAME || return
    validate_port CLIENT_ANYTLS_PORT || return
  fi

  if [ "${ENABLE_WARP}" = true ]; then
    require_nonempty CLIENT_WARP_SERVER CLIENT_WARP_PORT || return
    validate_port CLIENT_WARP_PORT || return
  fi

  if [ -n "${DEFAULT_OUTBOUND:-}" ]; then
    case "$DEFAULT_OUTBOUND" in
      vless|hy2|tuic|anytls) ;;
      *) validation_error "DEFAULT_OUTBOUND must be vless, hy2, tuic, or anytls."; return ;;
    esac
  fi
  require_nonempty REMOTE_DNS LOCAL_DNS || return

  for variable_name in CLIENT_VLESS_PASSWORD CLIENT_HY2_PASSWORD CLIENT_TUIC_PASSWORD CLIENT_ANYTLS_PASSWORD; do
    warn_example_value "$variable_name"
  done
}

validate_rendered_text() {
  local file="$1"
  local variables="$2"
  local variable_expression
  for variable_expression in $variables; do
    if grep -Fq -- "$variable_expression" "$file"; then
      echo "Error: unresolved template variable $variable_expression remains in $file." >&2
      return 1
    fi
  done
}

validate_json() {
  local file="$1"
  if ! jq empty "$file" >/dev/null; then
    echo "Error: invalid JSON output: $file" >&2
    return 1
  fi
}

# Lightweight structural check for the generated Hysteria 2 TOML. This is NOT a
# full TOML parser: it only verifies that the known string fields the renderer
# injects are double-quoted, which catches unquoted leaks such as
# `listen = :10443`. Hysteria 2's CLI has no stable check-only flag, so no
# external tool is invoked here.
validate_hy2_toml() {
  local file="$1"
  local line

  if [ ! -f "$file" ]; then
    validation_error "HY2 TOML output not found: $file"
    return
  fi
  while IFS= read -r line; do
    case "$line" in
      listen\ =*|password\ =*|addr\ =*)
        if ! [[ "$line" =~ ^[[:space:]]*[A-Za-z0-9_.]+[[:space:]]*=[[:space:]]*\".*\"[[:space:]]*$ ]]; then
          validation_error "HY2 TOML string field is not a double-quoted string: $line"
          return
        fi
        ;;
    esac
  done < "$file"
}
