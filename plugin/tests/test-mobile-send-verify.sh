#!/usr/bin/env bash
# 메시지 전달도 **확인돼야** 성공이다 — 실측(2026-08-16): 컨텍스트가 꽉 찬 유휴 claude TUI 가
# 형 메시지를 2시간 반 동안 소리 없이 버렸는데 marina 는 계속 "보냈다"고 보고했다.
#
# 계약: ① 유휴 claude 전송은 트랜스크립트 user 행으로 확인 ② 확인 실패면 보류함에 보존하고
# held 로 정직하게 응답 ③ 컨텍스트가 가득이면 /compact 회복을 시작 ④ 드레이너는 압축이
# 끝날 때까지 타이핑하지 않고(중복 방지), 끝나면 전달 ⑤ 원인 불명 실패는 백오프로 재시도.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PYTHONPATH="$SCR" python3 - "$TMP" "$HERE" <<'PY'
import json
import sys
import time
from pathlib import Path

import marina_mobile as mm

tmp, root = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
mm.safe_root = lambda value: Path(str(value)).resolve()
mm.OUTBOX_DIR = tmp / "outbox"
mm._agent_input_pause = lambda: None
mm._native_agent_active = lambda r, s, i: False
mm._live_agent_tid = lambda r, s, i: "tid-1"
mm._recover_pending_settings = lambda r, s, i, t: "none"
mm._DELIVERY_CONFIRM_TIMEOUT_S = 0.3       # 테스트에서 4초씩 기다리지 않는다

transcript = tmp / "session.jsonl"
transcript.write_text("{}\n", encoding="utf-8")
mm.agent_transcript_path = lambda r, s, i: transcript

def echoing_term_input(tid, text):
    # 건강한 CLI: 제출된 입력이 곧장 user 행으로 남는다(슬래시는 command 행).
    if text in ("\r", "\t"):
        return
    with transcript.open("a", encoding="utf-8") as fh:
        if text.startswith("/"):
            command, _, argument = text.partition(" ")
            fh.write(json.dumps({"type": "user", "message": {"content":
                f"<command-name>{command}</command-name>\n<command-args>{argument}</command-args>"}},
                ensure_ascii=False) + "\n")
        else:
            fh.write(json.dumps({"type": "user", "message": {"content": text}}, ensure_ascii=False) + "\n")

def target(sid):
    return {"root": str(root), "text": "야 이거 확인해줘",
            "target": {"type": "agent", "source": "claude", "sid": sid}}

# ① 건강한 세션: 확인되고 종전대로 전달된다.
mm.term_input = echoing_term_input
out = mm.mobile_send(target("sid-ok"))
assert out["ok"] and out["delivery"] == "queue", out
assert mm.mobile_outbox_pending(root, "claude", "sid-ok") == [], "확인됐는데 보류함에 남았다"

# ② 삼키는 세션 + 컨텍스트 여유: held 로 정직하게 응답하고 메시지는 보류함에 보존된다.
mm.term_input = lambda tid, text: None
mm.agent_usage_from_path = lambda path, source: {"contextPercent": 12.0}
out = mm.mobile_send(target("sid-low"))
assert out["ok"] and out["delivery"] == "held" and out["compacting"] is False, out
assert mm.mobile_outbox_pending(root, "claude", "sid-low") == ["야 이거 확인해줘"], "메시지가 유실됐다"

# ③ 삼키는 세션 + 컨텍스트 가득: /compact 회복이 시작된다(명령 행 확인 = 그 자리에서 성공).
typed = []
def compact_accepting_input(tid, text):
    typed.append(text)
    if text.startswith("/compact"):
        with transcript.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"type": "user", "message": {"content":
                "<command-name>/compact</command-name>\n<command-args></command-args>"}}) + "\n")
mm.term_input = compact_accepting_input
mm.agent_usage_from_path = lambda path, source: {"contextPercent": 97.5}
out = mm.mobile_send(target("sid-full"))
assert out["ok"] and out["delivery"] == "held" and out["compacting"] is True, out
record = json.loads((mm.OUTBOX_DIR / "claude-sid-full.json").read_text(encoding="utf-8"))
assert record.get("compactingSince") and "compactOffset" in record, record

