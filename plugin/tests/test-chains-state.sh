#!/usr/bin/env bash
# 묶음 상태기계(스펙 5.2) — 순수 함수라 파일·프로세스·시계 없이 모든 전이를 본다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import copy
import marina_chains as C

IMP = {"root": "/wt", "source": "claude", "sid": "s-impl", "socket": "uds:/tmp/cc-socks/1.sock"}
def fresh(max_rounds=2, unlimited=False):
    return C.new_chain(role="reviewer", implementer=IMP, base={"marina": "a"}, head={"marina": "b"},
                       max_rounds=max_rounds, unlimited=unlimited, now=100.0, anchor=10)
def do(actions): return [a["do"] for a in actions]

c = fresh()
assert c["state"] == "reviewing" and c["round"] == 1 and c["reviewedHead"] == {"marina": "b"}, c
assert c["rounds"][0]["sentAnchor"] == 10 and c["id"].startswith("c-"), c

# 결과(지적 없음) → done, 역할 방 끔
d, acts = C.next_state(copy.deepcopy(c), {"type": "result", "noneLeft": True, "findings": 0, "held": [], "anchor": 20}, 110.0)
assert d["state"] == "done" and d["endedReason"] == "clean" and do(acts) == ["kill_role"], (d, acts)
assert d["endedAnchor"] == 20 and d["rounds"][0]["noneLeft"] is True

# 결과(지적 있음) → applying
a, acts = C.next_state(copy.deepcopy(c), {"type": "result", "noneLeft": False, "findings": 2, "held": [], "anchor": 20}, 110.0)
assert a["state"] == "applying" and acts == [] and a["rounds"][0]["findings"] == 2, a

# applying + 턴 끝 + HEAD 앞섬 → 2바퀴 요청
r2, acts = C.next_state(copy.deepcopy(a), {"type": "implementer_turn_end", "head": {"marina": "c"}, "anchor": 30}, 120.0)
assert r2["state"] == "reviewing" and r2["round"] == 2, r2
assert acts == [{"do": "request_round", "round": 2, "base": {"marina": "b"}, "head": {"marina": "c"}}], acts
assert r2["reviewedHead"] == {"marina": "c"} and r2["rounds"][1]["sentAnchor"] == 30

# 2바퀴 결과(지적) 후 또 커밋 → 상한 도달 done
a2, _ = C.next_state(r2, {"type": "result", "noneLeft": False, "findings": 1, "held": [], "anchor": 40}, 130.0)
m, acts = C.next_state(a2, {"type": "implementer_turn_end", "head": {"marina": "d"}, "anchor": 50}, 140.0)
assert m["state"] == "done" and m["endedReason"] == "max-rounds" and do(acts) == ["kill_role"], (m, acts)

# 무제한이면 상한을 넘어 계속
u = copy.deepcopy(a2); u["unlimited"] = True
u3, acts = C.next_state(u, {"type": "implementer_turn_end", "head": {"marina": "d"}, "anchor": 50}, 140.0)
assert u3["state"] == "reviewing" and u3["round"] == 3 and do(acts) == ["request_round"], (u3, acts)

# 보류 누적(중복 제거)
h, _ = C.next_state(copy.deepcopy(c), {"type": "result", "noneLeft": False, "findings": 1, "held": ["[보류] X", "[보류] X"], "anchor": 20}, 110.0)
h2, _ = C.next_state(C.next_state(h, {"type": "implementer_turn_end", "head": {"marina": "c"}, "anchor": 30}, 120.0)[0],
                     {"type": "result", "noneLeft": False, "findings": 1, "held": ["[보류] X", "[보류] Y"], "anchor": 40}, 130.0)
assert h2["held"] == ["[보류] X", "[보류] Y"], h2["held"]

