#!/usr/bin/env bash
# 모델·추론강도를 바꾸면 **지금** 먹어야 한다 — 형: "모델 변경 클로드는 펜딩이 아니라 그냥 안먹는거같은데".
#
# **왜 안 먹었나.** 라이브 적용이 codex 에만 있었다. claude 는 예약(pending)으로 떨어지는데,
# 예약이 실제로 쓰이는 곳은 PTY 가 없어 새로 열 때(`--model` 인자)뿐이다. 마리나로 계속 대화하면
# 그 PTY 는 계속 살아 있으니 그 경로에 영영 안 들어간다 = 바뀐 적이 없다.
#
# **어떻게 고쳤나.** Claude Code 의 슬래시 명령은 인자를 받는다(`/model <name>`·`/effort <level>`).
# codex 처럼 목록을 화살표로 세지 않아도 되고 목록이 바뀌어도 안 깨진다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - "$HERE" <<'PY'
import sys
from pathlib import Path

import marina_mobile as mm

root = Path(sys.argv[1]).resolve()
mm.safe_root = lambda value: Path(str(value)).resolve()   # 등록된 워크트리 없이 순수 판정만 본다
sent = []
mm.term_input = lambda tid, text: sent.append((tid, text))
mm._agent_input_pause = lambda: None

busy = {"value": False}
mm._native_agent_active = lambda r, s, i: busy["value"]
mm._live_agent_tid = lambda r, s, i: "tid-1"

# ① claude 도 살아있는 PTY 면 지금 먹는다. 화살표가 아니라 **인자 있는 슬래시 명령**으로.
result = mm.mobile_update_session_settings({
    "root": str(root), "source": "claude", "sid": "claude-sid-0001",
    "model": "claude-opus-5", "effort": "high",
})
assert result["applyMode"] == "live", result
typed = [text for _, text in sent]
assert "/model claude-opus-5" in typed, typed
assert "/effort high" in typed, typed
assert not any("\x1b[A" in text for text in typed), "claude 는 화살표로 목록을 세지 않는다"
assert mm.mobile_pending_session_settings(root, "claude", "claude-sid-0001") == {"model": "", "effort": ""}, \
    "지금 먹였으면 예약이 남아 있으면 안 된다"

# ② 작업 중이면 슬래시를 치지 않는다 — 응답 중 입력은 명령이 아니라 메시지로 큐에 들어간다.
sent.clear()
busy["value"] = True
result = mm.mobile_update_session_settings({
    "root": str(root), "source": "claude", "sid": "claude-sid-0002",
    "model": "claude-sonnet-5", "effort": "low",
})
assert result["applyMode"] == "pending", result
assert result["pendingReason"] == "busy", result   # 왜 미뤘는지까지 말해야 한다
assert sent == [], sent
saved = mm.mobile_pending_session_settings(root, "claude", "claude-sid-0002")
assert saved == {"model": "claude-sonnet-5", "effort": "low"}, saved

# ③ 예약은 다음 유휴 전송 때 회수된다 — 이게 없으면 예약 배지가 영원히 남는다(원래 버그).
sent.clear()
busy["value"] = False
mm._deliver_agent_input = lambda tid, source, text, delivery: "send"
out = mm.mobile_send({"root": str(root), "text": "안녕",
                      "target": {"type": "agent", "source": "claude", "sid": "claude-sid-0002"}})
assert out["ok"], out
typed = [text for _, text in sent]
assert "/model claude-sonnet-5" in typed and "/effort low" in typed, typed
assert mm.mobile_pending_session_settings(root, "claude", "claude-sid-0002") == {"model": "", "effort": ""}, \
    "회수했으면 예약을 지워야 한다"

# ④ PTY 가 없으면 예약이고, 이유는 'detached' 다(다음 실행 인자로 들어간다).
sent.clear()
mm._live_agent_tid = lambda r, s, i: ""
result = mm.mobile_update_session_settings({
    "root": str(root), "source": "claude", "sid": "claude-sid-0003", "model": "claude-opus-5", "effort": "",
})
assert result["applyMode"] == "pending" and result["pendingReason"] == "detached", result

