#!/usr/bin/env bash
# B — 주입 메시지(task-notification·system-reminder·isMeta·AGENTS.md·INSTRUCTIONS·
# environment_context)는 user turn 에서 빠지고, 진짜 사용자 입력만 남는다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
python3 - "$SCR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import marina_sessions as ms

def turns(obj, source):
    return ms._transcript_object_turns(obj, source)

# claude: 진짜 입력 통과
real = {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "야 이거 고쳐줘"}]}}
assert [t["text"] for t in turns(real, "claude")] == ["야 이거 고쳐줘"]

# claude: task-notification 제외
notif = {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "<task-notification>\n<task-id>x</task-id>"}]}}
assert turns(notif, "claude") == [], "task-notification 새어나감"

# claude: system-reminder 단독 제외
sysrem = {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "<system-reminder>\nblah"}]}}
assert turns(sysrem, "claude") == [], "system-reminder 새어나감"

# claude: isMeta 제외
meta = {"type": "user", "isMeta": True, "message": {"role": "user", "content": [{"type": "text", "text": "Continue from where you left off"}]}}
assert turns(meta, "claude") == [], "isMeta 새어나감"

# claude: assistant 는 영향 없음
asst = {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "네 고칠게요"}]}}
assert [t["text"] for t in turns(asst, "claude")] == ["네 고칠게요"]

# codex: 진짜 입력 통과
creal = {"payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "오르카랑 비교해줘"}]}}
assert [t["text"] for t in turns(creal, "codex")] == ["오르카랑 비교해줘"]

# codex: AGENTS.md 주입 제외
cinj = {"payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "# AGENTS.md instructions\n<INSTRUCTIONS>..."}]}}
assert turns(cinj, "codex") == [], "AGENTS.md 주입 새어나감"

print("OK B-inject-filter (turns)")

# --- timeline(모바일이 실제 렌더하는 소스)도 같은 필터 + str content 처리 ---
def tl_messages(*objs, source="claude"):
    rows = [(i * 10, o) for i, o in enumerate(objs)]
    return [x for x in ms._transcript_timeline(rows, source) if x.get("kind") == "message"]

# claude 진짜 메시지: content 가 str(사용자 직접 입력) → timeline 에 나와야
real_str = {"type": "user", "message": {"role": "user", "content": "야 이거 고쳐줘"}}
assert [m["text"] for m in tl_messages(real_str)] == ["야 이거 고쳐줘"], "str content 진짜 메시지 누락"

# claude 주입(list, isMeta) → 제외
inj = {"type": "user", "isMeta": True, "message": {"role": "user", "content": [{"type": "text", "text": "Continue from where you left off."}]}}
assert tl_messages(inj) == [], "Continue timeline 누출"

# claude task-notification(str) → 제외
notif = {"type": "user", "message": {"role": "user", "content": "<task-notification>\nx"}}
assert tl_messages(notif) == [], "task-notification timeline 누출"

# codex 진짜 vs 주입
creal = {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "오르카 비교"}]}}
assert [m["text"] for m in tl_messages(creal, source="codex")] == ["오르카 비교"], "codex 진짜 메시지 누락"
cinj2 = {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "# AGENTS.md instructions\n<INSTRUCTIONS>"}]}}
assert tl_messages(cinj2, source="codex") == [], "codex 주입 timeline 누출"

print("OK B-inject-filter (timeline)")

# --- assistant "No response requested"(Continue 재개 응답) 은 turns·timeline 에서 제외 ---
noop = {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "No response requested."}]}}
assert turns(noop, "claude") == [], "noop assistant turns 누출"
assert tl_messages(noop) == [], "noop assistant timeline 누출"

# --- 상태 판정: 주입 user(Continue)가 마지막이어도 working 고착 안 됨 ---
import tempfile, json as _json
from pathlib import Path as _Path
def native_status(*lines, source="claude"):
    p = _Path(tempfile.mktemp(suffix=".jsonl"))
    p.write_text("\n".join(_json.dumps(o) for o in lines) + "\n", encoding="utf-8")
    return ms._native_agent_status(p, source, now=9999999999)

st = native_status(
    {"type": "assistant", "message": {"role": "assistant", "stop_reason": "end_turn", "content": []}},
    {"type": "user", "isMeta": True, "message": {"role": "user", "content": [{"type": "text", "text": "Continue from where you left off"}]}},
)
assert st["status"] != "working", f"주입 user 로 상태 working 고착: {st}"
print("OK 상태: 주입 user 는 working 판정 제외")

# --- [Request interrupted by user]: 렌더 숨김 + 상태는 completed(턴 종료) ---
interrupt = {"type": "user", "message": {"role": "user", "content": "[Request interrupted by user]"}}
assert turns(interrupt, "claude") == [], "interrupt turns 누출"
assert tl_messages(interrupt) == [], "interrupt timeline 누출"
st2 = native_status(
    {"type": "assistant", "message": {"role": "assistant", "content": []}},   # stop_reason 없음 = 중단된 응답
    {"type": "user", "message": {"role": "user", "content": "[Request interrupted by user]"}},
)
assert st2["status"] == "completed", f"interrupt 후 completed 아님: {st2}"
print("OK interrupt 마커: 렌더 숨김 + 상태 completed")

# --- 죽은 세션(프로세스 없음) working/blocked → idle 강등 ---
live = {("claude", "alive-1")}
assert ms._downgrade_if_dead({"source": "claude", "sid": "alive-1", "status": "working"}, live)["status"] == "working", "살아있는 세션 강등됨"
assert ms._downgrade_if_dead({"source": "claude", "sid": "dead-1", "status": "working"}, live)["status"] == "idle", "죽은 working 강등 안 됨"
assert ms._downgrade_if_dead({"source": "claude", "sid": "dead-1", "status": "blocked"}, live)["status"] == "idle", "죽은 blocked 강등 안 됨"
assert ms._downgrade_if_dead({"source": "claude", "sid": "dead-1", "status": "completed"}, live)["status"] == "completed", "completed 는 강등 대상 아님"
print("OK 죽은 세션 working→idle 강등")
PY
echo "PASS test-transcript-inject-filter"