# applying + 턴 끝 + HEAD 그대로 → waiting, 30분 뒤 tick → done
w, acts = C.next_state(copy.deepcopy(a), {"type": "implementer_turn_end", "head": {"marina": "b"}, "anchor": 30}, 120.0)
assert w["state"] == "waiting" and w["waitingSince"] == 120.0 and acts == [], w
still, acts = C.next_state(copy.deepcopy(w), {"type": "tick"}, 120.0 + C.WAIT_TIMEOUT_S - 1)
assert still["state"] == "waiting" and acts == []
t, acts = C.next_state(copy.deepcopy(w), {"type": "tick"}, 120.0 + C.WAIT_TIMEOUT_S)
assert t["state"] == "done" and t["endedReason"] == "wait-timeout" and do(acts) == ["kill_role"], t
# waiting 중 커밋 → 다음 바퀴
wr, acts = C.next_state(copy.deepcopy(w), {"type": "implementer_turn_end", "head": {"marina": "c"}, "anchor": 60}, 130.0)
assert wr["state"] == "reviewing" and wr["round"] == 2 and do(acts) == ["request_round"]

# reviewing 중 커밋 → 새 요청 없이 다음 바퀴 범위에 합친다
p, acts = C.next_state(copy.deepcopy(c), {"type": "implementer_turn_end", "head": {"marina": "z"}, "anchor": 15}, 105.0)
assert p["state"] == "reviewing" and acts == [] and p["pendingHead"] == {"marina": "z"}, p
pa, _ = C.next_state(p, {"type": "result", "noneLeft": False, "findings": 1, "held": [], "anchor": 20}, 110.0)
pr, acts = C.next_state(pa, {"type": "implementer_turn_end", "head": {"marina": "z"}, "anchor": 30}, 120.0)
assert do(acts) == ["request_round"] and acts[0]["head"] == {"marina": "z"} and "pendingHead" not in pr, (pr, acts)

# 결과 없음: 한 번 찌르고, 두 번째면 끝
n1, acts = C.next_state(copy.deepcopy(c), {"type": "no_result", "anchor": 20}, 110.0)
assert n1["state"] == "reviewing" and n1["nudged"] is True and do(acts) == ["nudge_role"]
n2, acts = C.next_state(n1, {"type": "no_result", "anchor": 25}, 115.0)
assert n2["state"] == "done" and n2["endedReason"] == "no-result" and do(acts) == ["kill_role"]

# 멈추기·무제한 토글·구현 방 사라짐·끝난 묶음은 무시
s, acts = C.next_state(copy.deepcopy(a), {"type": "stop", "anchor": 31}, 121.0)
assert s["state"] == "stopped" and do(acts) == ["kill_role"] and s["endedAnchor"] == 31
on, acts = C.next_state(copy.deepcopy(c), {"type": "unlimited", "on": True}, 101.0)
assert on["unlimited"] is True and acts == []
g, acts = C.next_state(copy.deepcopy(a), {"type": "implementer_gone", "anchor": 32}, 122.0)
assert g["endedReason"] == "implementer-gone" and do(acts) == ["kill_role"]
same, acts = C.next_state(copy.deepcopy(d), {"type": "stop", "anchor": 99}, 200.0)
assert same == d and acts == [], "끝난 묶음이 다시 움직였다"

assert C.head_advanced({"a": "1"}, {"a": "2"}) and not C.head_advanced({"a": "1"}, {"a": "1"})
assert C.head_advanced({"a": "1"}, {"a": "1", "b": "9"}) and not C.head_advanced({"a": "1"}, {"a": ""})

# 파일 IO
C.save_chain(c)
assert C.load_chain(c["id"]) == c and C.open_chain_for("claude", "s-impl", "reviewer")["id"] == c["id"]
C.save_chain(d)                                   # 같은 id 를 done 으로 덮는다
assert C.open_chain_for("claude", "s-impl", "reviewer") is None and C.last_chain_for("claude", "s-impl", "reviewer")["state"] == "done"
assert C.load_chain("../etc/passwd") is None
print("PASS: 묶음 상태기계·장부")
PY
