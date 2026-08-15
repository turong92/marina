#!/usr/bin/env bash
# 상태 판정 캐시: **빨라지되 늙지 않는다**.
#
# 모바일 새로고침 한 번이 세션 전부의 트랜스크립트 꼬리와 이벤트 저널을 매번 다시 파싱했다
# (실측 2.1초 중 1.8초, JSON 파싱 8688회 + readlink 8950회). 대부분의 폴에서 파일은 그대로라
# 지문((mtime_ns, size, inode))이 같으면 재사용한다. 대신 **바뀌면 반드시 보여야** 한다 —
# 상태가 늙으면 "작업 중인데 유휴"처럼 보이는 그 부류의 버그가 다시 시작된다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import json
import os
import sys
import time
from pathlib import Path

import marina_sessions as ms

tmp = Path(sys.argv[1])
transcript = tmp / "session.jsonl"

def write(rows):
    transcript.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")

def assistant(ts, stop="end_turn"):
    return {"type": "assistant", "timestamp": ts,
            "message": {"role": "assistant", "stop_reason": stop, "content": []}}

def user(ts, text):
    return {"type": "user", "timestamp": ts, "message": {"role": "user", "content": text}}

now = time.time()
stamp = lambda offset: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now + offset))

# ① 끝난 턴 → completed
write([assistant(stamp(-10))])
first = ms._native_agent_status(transcript, "claude", now=now)
assert first["status"] == "completed", first

# ② 같은 파일을 다시 읽을 땐 파싱하지 않는다(캐시 적중) — 파싱 횟수로 확인한다.
real_loads = ms.json.loads
count = {"n": 0}
def counting_loads(*args, **kwargs):
    count["n"] += 1
    return real_loads(*args, **kwargs)
ms.json.loads = counting_loads
try:
    again = ms._native_agent_status(transcript, "claude", now=now)
finally:
    ms.json.loads = real_loads
assert again == first, (again, first)
assert count["n"] == 0, f"안 바뀐 파일을 다시 파싱했다({count['n']}회)"

# ③ **바뀌면 보인다** — 새 사용자 턴을 붙이면 working 으로 넘어가야 한다.
write([assistant(stamp(-10)), user(stamp(-1), "이거 고쳐줘")])
fresh = ms._native_agent_status(transcript, "claude", now=now)
assert fresh["status"] == "working", f"파일이 바뀌었는데 옛 판정을 줬다: {fresh}"

# ③-1 크기가 같은 덮어쓰기도 보인다 — 지문은 mtime_ns 까지 본다(크기만 보면 놓친다).
def render(rows, pad=0):
    body = "".join(json.dumps(r) + "\n" for r in rows)
    return body[:-1] + " " * pad + "\n" if pad else body

working_rows = [assistant(stamp(-30)), user(stamp(-2), "AAAA")]
done_rows = [assistant(stamp(-30)), assistant(stamp(-2))]
gap = len(render(done_rows)) - len(render(working_rows))
assert gap >= 0, gap
transcript.write_text(render(working_rows, pad=gap), encoding="utf-8")
before = transcript.stat().st_size
assert ms._native_agent_status(transcript, "claude", now=now)["status"] == "working"
transcript.write_text(render(done_rows), encoding="utf-8")   # 같은 크기, 끝난 턴
assert transcript.stat().st_size == before, "테스트 전제(같은 크기)가 깨졌다"
swapped = ms._native_agent_status(transcript, "claude", now=now)
assert swapped["status"] == "completed", f"같은 크기로 덮어썼는데 옛 판정을 줬다: {swapped}"

# ③-2 시계에 따라 달라지는 판정은 캐시하지 않는다 — 파일이 그대로여도 시간이 지나면 바뀐다.
#     (후보 목록만 재사용하고 선택은 매번 한다. 이걸 통째로 캐시하면 상태가 시간에 얼어붙는다.)
write([{"type": "other", "timestamp": stamp(-1)}])     # 턴 경계 후보 없음 → mtime 기반 판정
touched = transcript.stat().st_mtime                   # 판정 기준은 파일 mtime 이다
recent = ms._native_agent_status(transcript, "claude", now=touched + 1)
assert recent["status"] == "working", recent           # 최근 활동
later = ms._native_agent_status(transcript, "claude", now=touched + 3600)
assert later["status"] == "idle", f"시간이 지났는데 옛 상태에 얼어붙었다: {later}"