# ⑤ 값 검증은 CLI 인자 경로와 같은 규칙을 쓴다 — 한쪽만 통과하는 값이 생기면 안 된다.
mm._live_agent_tid = lambda r, s, i: "tid-1"
for bad in ({"model": "opus; rm -rf /", "effort": ""}, {"model": "", "effort": "turbo"}):
    try:
        mm.mobile_update_session_settings({"root": str(root), "source": "claude",
                                           "sid": "claude-sid-0004", **bad})
    except ValueError:
        continue
    raise AssertionError(f"검증을 통과하면 안 되는 값: {bad}")

print("ok claude 모델·강도가 지금 먹고, 작업 중이면 다음 전송 때 회수된다")

# ⑥ 드레이너가 예약을 회수한다 — 메시지를 안 보내도 유휴가 되는 순간 적용된다.
#    (이게 없으면 "→ 다음 X" 배지가 다음 전송 때까지 하염없이 남는다.)
mm._clear_pending_session_settings(root, "claude", "claude-sid-0003")   # ④의 잔여 예약 정리
busy["value"] = True
sent.clear()
mm.mobile_update_session_settings({  # busy 상태에서 예약을 만든다
    "root": str(root), "source": "claude", "sid": "claude-sid-0005",
    "model": "claude-opus-5", "effort": "max",
})
assert sent == [], sent
busy["value"] = False
assert mm.mobile_settings_drain() == 1
typed = [text for _, text in sent]
assert "/model claude-opus-5" in typed and "/effort max" in typed, typed
assert mm.mobile_pending_session_settings(root, "claude", "claude-sid-0005") == {"model": "", "effort": ""}
# 여전히 작업 중이면 건드리지 않는다.
busy["value"] = True
mm.mobile_update_session_settings({"root": str(root), "source": "claude",
                                   "sid": "claude-sid-0006", "model": "claude-opus-5", "effort": ""})
sent.clear()
assert mm.mobile_settings_drain() == 0 and sent == [], sent
busy["value"] = False

# ⑦ 적용 직후 current 는 적용값을 보인다 — 트랜스크립트가 따라잡기 전까지의 공백 동안
#    화면이 옛 모델로 되돌아가면 "안 먹었다"로 보인다(형이 본 그 깜빡임).
transcript = {"value": {"model": "claude-old-1", "effort": "low"}}
mm.agent_runtime_settings = lambda r, s, i: dict(transcript["value"])
sent.clear()
result = mm.mobile_update_session_settings({
    "root": str(root), "source": "claude", "sid": "claude-sid-0007",
    "model": "claude-fable-5", "effort": "high",
})
assert result["applyMode"] == "live", result
shown = mm.mobile_current_session_settings(root, "claude", "claude-sid-0007")
assert shown == {"model": "claude-fable-5", "effort": "high"}, shown
# 새 턴이 기록되면(어느 값이든) 트랜스크립트가 이기고 기억은 지워진다.
transcript["value"] = {"model": "claude-fable-5", "effort": "high"}
assert mm.mobile_current_session_settings(root, "claude", "claude-sid-0007") == transcript["value"]
transcript["value"] = {"model": "claude-cli-pick-7", "effort": "low"}   # CLI 에서 직접 바꾼 경우
assert mm.mobile_current_session_settings(root, "claude", "claude-sid-0007") == transcript["value"], \
    "기억이 트랜스크립트를 계속 덮으면 CLI 에서 바꾼 게 영영 안 보인다"

# ⑧ **바꾼 것만 친다** — 형: "바꾼것만 보고 바로 적용돼야하는거아니야?". 모델만 바꿨는데
#    강도까지 다시 치면 느리고, 미룰 때도 안 바꾼 항목이 예약에 끼어 배지에 물고 늘어진다.
transcript["value"] = {"model": "claude-fable-5", "effort": "high"}
sent.clear()
result = mm.mobile_update_session_settings({
    "root": str(root), "source": "claude", "sid": "claude-sid-0008",
    "model": "claude-opus-5", "effort": "high",       # 모델만 다르다
})
assert result["applyMode"] == "live", result
typed = [text for _, text in sent]
assert "/model claude-opus-5" in typed, typed
assert not any(text.startswith("/effort") for text in typed), f"안 바꾼 강도까지 쳤다: {typed}"

