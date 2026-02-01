#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
install-codex-notify.sh --url <windows_url> --token <token> [--host <host>] [--source <source>] [--env <path>] [--skip-hook]

Examples:
  ./install-codex-notify.sh --url http://192.168.101.40:9412/notify --token XXXXX --host 192.168.101.35
USAGE
}

WINDOWS_NOTIFY_URL="${WINDOWS_NOTIFY_URL:-}"
WINDOWS_NOTIFY_TOKEN="${WINDOWS_NOTIFY_TOKEN:-}"
CODEX_NOTIFY_HOST="${CODEX_NOTIFY_HOST:-}"
CODEX_NOTIFY_SOURCE="${CODEX_NOTIFY_SOURCE:-Codex}"
ENV_PATH="${ENV_PATH:-$HOME/bin/.env}"
SKIP_HOOK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --url) WINDOWS_NOTIFY_URL="$2"; shift 2;;
    --token) WINDOWS_NOTIFY_TOKEN="$2"; shift 2;;
    --host) CODEX_NOTIFY_HOST="$2"; shift 2;;
    --source) CODEX_NOTIFY_SOURCE="$2"; shift 2;;
    --env) ENV_PATH="$2"; shift 2;;
    --skip-hook) SKIP_HOOK=1; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

if [ -z "$WINDOWS_NOTIFY_URL" ] || [ -z "$WINDOWS_NOTIFY_TOKEN" ]; then
  echo "Missing --url or --token" >&2
  usage
  exit 1
fi

if [ -z "$CODEX_NOTIFY_HOST" ]; then
  CODEX_NOTIFY_HOST="$(hostname)"
fi

mkdir -p "$HOME/bin"

cat > "$HOME/bin/codex-notify.sh" <<'SH'
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

payload="$(cat)"
host="${CODEX_NOTIFY_HOST:-$(hostname)}"
source="${CODEX_NOTIFY_SOURCE:-Codex}"

curl -sS -X POST "$WINDOWS_NOTIFY_URL" \
  -H "Content-Type: application/json" \
  -H "X-Notify-Token: $WINDOWS_NOTIFY_TOKEN" \
  -H "X-Notify-Source: $source" \
  -H "X-Notify-Host: $host" \
  --data-binary "$payload" >/dev/null
SH

chmod +x "$HOME/bin/codex-notify.sh"

mkdir -p "$(dirname "$ENV_PATH")"
touch "$ENV_PATH"

upsert () {
  key="$1"; val="$2"
  if grep -q "^${key}=" "$ENV_PATH" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_PATH"
  else
    echo "${key}=${val}" >> "$ENV_PATH"
  fi
}

upsert WINDOWS_NOTIFY_URL "$WINDOWS_NOTIFY_URL"
upsert WINDOWS_NOTIFY_TOKEN "$WINDOWS_NOTIFY_TOKEN"
upsert NOTIFY_SERVER_TOKEN "$WINDOWS_NOTIFY_TOKEN"
upsert CODEX_NOTIFY_HOST "$CODEX_NOTIFY_HOST"
upsert CODEX_NOTIFY_SOURCE "$CODEX_NOTIFY_SOURCE"

if [ "$SKIP_HOOK" -eq 0 ]; then
  mkdir -p "$HOME/.codex"
  if [ -f "$HOME/.codex/config.toml" ]; then
    grep -q '^notify[[:space:]]*=' "$HOME/.codex/config.toml" || \
      echo 'notify = ["/bin/bash","-lc","~/bin/codex-notify.sh"]' >> "$HOME/.codex/config.toml"
  else
    echo 'notify = ["/bin/bash","-lc","~/bin/codex-notify.sh"]' > "$HOME/.codex/config.toml"
  fi
fi

echo "ok"
