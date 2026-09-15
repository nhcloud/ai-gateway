#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Convenience dispatcher. Each stack is self-contained and can be run on
# its own - this just saves you a cd:
#
#   ./start_all.sh                 both stacks at once, side by side
#   ./start_all.sh dotnet          -> dotnet/start.sh    http://localhost:5080
#   ./start_all.sh python          -> python/start.sh    http://localhost:8080
#   ./start_all.sh verify          run both against the mock and compare them
#   ./start_all.sh mock            the offline mock only
#
# Any other flags (--port, --mock, --no-browser, ...) are passed straight
# through to the stack's own launcher.
# ─────────────────────────────────────────────────────────────────────
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# With no argument - or with a leading flag, which means no target was named - run
# both stacks. That is the demo: one page and one JSON contract, two back ends.
TARGET="${1:-both}"
case "$TARGET" in
  -*) TARGET=both ;;
  *)  [ $# -gt 0 ] && shift ;;
esac

case "$TARGET" in
  dotnet|net|razor)  exec "$ROOT/dotnet/start.sh" "$@" ;;
  python|py|fastapi) exec "$ROOT/python/start.sh" "$@" ;;

  both)
    # Different ports by design, so both run at once and can be compared.
    "$ROOT/dotnet/start.sh" "$@" &
    dotnet_pid=$!
    "$ROOT/python/start.sh" --no-browser "$@" &
    python_pid=$!
    printf '\n  .NET 10 Razor   http://localhost:5080\n'
    printf '  Python FastAPI  http://localhost:8080\n'
    printf '  Same page, same contract, two stacks. Ctrl+C stops both.\n\n'
    trap 'kill '"$dotnet_pid $python_pid"' 2>/dev/null' EXIT INT TERM
    wait
    ;;

  verify)
    command -v dotnet >/dev/null 2>&1 || { echo "error: the .NET SDK was not found." >&2; exit 1; }
    dotnet build "$ROOT/dotnet/AiGatewayDemo" --nologo -v q || exit 1
    python3 "$ROOT/tools/mock-azure-ai.py" 5290 &
    mock_pid=$!
    trap 'kill '"$mock_pid"' 2>/dev/null' EXIT INT TERM
    sleep 2
    python3 "$ROOT/tests/verify-apps.py"
    ;;

  mock)
    exec python3 "$ROOT/tools/mock-azure-ai.py" "${1:-5290}"
    ;;

  -h|--help|help)
    sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;

  *)
    echo "unknown target: $TARGET" >&2
    sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