# ⑧-1 둘 다 이미 그 값이면(방금 적용한 기억까지 현재값이다) 칠 것도, 예약할 것도 없다.
sent.clear()
result = mm.mobile_update_session_settings({
    "root": str(root), "source": "claude", "sid": "claude-sid-0008",
    "model": "claude-opus-5", "effort": "high",
})
assert result["applyMode"] == "live", result
assert sent == [], f"이미 현재값인데 쳤다: {sent}"

# ⑨ 예약이 기다리는 사이 트랜스크립트가 따라잡았으면(CLI 에서 직접 바꿈 등) 예약은 끝난 것 —
#    드레이너가 다시 치지 않고 지운다.
mm._clear_pending_session_settings(root, "claude", "claude-sid-0006")   # ⑥의 잔여 예약 정리
mm._persist_pending_session_settings(root, "claude", "claude-sid-0009",
                                     {"model": "claude-fable-5", "effort": "high"})
sent.clear()
assert mm.mobile_settings_drain() == 1   # 수렴 = 적용 완료로 센다
assert sent == [], f"이미 수렴했는데 쳤다: {sent}"
assert mm.mobile_pending_session_settings(root, "claude", "claude-sid-0009") == {"model": "", "effort": ""}
print("ok 바뀐 것만 치고, 수렴한 예약은 걷는다")
PY

# 적용은 **확인돼야** 성공이다 — 실측에서 유휴 TUI 에 친 /model 이 흔적 없이 사라진 적이 있다.
# 실행된 슬래시 명령은 트랜스크립트에 <command-args> 행을 즉시 남기므로 그걸 본다.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PYTHONPATH="$SCR" python3 - "$TMP" "$HERE" <<'PY'
import sys
from pathlib import Path

import marina_mobile as mm

tmp, root = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
mm.safe_root = lambda value: Path(str(value)).resolve()
mm.PENDING_SETTINGS_FILE = tmp / "pending.json"
mm.APPLIED_SETTINGS_FILE = tmp / "applied.json"
mm._SLASH_CONFIRM_TIMEOUT_S = 0.3          # 테스트에서 3초씩 기다리지 않는다
mm._agent_input_pause = lambda: None
mm._native_agent_active = lambda r, s, i: False
mm._live_agent_tid = lambda r, s, i: "tid-1"

transcript = tmp / "fake-transcript.jsonl"
transcript.write_text("{}\n", encoding="utf-8")
mm.agent_transcript_path = lambda r, s, i: transcript

# ① CLI 처럼 실행 행을 남기는 term_input → 확인 성공 → live
def echoing_term_input(tid, text):
    if text.startswith("/"):
        command, _, argument = text.partition(" ")
        with transcript.open("a", encoding="utf-8") as fh:
            fh.write(f'{{"type":"user","message":{{"content":"<command-args>{argument}</command-args>"}}}}\n')
mm.term_input = echoing_term_input
result = mm.mobile_update_session_settings({
    "root": str(root), "source": "claude", "sid": "claude-sid-0010",
    "model": "claude-opus-5", "effort": "high",
})
assert result["applyMode"] == "live", result

# ② 아무 행도 안 남는 term_input(실측의 그 소실) → live 라고 거짓말하지 않는다
mm.term_input = lambda tid, text: None
result = mm.mobile_update_session_settings({
    "root": str(root), "source": "claude", "sid": "claude-sid-0011",
    "model": "claude-opus-5", "effort": "",
})
assert result["applyMode"] == "pending" and result["pendingReason"] == "unverified", result

# ③ 드레이너가 재시도하되, 상한(5회)을 넘으면 접는다 — 남의 입력창에 3초마다 슬래시를 치지 않는다
calls = []
mm.term_input = lambda tid, text: calls.append(text)
for expected_attempts in (2, 3, 4, 5):
    assert mm.mobile_settings_drain() == 0
    raw = mm._read_json(mm.PENDING_SETTINGS_FILE)
    key = mm._session_settings_key(root, "claude", "claude-sid-0011")
    assert raw[key]["attempts"] == expected_attempts, raw[key]
calls.clear()
assert mm.mobile_settings_drain() == 0
assert calls == [], "상한을 넘겼는데 계속 슬래시를 친다"
raw = mm._read_json(mm.PENDING_SETTINGS_FILE)
assert key in raw, "상한 뒤에도 예약은 남아야 한다 — 다음 resume 인자로 먹는 마지막 보루"