# ④ 파일이 사라지면 캐시도 함께 사라진다(유령 상태 금지).
transcript.unlink()
gone, _ = ms._agent_state_rows(transcript)
assert gone == [], gone
print("ok 트랜스크립트 캐시: 안 바뀌면 재파싱 없음, 바뀌면 즉시 반영")

# ⑤ 모델·강도도 지문으로 캐시한다 — **여기서 늙으면 형이 겪은 "바꿨는데 그대로"가 재발한다**.
project = tmp / "projects" / ms._claude_project_slug(tmp / "wt")
project.mkdir(parents=True, exist_ok=True)
ms.CLAUDE_PROJECTS_DIR = tmp / "projects"
sid = "sid-runtime-0001"
settings_path = project / f"{sid}.jsonl"

def write_settings(model, effort):
    settings_path.write_text(json.dumps(
        {"type": "assistant", "effort": effort, "message": {"model": model}}) + "\n", encoding="utf-8")

write_settings("claude-fable-5", "high")
assert ms.agent_runtime_settings(tmp / "wt", "claude", sid) == {"model": "claude-fable-5", "effort": "high"}
write_settings("claude-opus-5", "high")   # 같은 크기가 아니어도, 같아도 보여야 한다
after = ms.agent_runtime_settings(tmp / "wt", "claude", sid)
assert after == {"model": "claude-opus-5", "effort": "high"}, f"모델이 바뀌었는데 옛 값을 줬다: {after}"
# 돌려준 dict 를 호출자가 고쳐도 캐시가 오염되면 안 된다(화면이 남의 수정을 물려받는다).
after["model"] = "오염"
assert ms.agent_runtime_settings(tmp / "wt", "claude", sid)["model"] == "claude-opus-5"
print("ok 모델·강도 캐시: 바뀌면 즉시, 호출자 수정에 오염되지 않음")
PY

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import json
import sys
import time
from pathlib import Path

import marina_agent_events as ae

tmp = Path(sys.argv[1])
home = tmp / "home"
home.mkdir(parents=True, exist_ok=True)
root = tmp / "wt"
root.mkdir(parents=True, exist_ok=True)
sid = "sid-cache-0001"

def record(hook, ts):
    written = ae.record_hook_event(
        {"session_id": sid, "cwd": str(root), "hook_event_name": hook,
         "transcript_path": str(root / ".claude" / "x.jsonl")},
        environ={}, home=home, now=ts)
    assert written, hook
    return written

now = time.time()
record("UserPromptSubmit", now - 20)
first = ae.latest_agent_event("claude", sid, root, home=home, now=now)
assert first and first["event"] == "working", first

# ① 안 바뀐 저널은 다시 파싱하지 않는다.
real_loads = ae.json.loads
count = {"n": 0}
ae.json.loads = lambda *a, **k: (count.__setitem__("n", count["n"] + 1), real_loads(*a, **k))[1]
try:
    again = ae.latest_agent_event("claude", sid, root, home=home, now=now)
finally:
    ae.json.loads = real_loads
assert again == first, (again, first)
assert count["n"] == 0, f"안 바뀐 저널을 다시 파싱했다({count['n']}회)"

# ② 새 이벤트가 들어오면 **즉시** 보인다 — 이게 늦으면 상태 배지가 통째로 늙는다.
record("Stop", now - 1)
fresh = ae.latest_agent_event("claude", sid, root, home=home, now=now)
assert fresh and fresh["event"] == "ended", f"새 이벤트를 못 봤다: {fresh}"

# ③ 저널이 사라지면 None — 캐시가 유령을 되살리면 안 된다.
(home / ".marina" / "agent-events" / "claude" / f"{sid}.jsonl").unlink()
assert ae.latest_agent_event("claude", sid, root, home=home, now=now) is None

# ④ 경로 정규화 기억은 결과를 바꾸지 않는다(같은 입력 → 같은 답).
sample = str(root / "sub" / ".." / "x")
assert ae._canonical_path(sample) == ae._canonical_path(sample) == str((root / "x").resolve())
print("ok 이벤트 저널 캐시: 안 바뀌면 재파싱 없음, 새 이벤트는 즉시")
PY

echo "PASS test-state-cache-freshness"