# ③-1 압축 대기 중의 재전송은 회복을 또 건드리지 않는다(압축 중인 TUI 를 죽이면 안 된다).
typed.clear()
out = mm.mobile_send(target("sid-full"))
assert out["delivery"] == "held" and out["compacting"] is True, out
assert not any(t.startswith("/compact") for t in typed), "압축 중인데 /compact 를 또 쳤다"
assert len(json.loads((mm.OUTBOX_DIR / "claude-sid-full.json").read_text())["messages"]) == 2

# ④ 드레이너: 압축이 안 끝났으면 **아무것도 타이핑하지 않는다**. 끝나면 전달한다.
mm.mobile_outbox_drain()   # sid-full 은 압축 대기로 건너뛰고, sid-low 는 시도→실패 1회 기록됨
mm.term_input = lambda tid, text: typed.append(text)
typed.clear()
mm.mobile_outbox_drain()
assert not any("확인해줘" in t for t in typed), f"압축이 안 끝났는데 타이핑했다: {typed}"
with transcript.open("a", encoding="utf-8") as fh:   # 압축 완료 표식
    fh.write('{"type":"user","isCompactSummary":true,"message":{"content":"summary"}}\n')
mm.term_input = echoing_term_input
delivered = mm.mobile_outbox_drain()
assert delivered >= 1, delivered
assert not (mm.OUTBOX_DIR / "claude-sid-full.json").exists(), "압축 끝났는데 전달이 안 됐다"

# ⑤ 원인 불명 실패(컨텍스트 여유)의 드레인: 실패를 세고 백오프한다 — 3초마다 타이핑 금지.
mm.term_input = lambda tid, text: None
mm.mobile_outbox_drain()                        # 시도 1 → 실패 기록
record = json.loads((mm.OUTBOX_DIR / "claude-sid-low.json").read_text(encoding="utf-8"))
assert record.get("attempts") == 1 and record.get("lastAttempt"), record
typed2 = []
mm.term_input = lambda tid, text: typed2.append(text)
mm.mobile_outbox_drain()                        # 직후 재시도 → 백오프에 걸려 타이핑 없음
assert typed2 == [], f"백오프를 무시하고 타이핑했다: {typed2}"
# 백오프가 지나면 다시 시도하고, 성공하면 비운다.
record["lastAttempt"] = time.time() - 3600
(mm.OUTBOX_DIR / "claude-sid-low.json").write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
mm.term_input = echoing_term_input
assert mm.mobile_outbox_drain() == 1
assert not (mm.OUTBOX_DIR / "claude-sid-low.json").exists()

print("ok 전달은 확인돼야 성공이고, 실패는 보존·회복·백오프로 다룬다")
PY

# ⑥ 삼키는 TUI 가 /compact 까지 삼키면: 그 PTY 를 접고 새 resume 에서 /compact 를 확인한다.
PYTHONPATH="$SCR" python3 - "$TMP" "$HERE" <<'PY'
import json
import sys
from pathlib import Path

import marina_mobile as mm

tmp, root = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
transcript = tmp / "wedged.jsonl"
transcript.write_text("{}\n", encoding="utf-8")
mm._agent_input_pause = lambda: None

killed = []
mm.term_kill = lambda tid: killed.append(tid)
mm.term_open = lambda r, **kw: {"tid": "tid-fresh", "reused": False}
def fresh_only_input(tid, text):
    # 옛 TUI(tid-wedged)는 전부 삼킨다. 새 TUI(tid-fresh)만 /compact 를 받는다.
    if tid == "tid-fresh" and text.startswith("/compact"):
        with transcript.open("a", encoding="utf-8") as fh:
            fh.write('{"type":"user","message":{"content":"<command-name>/compact</command-name>"}}\n')
mm.term_input = fresh_only_input

ok = mm._compact_wedged_claude(root, "sid-wedged", "tid-wedged", transcript)
assert ok is True
assert killed == ["tid-wedged"], f"명령까지 삼키는 PTY 를 접지 않았다: {killed}"
print("ok 명령까지 삼키면 PTY 를 접고 새 resume 에서 /compact")
PY

echo "PASS test-mobile-send-verify"
