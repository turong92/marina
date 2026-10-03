#!/usr/bin/env bash
# 분리 B: discord 는 사용량·컨텍스트 % 를 자기 사본(marina_discord_usage)으로 — 대시보드(marina_sessions)와 같은 값이어야 한다(R3)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd -P)"
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$MARINA_HOME" <<'PY'
import json, sys, time
from pathlib import Path
import marina_discord_usage as du
import marina_sessions as ms
h = Path(sys.argv[1]); tr = h / "t.jsonl"
tr.write_text("\n".join(json.dumps(x) for x in [
    {"type": "user", "message": {"content": "hi"}},
    {"type": "assistant", "message": {"model": "claude-opus-5-5", "usage": {"input_tokens": 1000, "cache_read_input_tokens": 40000, "output_tokens": 500}}},
]) + "\n")
a = du.context_percent(tr); b = ms.agent_usage_from_path(tr, "claude").get("contextPercent")
assert a == b and a is not None, (a, b)
assert du.context_percent(h / "none.jsonl") is None
payload = {"five_hour": {"utilization": 20.0, "resets_at": "2026-10-03T05:00:00+00:00"},
           "seven_day": {"utilization": 6.0, "resets_at": "2026-10-08T05:00:00+00:00"}}
du.claude_usage_payload = lambda refresh=False: payload
import marina_usage; marina_usage.claude_usage_payload = lambda refresh=False: payload
w1 = du.claude_windows(); w2 = ms.provider_account_usage("claude").get("windows")
assert [(x["key"], x["usedPercent"]) for x in w1] == [(x["key"], x["usedPercent"]) for x in w2] and w1, (w1, w2)
src = (Path(du.__file__)).read_text()
assert "import marina_sessions" not in src and "from marina_sessions" not in src and "marina_usage" not in src.replace("marina_discord_usage", "")
print("ok")
PY
echo "PASS test-discord-usage"
