#!/usr/bin/env bash
# 부수효과 층 — 역할 방 띄우기·재리뷰 입력·찌르기·끄기가 상태기계 액션대로 실행되나(가짜로 갈아끼워 본다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import json, tempfile
from pathlib import Path
import marina_chain_runtime as RT
import marina_chains as C

root = Path(tempfile.mkdtemp())
calls = {"open": [], "kill": [], "deliver": []}
heads = {"v": {"proj": "a1"}}
role_t = Path(tempfile.mkdtemp()) / "role.jsonl"; role_t.write_text("")
RT._term_open = lambda root, *a, **kw: (calls["open"].append(kw), {"tid": f"t{len(calls['open'])}"})[1]
RT._term_kill = lambda tid: calls["kill"].append(tid)
RT._deliver = lambda tid, text: calls["deliver"].append((tid, text))
RT._repo_heads = lambda root: dict(heads["v"])
RT._transcript_size = lambda root, source, sid: 1000
RT._socket_for = lambda sid: "uds:/tmp/cc-socks/9.sock"
RT._role_settings = lambda root: {"on": "commit", "maxRounds": 2}
RT._role_transcript = lambda chain: role_t

# 기준 없음 → 기록만, 역할 방 안 띄움
r = RT.chain_trigger(root, "claude", "impl", "commit", now=100.0)
assert r["reason"] == "baseline" and calls["open"] == [], r
# 커밋 → 묶음 시작, 역할 방은 프롬프트-맨앞 argv·plan·계약(소켓) 으로
heads["v"] = {"proj": "b2"}
r = RT.chain_trigger(root, "claude", "impl", "commit", now=110.0)
assert r["ok"] and r["started"], r
kw = calls["open"][0]
argv = kw["agent_role_argv"]
assert argv[0] == "claude" and "uds:/tmp/cc-socks/9.sock" in argv[1] and "a1..b2" in argv[1], argv[:2]
assert "--permission-mode" in argv and kw["agent_role"] == "reviewer" and kw["agent_prompt"] == argv[1]
assert argv[1] not in kw["agent_role_launch"], "저장본에 프롬프트"
chain = C.open_chain_for("claude", "impl", "reviewer")
assert chain["roleRoom"]["tid"] == "t1" and chain["rounds"][0]["sentAnchor"] == 1000, chain

# 커밋 없는 트리거는 무시(열린 묶음이 reviewing 이면 pendingHead 도 안 생김)
assert RT.chain_trigger(root, "claude", "impl", "commit", now=111.0)["reason"] == "in-progress"

# 역할 결과(지적) → applying
role_t.write_text(json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "SendMessage",
    "input": {"to": "uds:/tmp/cc-socks/9.sock", "message": "### [WARNING] x"}}]}}) + "\n")
chain = RT.on_role_turn_end(C.open_chain_for("claude", "impl", "reviewer"), now=120.0)
assert chain["state"] == "applying" and chain["rounds"][0]["findings"] == 1, chain
# 구현 방 반영 커밋 → 2바퀴 요청이 역할 방 PTY 로 간다
heads["v"] = {"proj": "c3"}
chain = RT.on_implementer_turn_end(chain, root, now=130.0)
assert chain["state"] == "reviewing" and chain["round"] == 2, chain
tid, text = calls["deliver"][-1]
assert tid == "t1" and "b2..c3" in text and "2바퀴" in text, (tid, text)
assert chain["rounds"][1]["roleAnchor"] == role_t.stat().st_size

# 역할 방 PTY 가 죽었으면(입력 실패) 새로 띄우고 지난 요약을 싣는다
def boom(tid, text): raise ValueError("detached")
RT._deliver = boom
heads["v"] = {"proj": "d4"}
a = dict(chain); a["state"] = "applying"; a["unlimited"] = True; C.save_chain(a)   # 상한(2)에 걸리지 않게
chain = RT.on_implementer_turn_end(C.load_chain(a["id"]), root, now=140.0, force_round=True)
assert calls["open"][-1]["agent_role_argv"][1].count("지난 바퀴 요약") == 1 and chain["roleRoom"]["tid"] == "t2", chain

# 결과(지적 없음) → done + 역할 방 끔
role_t.write_text(json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "SendMessage",
    "input": {"to": "uds:/tmp/cc-socks/9.sock", "message": "반영 확인\n\n새 지적 없음"}}]}}) + "\n")
chain["rounds"][-1]["roleAnchor"] = 0; C.save_chain(chain)
done = RT.on_role_turn_end(C.load_chain(chain["id"]), now=150.0)
assert done["state"] == "done" and calls["kill"][-1] == "t2", (done, calls["kill"])

# 폰·명령: 무제한·멈추기
heads["v"] = {"proj": "e5"}; RT._deliver = lambda tid, text: calls["deliver"].append((tid, text))
RT.chain_trigger(root, "claude", "impl", "commit", now=160.0)
assert RT.set_unlimited("claude", "impl", True)["unlimited"] is True
assert RT.stop_chain("claude", "impl")["state"] == "stopped" and calls["kill"][-1] == "t3"
# force(폰 버튼): 커밋 없어도 시작
assert RT.chain_trigger(root, "claude", "impl", "button", force=True, now=170.0)["started"]
# 역할 꺼진 프로젝트 → off (force 는 기본 설정으로 시작)
RT._role_settings = lambda root: None
assert RT.chain_trigger(root, "claude", "impl2", "commit", now=180.0)["reason"] == "off"
print("PASS: 런타임 — 시작·재리뷰·재기동·끝·무제한·멈추기")
PY
