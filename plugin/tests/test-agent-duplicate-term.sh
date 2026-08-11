#!/usr/bin/env bash
# 한 세션에 term 이 여럿일 때 **가장 최근 것**을 쓴다 — 형: "왜 너만 모바일로 메세지를 안먹냐".
#
# **어쩌다 여럿이 되나.** _live_agent_tid 가 잠깐 빈손을 돌려주면 호출자(mobile_send)는 "조작
# 가능한 PTY 가 없다"고 보고 인수인계 경로로 내려간다. 거기서 붙들고 있는 pid 를 못 짚으면
# (데스크톱/불명) 죽이지 않고 그냥 resume 하므로, 같은 세션의 claude 프로세스가 **둘**이 된다.
#
# **그다음이 진짜 문제.** 예전 구현은 먼저 걸리는 term 을 그냥 돌려줬다. 그래서 조회가 옛
# 프로세스를 집으면 형이 보낸 메시지가 이미 버려진 대화로 타이핑돼 영영 도착하지 않는다.
# 실측(2026-08-11): 15:59 것과 16:06 것이 동시에 살아 있었고 실제 대화는 16:06 쪽이었다.
# 새 resume 이 곧 현재 대화이므로 최신이 이긴다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from pathlib import Path

import marina_mobile as M

ROOT = Path("/tmp/marina-dup-term-test")
ROOT.mkdir(parents=True, exist_ok=True)
SID = "sid-dup"


def term(tid, created, *, alive=True, detached=False, sid=SID, source="claude"):
    return {"tid": tid, "alive": alive, "detached": detached,
            "root": str(ROOT.resolve()), "created": created,
            "agent": {"source": source, "sid": sid}}


def pick(sessions):
    M.term_list = lambda: {"sessions": sessions}
    return M._live_agent_tid(ROOT, "claude", SID)


old, new = term("old", 100.0), term("new", 200.0)

# ① 순서와 무관하게 최신이 이긴다 — 목록 순서는 보장이 없다.
assert pick([old, new]) == "new", "옛 것이 먼저 와도 최신을 골라야 한다"
assert pick([new, old]) == "new", "순서가 뒤집혀도 결과가 같아야 한다"

# ② detached 는 후보가 아니다 — tid 를 줘도 term_input 이 거부한다. 최신이어도 제외.
assert pick([old, term("newer-detached", 300.0, detached=True)]) == "old", \
    "detached 가 최신이라고 그걸 고르면 입력이 조용히 실패한다"

# ③ 죽은 term 도 제외한다.
assert pick([old, term("newer-dead", 300.0, alive=False)]) == "old", "죽은 term 을 고르면 안 된다"

# ④ 다른 세션/다른 소스의 term 에 새는 일이 없어야 한다(sid 가 곧 대화다).
assert pick([term("other-sid", 900.0, sid="다른세션"), old]) == "old", "sid 가 다른 term 으로 새면 안 된다"
assert pick([term("other-src", 900.0, source="codex"), old]) == "old", "source 가 다른 term 으로 새면 안 된다"

# ⑤ 후보가 없으면 빈 문자열 — 호출자가 인수인계 경로로 내려간다(그게 설계다).
assert pick([]) == "", "후보가 없으면 빈 문자열이어야 한다"

# ⑥ created 가 없거나 깨져도 죽지 않는다(0 으로 보고 다른 것에 밀린다).
assert pick([term("no-created", None), old]) == "old", "created 없는 레코드에 밀려선 안 된다"

print("PASS 중복 term: 최신 우선 · detached/죽은 것 제외 · sid·source 격리 · 빈 목록 · created 결측")
PY

echo "PASS test-agent-duplicate-term"
