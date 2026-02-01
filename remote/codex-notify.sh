#!/usr/bin/env bash
set -euo pipefail

: "${NOTIFY_CONFIG_PATH:=}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

load_env_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == export\ * ]] && line="${line#export }"
    [[ "$line" != *"="* ]] && continue
    local key="${line%%=*}"
    local val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ "$val" == \"*\" && "$val" == *\" ]]; then val="${val:1:-1}"; fi
    if [[ "$val" == \'*\' && "$val" == *\' ]]; then val="${val:1:-1}"; fi
    if [ -z "${!key:-}" ]; then
      export "$key=$val"
    fi
  done < "$file"
}

load_yaml_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* || "$line" == "---" ]] && continue
    [[ "$line" != *":"* ]] && continue
    local key="${line%%:*}"
    local val="${line#*:}"
    key="${key%"${key##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ "$val" == \"*\" && "$val" == *\" ]]; then val="${val:1:-1}"; fi
    if [[ "$val" == \'*\' && "$val" == *\' ]]; then val="${val:1:-1}"; fi
    if [ -z "${!key:-}" ]; then
      export "$key=$val"
    fi
  done < "$file"
}

config_candidates=()
if [ -n "$NOTIFY_CONFIG_PATH" ]; then
  config_candidates+=("$NOTIFY_CONFIG_PATH")
fi
config_candidates+=(
  "$script_dir/.env"
  "$script_dir/notify.env"
  "$script_dir/notify.yml"
  "$script_dir/notify.yaml"
  ".env"
  "notify.yml"
  "notify.yaml"
)

for p in "${config_candidates[@]}"; do
  [ -f "$p" ] || continue
  case "$p" in
    *.yml|*.yaml) load_yaml_file "$p" ;;
    *) load_env_file "$p" ;;
  esac
done

if [ -z "${WINDOWS_NOTIFY_TOKEN:-}" ] && [ -n "${NOTIFY_SERVER_TOKEN:-}" ]; then
  WINDOWS_NOTIFY_TOKEN="$NOTIFY_SERVER_TOKEN"
fi

: "${WINDOWS_NOTIFY_URL:?missing WINDOWS_NOTIFY_URL}"
: "${WINDOWS_NOTIFY_TOKEN:?missing WINDOWS_NOTIFY_TOKEN}"

payload="${1:-}"
if [ -z "$payload" ] && [ ! -t 0 ]; then
  if IFS= read -r -t 0.2 payload; then
    :
  fi
fi
if [ -z "$payload" ]; then
  payload="{}"
fi
host="${CODEX_NOTIFY_HOST:-$(hostname)}"
host_name="${CODEX_NOTIFY_NAME:-}"
source="${CODEX_NOTIFY_SOURCE:-Codex}"

curl -sS -X POST "$WINDOWS_NOTIFY_URL" \
  -H "Content-Type: application/json; charset=utf-8" \
  -H "X-Notify-Token: $WINDOWS_NOTIFY_TOKEN" \
  -H "X-Notify-Source: $source" \
  -H "X-Notify-Host: $host" \
  ${host_name:+-H "X-Notify-Host-Name: $host_name"} \
  --data-binary "$payload" >/dev/null
