#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Runs the .NET 10 Razor app - backend and UI, self-contained.
# macOS, Linux, WSL and Git Bash.
#
#   ./start.sh                 http://localhost:5080
#   ./start.sh --port 5090     a different port
#   ./start.sh --mock          against the offline mock, no Azure needed
#   ./start.sh --no-browser    do not open a browser
#
# Configuration comes from ../.env (shared with the Python stack), or from
# dotnet/.env if you want this app pointed somewhere the other one is not.
#
# Written for bash 3.2, the version macOS ships.
# ─────────────────────────────────────────────────────────────────────
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PORT=5080
MOCK_PORT=5290
FORCE_MOCK=0
OPEN_BROWSER=1
MOCK_PID=""

if [ -t 1 ]; then
  C_HEAD=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'
  C_ERR=$'\033[31m'; C_DIM=$'\033[90m'; C_OFF=$'\033[0m'
else
  C_HEAD=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_OFF=""
fi
step() { printf '\n%s==> %s%s\n' "$C_HEAD" "$1" "$C_OFF"; }
ok()   { printf '    %s%s%s\n' "$C_OK" "$1" "$C_OFF"; }
note() { printf '    %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }
warn() { printf '    %s! %s%s\n' "$C_WARN" "$1" "$C_OFF"; }
die()  { printf '\n%serror: %s%s\n\n' "$C_ERR" "$1" "$C_OFF" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --mock)        FORCE_MOCK=1 ;;
    --no-browser)  OPEN_BROWSER=0 ;;
    --port)        shift; PORT="${1:-}"; [ -n "$PORT" ] || die "--port needs a number" ;;
    -h|--help)     sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
  shift
done

command -v dotnet >/dev/null 2>&1 \
  || die "The .NET SDK was not found. Install .NET 10 from https://dot.net, or 'brew install --cask dotnet-sdk'."

find_python() {
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 \
       && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
      echo "$candidate"; return 0
    fi
  done
  return 1
}

# The .NET app reads configuration from more places than a .env: appsettings.json,
# appsettings.Development.json and user-secrets all carry it too. The launcher must
# know about all of them, because the mock fallback works by exporting environment
# variables - and those outrank appsettings, so guessing wrong silently replaces
# real configuration with the mock.
json_sets_endpoint() {
  [ -f "$1" ] && grep -qE '"AI_ENDPOINT"[[:space:]]*:[[:space:]]*"[^"]+"' "$1" 2>/dev/null
}

user_secrets_file() {
  local id
  id="$(grep -oE '<UserSecretsId>[^<]+</UserSecretsId>' "$HERE/AiGatewayDemo/AiGatewayDemo.csproj" 2>/dev/null \
        | sed -e 's/<UserSecretsId>//' -e 's|</UserSecretsId>||')"
  [ -n "$id" ] || return 1
  if [ -n "${APPDATA:-}" ]; then
    echo "$APPDATA/Microsoft/UserSecrets/$id/secrets.json"
  else
    echo "$HOME/.microsoft/usersecrets/$id/secrets.json"
  fi
}

is_configured() {
  [ -n "${AI_ENDPOINT:-}" ] && return 0
  [ -f "$ROOT/.env" ] && return 0
  [ -f "$HERE/.env" ] && return 0
  json_sets_endpoint "$HERE/AiGatewayDemo/appsettings.Development.json" && return 0
  json_sets_endpoint "$HERE/AiGatewayDemo/appsettings.json" && return 0
  json_sets_endpoint "$(user_secrets_file 2>/dev/null)" && return 0
  return 1
}

mock_is_up() {
  "$1" - "$MOCK_PORT" <<'PY' >/dev/null 2>&1
import sys, urllib.error, urllib.request
try:
    urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/", timeout=1).read()
except urllib.error.HTTPError as exc:      # a 404 from the mock still means "up"
    exc.read()
except Exception:
    sys.exit(1)
PY
}

start_mock() {
  local python
  python="$(find_python)" || die "Python 3.10+ is needed to run the offline mock."

  # The other stack may already be running one. Reuse it rather than starting a
  # second that cannot bind - which would look like it worked and leave a corpse.
  if mock_is_up "$python"; then
    ok "Reusing the mock already listening on :$MOCK_PORT"
    return 0
  fi

  step "Starting the mock Azure AI stack on :$MOCK_PORT"
  "$python" "$ROOT/scripts/mock-azure-ai.py" "$MOCK_PORT" &
  MOCK_PID=$!

  local attempt=0
  while [ $attempt -lt 20 ]; do
    if mock_is_up "$python"; then
      ok "Mock ready. 'bomb', 'attack', 'kill' or 'weapon' in a prompt trips the guardrail."
      note 'The mock is not an Azure host, so the page will report a "custom" connection.'
      return 0
    fi
    attempt=$((attempt + 1)); sleep 0.5
  done
  die "The mock did not start. Is port $MOCK_PORT already in use?"
}

cleanup() {
  if [ -n "$MOCK_PID" ] && kill -0 "$MOCK_PID" 2>/dev/null; then kill "$MOCK_PID" 2>/dev/null; fi
}
trap cleanup EXIT INT TERM

# ── configuration ────────────────────────────────────────────────────
if [ "$FORCE_MOCK" -eq 1 ] || ! is_configured; then
  if [ "$FORCE_MOCK" -eq 0 ]; then
    warn "No AI_ENDPOINT in .env, appsettings, user-secrets or the environment."
    warn "Falling back to the offline mock. Run scripts/03-set-local-env.ps1 for real resources."
  else
    note "--mock overrides any configuration; the page will say the endpoint came"
    note "from an environment variable."
  fi
  start_mock
  MOCK_URL="http://127.0.0.1:$MOCK_PORT"
  export AI_ENDPOINT="$MOCK_URL"
  export AI_KEY="mock-gateway-key"
  export AI_KEY_HEADER="api-key"
  export AI_CHAT_MODEL="gpt-4o"
  export AI_EMBEDDING_MODEL="text-embedding-3-small"
  export CONTENT_SAFETY_ENDPOINT="$MOCK_URL"
  export CONTENT_SAFETY_KEY="mock-safety-key"
  export DOC_INTEL_ENDPOINT="$MOCK_URL"
  export DOC_INTEL_KEY="mock-docintel-key"
elif [ -n "${AI_ENDPOINT:-}" ]; then
  note "Configuration: AI_ENDPOINT from the environment"
elif [ -f "$HERE/.env" ]; then
  note "Configuration: dotnet/.env (overrides the shared one)"
elif [ -f "$ROOT/.env" ]; then
  note "Configuration: .env at the repo root"
else
  note "Configuration: appsettings / user-secrets - the app reports which on the page"
fi

export ASPNETCORE_URLS="http://localhost:$PORT"

if [ "$OPEN_BROWSER" -eq 1 ]; then
  (
    sleep 4
    if command -v open >/dev/null 2>&1; then open "http://localhost:$PORT"
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "http://localhost:$PORT"
    fi
  ) >/dev/null 2>&1 &
fi

step ".NET 10 Razor app on http://localhost:$PORT"
note "The Python stack runs separately, on its own port - see python/start.sh"
dotnet run --project "$HERE/AiGatewayDemo"