# ④ 상한 전에 성공하면 예약이 지워진다
mm.term_input = echoing_term_input
mm._settings_file_update(mm.PENDING_SETTINGS_FILE, key, {"model": "claude-opus-5", "effort": "", "attempts": 2})
assert mm.mobile_settings_drain() == 1
assert key not in mm._read_json(mm.PENDING_SETTINGS_FILE)
print("ok 적용은 트랜스크립트로 확인하고, 실패는 세다가 접는다")
PY

html="$(PYTHONPATH="$SCR" python3 -c 'from marina_mobile import render_mobile_html; print(render_mobile_html())')"
grep -qF '작업 중이라 이번 응답이 끝난 뒤 적용합니다' <<<"$html" \
  || { echo "FAIL: 미룬 이유를 화면이 말하지 않는다"; exit 1; }
grep -qF '적용 확인이 안 돼요' <<<"$html" \
  || { echo "FAIL: 확인 실패를 화면이 말하지 않는다"; exit 1; }

# 화면의 '현재 모델'은 **슬래시 명령 행**에서도 읽어야 한다 — 형: "적용한게 바로바로 안되네.
# 다음 대화 치면 그 전 모델로 떴다가 답변 오면서 바뀌네".
#
# 모델이 적힌 assistant 행은 **다음 답변 때야** 생긴다. 반면 /model 실행 행은 즉시 남는다.
# 응답 행만 보면 그 사이 내내 옛 모델을 보여준다(형이 본 그 지연).
TMP2="$(mktemp -d)"
trap 'rm -rf "$TMP2"' EXIT
PYTHONPATH="$SCR" python3 - "$TMP2" <<'PY2'
import json
import sys
from pathlib import Path

import marina_sessions as ms

tmp = Path(sys.argv[1])
project = tmp / "projects" / ms._claude_project_slug(tmp / "wt")
project.mkdir(parents=True, exist_ok=True)
ms.CLAUDE_PROJECTS_DIR = tmp / "projects"
sid = "sid-slash-0001"
path = project / f"{sid}.jsonl"

def write(*rows):
    path.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")

def answered(model, effort):
    return {"type": "assistant", "effort": effort, "message": {"model": model}}

def slash(command, argument):
    return {"type": "user", "message": {"content":
            f"<command-name>{command}</command-name>\n<command-args>{argument}</command-args>"}}

read = lambda: ms.agent_runtime_settings(tmp / "wt", "claude", sid)

# ① 응답 행만 있으면 종전대로.
write(answered("claude-fable-5", "high"))
assert read() == {"model": "claude-fable-5", "effort": "high"}, read()

# ② /model 을 친 직후 — 아직 답이 없어도 **바로** 새 모델로 보여야 한다.
write(answered("claude-fable-5", "high"), slash("/model", "claude-opus-5"))
assert read() == {"model": "claude-opus-5", "effort": "high"}, read()

# ③ 모델만 바꿨으면 강도는 옛 응답 행에서 그대로 온다(한 행에서 둘 다 찾으려 하면 어긋난다).
write(answered("claude-fable-5", "max"), slash("/model", "claude-opus-5"))
assert read() == {"model": "claude-opus-5", "effort": "max"}, read()

# ④ 강도만 바꾼 경우도 대칭으로.
write(answered("claude-fable-5", "low"), slash("/effort", "high"))
assert read() == {"model": "claude-fable-5", "effort": "high"}, read()

# ⑤ 답이 오면 응답 행이 더 새 정보다 — 명령 행에 발목 잡히지 않는다.
write(slash("/model", "claude-opus-5"), answered("claude-sonnet-5", "low"))
assert read() == {"model": "claude-sonnet-5", "effort": "low"}, read()

# ⑥ 다른 슬래시 명령은 설정과 무관하다.
write(answered("claude-fable-5", "high"), slash("/compact", ""))
assert read() == {"model": "claude-fable-5", "effort": "high"}, read()

print("ok 현재 모델·강도를 슬래시 명령 행에서 즉시 읽는다")
PY2

echo "PASS test-agent-settings-live"
