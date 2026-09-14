#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Runs the Python / FastAPI app - backend and UI, self-contained.
# macOS, Linux, WSL and Git Bash.
#
#   ./start.sh                 http://localhost:8080
#   ./start.sh --port 8090     a different port
#   ./start.sh --mock          against the offline mock, no Azure needed
#   ./start.sh --reload        uvicorn auto-reload
#   ./start.sh --no-browser    do not open a browser
#
# Configuration comes from ../.env (shared with the .NET stack), or from
# python/.env if you want this app pointed somewhere the other one is not.
#
# Written for bash 3.2, the version macOS ships.
# ─────────────────────────────────────────────────────────────────────
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PORT=8080
MOCK_PORT=5290
FORCE_MOCK=0
OPEN_BROWSER=1
RELOAD=0
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
    --reload)      RELOAD=1 ;;
    --port)        shift; PORT="${1:-}"; [ -n "$PORT" ] || die "--port needs a number" ;;
    -h|--help)     sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
  shift
done

find_python() {
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 \
       && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
      echo "$candidate"; return 0
    fi
  done
  return 1
}

PYTHON="$(find_python)" || die "Python 3.10+ not found. Install it from https://python.org, or 'brew install python'."

venv_python() {
  # bin/ on Unix, Scripts/ on Windows - so this also works in Git Bash.
  if [ -x "$HERE/.venv/bin/python" ]; then echo "$HERE/.venv/bin/python"
  elif [ -x "$HERE/.venv/Scripts/python.exe" ]; then echo "$HERE/.venv/Scripts/python.exe"
  else echo ""; fi
}

if [ -z "$(venv_python)" ]; then
  step "Creating python/.venv"
  "$PYTHON" -m venv "$HERE/.venv" || die "Could not create the virtual environment."
fi

VPY="$(venv_python)"
[ -n "$VPY" ] || die "The virtual environment looks broken. Delete python/.venv and try again."

step "Installing requirements"
"$VPY" -m pip install --quiet --disable-pip-version-check -r "$HERE/requirements.txt" \
  || die "pip install failed."
ok "Up to date."

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
  # The other stack may already be running one. Reuse it rather than starting a
  # second that cannot bind - which would look like it worked and leave a corpse.
  if mock_is_up "$PYTHON"; then
    ok "Reusing the mock already listening on :$MOCK_PORT"
    return 0
  fi

  step "Starting the mock Azure AI stack on :$MOCK_PORT"
  "$PYTHON" "$ROOT/scripts/mock-azure-ai.py" "$MOCK_PORT" &
  MOCK_PID=$!

  local attempt=0
  while [ $attempt -lt 20 ]; do
    if mock_is_up "$PYTHON"; then
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
if [ "$FORCE_MOCK" -eq 1 ] || { [ ! -f "$ROOT/.env" ] && [ ! -f "$HERE/.env" ] && [ -z "${AI_ENDPOINT:-}" ]; }; then
  if [ "$FORCE_MOCK" -eq 0 ]; then
    warn "No AI_ENDPOINT in .env or the environment - falling back to the offline mock."
    warn "Run scripts/03-set-local-env.ps1 to point the demo at real Azure resources."
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
  note "Configuration: python/.env (overrides the shared one)"
else
  note "Configuration: .env at the repo root"
fi

if [ "$OPEN_BROWSER" -eq 1 ]; then
  (
    sleep 3
    if command -v open >/dev/null 2>&1; then open "http://localhost:$PORT"
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "http://localhost:$PORT"
    fi
  ) >/dev/null 2>&1 &
fi

step "FastAPI app on http://localhost:$PORT"
note "The .NET stack runs separately, on its own port - see dotnet/start.sh"

ARGS="-m uvicorn app:app --port $PORT"
[ "$RELOAD" -eq 1 ] && ARGS="$ARGS --reload"

cd "$HERE" && exec "$VPY" $ARGS
