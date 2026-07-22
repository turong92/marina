#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
command -v python3 >/dev/null 2>&1 || exit 0
python3 "$SCRIPT_DIR/marina_agent_events.py" 2>/dev/null || true
exit 0
