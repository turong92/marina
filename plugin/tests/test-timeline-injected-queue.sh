#!/usr/bin/env bash
# _transcript_timeline — 작업 중 도착한 하네스 주입(<task-notification> 등)은 queue-operation:enqueue 로 기록되는데,
# 이건 사용자가 친 큐 메시지가 아니라 주입이다. user/assistant 경로의 _is_injected_user 필터가 queue 경로엔 안 걸려
# 그동안 "대기 중" 큐 말풍선으로 새어 문신됐다(형: "서브에이전트 알림이 내 말풍선으로, 대기열 대기중 문신"). 이 테스트는
# 주입 큐는 렌더에서 빠지고, 진짜 사용자 큐 메시지는 그대로 렌더됨을 못박는다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$HERE/../scripts"

python3 - "$SCRIPTS" <<'PY'
import sys, json
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import marina_sessions as ms

def qop(op, content, i):
    return (i, {"type": "queue-operation", "operation": op, "content": content})

rows = [
    (0, {"type": "user", "message": {"role": "user", "content": "진짜 사용자 메시지"}}),
    qop("enqueue", "<task-notification>\n<task-id>abc</task-id> subagent done", 1),   # 주입 — 렌더 제외
    qop("enqueue", "[SYSTEM NOTIFICATION - NOT USER INPUT]\nbackground event", 2),      # 주입 — 렌더 제외
    qop("enqueue", "형이 작업중에 친 진짜 큐 메시지", 3),                                # 진짜 큐 — 렌더
]
tl = ms._transcript_timeline(rows, "claude")
users = [it for it in tl if it.get("kind") == "message" and it.get("role") == "user"]
texts = [it.get("text", "") for it in users]

fails = []
# 주입 래퍼가 user 말풍선으로 새면 안 됨
if any(t.lstrip().startswith(("<task-notification>", "[SYSTEM NOTIFICATION")) for t in texts):
    fails.append(f"주입 큐가 user 말풍선으로 샘: {texts}")
# 진짜 사용자 메시지 + 진짜 사용자 큐 메시지는 남아야 함
if "진짜 사용자 메시지" not in texts:
    fails.append("일반 사용자 메시지 누락")
real_q = [it for it in users if it.get("queued") and it.get("text") == "형이 작업중에 친 진짜 큐 메시지"]
if not real_q:
    fails.append(f"진짜 큐 메시지가 렌더 안 됨: {texts}")

if fails:
    print("FAIL")
    for f in fails: print("  -", f)
    sys.exit(1)
print("PASS: 주입(task-notification/SYSTEM NOTIFICATION) 큐는 제외, 진짜 사용자 (큐)메시지는 렌더")
PY
