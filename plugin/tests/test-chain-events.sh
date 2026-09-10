#!/usr/bin/env bash
# 감시층 사건 → 묶음. 턴 끝 판정은 status 전이(waiting 포함), 역할 방 사건은 결과 읽기로(스펙 6.1).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
PYTHONPATH="$SCR" python3 - <<'PY'
import marina_chain_runtime as RT
import marina_chains as C

log = []
RT.chain_trigger = lambda root, source, sid, reason, force=False, now=None: log.append(("trigger", sid, reason)) or {"ok": True}
RT.on_implementer_turn_end = lambda chain, root, now=None, force_round=False: log.append(("impl", chain["id"])) or chain
RT.on_role_turn_end = lambda chain, now=None: log.append(("role", chain["id"])) or chain
RT._role_settings = lambda root: {"on": "commit"}

def ev(sid, kind, status, root="/wt"):
    return {"session": f"agent:claude:{sid}:{root}", "root": root, "source": "claude", "sid": sid, "kind": kind, "status": status}

RT._last_status.clear()
RT.on_events([ev("impl", "status", "working")], now=1.0)
assert log == [], log                                              # 일 시작은 트리거 아님
RT.on_events([ev("impl", "status", "waiting")], now=2.0)
assert log == [("trigger", "impl", "commit")], log                  # working → waiting = 턴 끝
log.clear()
RT.on_events([ev("other", "status", "waiting")], now=3.0)
assert log == [], "직전 상태를 모르면 턴 끝으로 보지 않는다"

# 열린 묶음이 있는 구현 방 → 트리거가 아니라 impl 경로
chain = C.new_chain(role="reviewer", implementer={"root": "/wt", "source": "claude", "sid": "impl", "socket": "uds:/x"},
                    base={"p": "a"}, head={"p": "b"}, max_rounds=2, unlimited=False, now=1.0, anchor=0)
chain["roleRoom"] = {"tid": "t1", "sid": "role-sid"}
C.save_chain(chain)
RT.on_events([ev("impl", "status", "working"), ev("impl", "idle", "idle")], now=4.0)
assert log == [("impl", chain["id"])], log
log.clear()
# 역할 방 사건 → 결과 읽기, 트리거 안 함(역할 방이 커밋해도 새 묶음이 생기면 안 된다)
RT.on_events([ev("role-sid", "status", "working"), ev("role-sid", "status", "waiting")], now=5.0)
assert log == [("role", chain["id"])], log

# 끝난 묶음의 역할 방 sid 는 더는 역할 방으로 안 본다
chain["state"] = "done"; C.save_chain(chain); log.clear()
assert RT._role_sid_to_chain("role-sid") is None
print("PASS: 사건 → 묶음")
PY

# _on_events 가 주 데몬 확인 직후·알림 필터 전에 넘긴다(순서가 계약)
python3 - "$SCR/marina_handler.py" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
body = src[src.index("def _on_events"):src.index("def _events_loop")]
primary = body.index("is_primary_notifier(PORT)")
submit = body.index("submit_events(events)")
notify = body.index("should_notify(")
assert primary < submit < notify, (primary, submit, notify)
print("PASS: _on_events 연결 순서")
PY
