#!/usr/bin/env bash
# 같은 세션을 두 번 resume 하지 않는다 — 중복 프로세스의 근본 차단.
#
# **어쩌다 생겼나.** term_open 의 재사용 키가 이랬다:
#     key = "" if (agent_prompt or not agent_sid) else ...
# 즉 프롬프트를 실어 보내면 키가 비어 재사용 검사가 통째로 꺼졌다. 그런데 mobile_send 는
# resume 할 때 **늘** 프롬프트를 싣는다 — 방지 장치가 필요한 순간에만 꺼져 있었던 셈이다.
# 실측(2026-08-11): 한 sid 에 claude 가 둘 살아남았고(15:59·16:06), 조회가 버려진 쪽을 집으면
# 형이 모바일로 보낸 메시지가 영영 도착하지 않았다("왜 너만 모바일로 메세지를 안먹냐").
#
# 키가 비면 _by_key 등록도 안 돼서 이후 조회도 실패한다 — 문제가 겹친다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - "$SCR" <<'PY'
import sys
from pathlib import Path

scr = Path(sys.argv[1])
term_src = (scr / "marina_term.py").read_text(encoding="utf-8")
mobile_src = (scr / "marina_mobile.py").read_text(encoding="utf-8")

# ① prompt attach 가 새 턴으로 뜨는 건 **의도된 동작**이다 — 재사용 금지를 되돌리면 안 된다.
#    (CLI 의 prompt 인자로 시작하므로 이미 돌고 있는 TUI 에는 붙일 수가 없다.)
assert 'key = "" if (agent_prompt or not agent_sid) else' in term_src, \
    "prompt attach 의 새-턴 계약이 깨졌다 — test-term 이 잠그는 동작이다"

# ② 같은 sid 의 **detached** term 은 거둔다. detached 는 fd 를 잃어 입력이 안 들어가는데도 살아있어,
#    _live_agent_tid 가 빈손 → 호출자가 resume 을 한 번 더 띄움 → 한 sid 에 둘이 남는다.
window = term_src[term_src.find("if key:"):term_src.find("pid, fd = pty.fork()")]
assert "if agent_sid:" in window, "같은 sid 의 옛 term 을 찾지 않는다"
assert "other.detached" in window, "detached 만 거둬야 한다 — 조건이 빠지면 진행 중인 턴을 죽인다"
assert "retire.append(other.tid)" in window, "정리 목록에 넣지 않는다"
assert "term_kill(tid)" in term_src, "실제로 거두지 않는다 — 중복이 그대로 남는다"
assert "other.root == cwd" in window, "다른 워크트리의 같은 sid 까지 죽이면 안 된다"

# ③ **attached 인 옛 term 은 건드리면 안 된다** — 진행 중인 턴을 새 전송이 죽이는 셈이 된다.
#    (test-term 이 "prompt attach 는 각자 살아서 각자 프롬프트를 처리한다"를 잠근다.)
assert "other.alive and other.detached" in window, \
    "alive 만 보고 거두면 남의 턴을 죽인다 — detached 조건이 반드시 함께 와야 한다"

# ③ 재사용됐으면 프롬프트가 CLI 인자로 안 실렸다 — 호출부가 타이핑으로 넣어야 한다.
#    예전엔 무조건 실린 걸로 쳐서, 재사용 분기에 걸리면 메시지가 조용히 사라졌다.
assert "prompt_submitted = opened" in mobile_src, \
    "재사용 시 프롬프트를 다시 넣지 않는다 — 형 메시지가 조용히 사라진다"
assert "prompt_submitted = True" not in mobile_src.split("result = term_open(")[1][:400], \
    "재사용 여부와 무관하게 보냈다고 치는 옛 코드가 남아 있다"

print("PASS resume 중복 차단: 키는 sid 만 · detached 는 정리 후 재생성 · 재사용 시 프롬프트 재전달")
PY

echo "PASS test-agent-resume-dedupe"
