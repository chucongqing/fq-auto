#!/usr/bin/env bash

# Shared helpers for configuration rendering. This file is sourced by render.sh.

CONFIG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$CONFIG_SCRIPT_DIR/../.." && pwd)"

STAGE_DIR=""
STAGED_OUTPUTS=()
FINAL_OUTPUTS=()

die() {
  echo "Error: $*" >&2
  return 1
}

require_commands() {
  local command_name
  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "Error: required command '$command_name' was not found." >&2
      case "$command_name" in
        envsubst) echo "Please install gettext-base." >&2 ;;
        jq) echo "Please install jq." >&2 ;;
      esac
      return 1
    fi
  done
}

load_env() {
  local env_file="$1"
  local init_hint="$2"

  if [ ! -f "$env_file" ]; then
    echo "Error: required environment file not found: $env_file" >&2
    echo "Please run '$init_hint' and configure it first." >&2
    return 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
}

# Keep this helper available for callers that need to inspect an env file. The
# renderer itself passes explicit variable lists to envsubst instead.
env_variable_list() {
  local env_file="$1"
  awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/{printf "${%s} ", $1}' "$env_file"
}

init_stage() {
  STAGE_DIR="$(mktemp -d "$ROOT_DIR/.render.XXXXXX")"
  STAGED_OUTPUTS=()
  FINAL_OUTPUTS=()
}

cleanup_stage() {
  if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
    rm -rf -- "$STAGE_DIR"
  fi
  STAGE_DIR=""
}

stage_path() {
  local output="$1"
  local relative

  case "$output" in
    "$ROOT_DIR"/*) relative="${output#"$ROOT_DIR"/}" ;;
    *) echo "Error: output path is outside the repository: $output" >&2; return 1 ;;
  esac

  printf '%s/%s\n' "$STAGE_DIR" "$relative"
}

register_output() {
  STAGED_OUTPUTS+=("$1")
  FINAL_OUTPUTS+=("$2")
}

decimal_port() {
  local value="$1"
  printf '%d\n' "$((10#$value))"
}

render_text() {
  local env_file="$1"
  local template="$2"
  local output="$3"
  local variables="$4"
  local temp_file

  : "$env_file"
  if [ ! -f "$template" ]; then
    echo "Error: template not found: $template" >&2
    return 1
  fi

  mkdir -p "$(dirname "$output")"
  temp_file="$(mktemp "${output}.tmp.XXXXXX")"

  if ! envsubst "$variables" < "$template" > "$temp_file"; then
    rm -f -- "$temp_file"
    return 1
  fi
  if ! validate_rendered_text "$temp_file" "$variables"; then
    rm -f -- "$temp_file"
    return 1
  fi

  mv -f -- "$temp_file" "$output"
}

render_json() {
  local env_file="$1"
  local template="$2"
  local filter="$3"
  local output="$4"
  local temp_file
  shift 4

  : "$env_file"
  if [ ! -f "$template" ]; then
    echo "Error: template not found: $template" >&2
    return 1
  fi
  if [ ! -f "$filter" ]; then
    echo "Error: jq filter not found: $filter" >&2
    return 1
  fi

  mkdir -p "$(dirname "$output")"
  temp_file="$(mktemp "${output}.tmp.XXXXXX")"

  if ! jq "$@" -f "$filter" "$template" > "$temp_file"; then
    rm -f -- "$temp_file"
    return 1
  fi
  if ! validate_json "$temp_file"; then
    rm -f -- "$temp_file"
    return 1
  fi

  mv -f -- "$temp_file" "$output"
}

# Commit all staged files only after every target has rendered and validated.
# Existing generated files are backed up so a rare mid-commit failure can be
# rolled back instead of leaving a partially updated configuration set.
commit_staged_outputs() {
  local backup_dir="$STAGE_DIR/backups"
  local -a existed=()
  local -a committed=()
  local i j staged final backup

  mkdir -p "$backup_dir"
  for i in "${!STAGED_OUTPUTS[@]}"; do
    staged="${STAGED_OUTPUTS[$i]}"
    final="${FINAL_OUTPUTS[$i]}"
    backup="$backup_dir/$i"
    if [ ! -f "$staged" ]; then
      echo "Error: staged output disappeared: $staged" >&2
      return 1
    fi
    mkdir -p "$(dirname "$final")"
    if [ -e "$final" ]; then
      cp -p -- "$final" "$backup"
      existed[$i]=1
    else
      existed[$i]=0
    fi
  done

  for i in "${!STAGED_OUTPUTS[@]}"; do
    staged="${STAGED_OUTPUTS[$i]}"
    final="${FINAL_OUTPUTS[$i]}"
    if ! mv -f -- "$staged" "$final"; then
      echo "Error: failed to replace $final; rolling back rendered files." >&2
      for j in "${committed[@]}"; do
        final="${FINAL_OUTPUTS[$j]}"
        backup="$backup_dir/$j"
        if [ "${existed[$j]}" = 1 ]; then
          mv -f -- "$backup" "$final"
        else
          rm -f -- "$final"
        fi
      done
      return 1
    fi
    committed+=("$i")
  done
}
