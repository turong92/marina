#!/usr/bin/env bash
# 살아 있는 질문은 **시간이 지났다고 사라지지 않는다.**
#
# 형이 겪은 것(2026-08-18): ai-api 워크트리에서 물어봤는데 폰에는 질문 카드가 아예 안 뜨고
# 터미널에 가야 보였다. 원인은 만료 상한 15분이었다 — 훅은 질문을 제대로 기록했지만, 형이
# 15분 안에 폰을 안 보면 마리나가 카드를 내려버렸다. 터미널은 계속 보여주는데.
#
# 상한의 원래 목적은 **고아 방지**다(세션이 죽어 PostToolUse 가 영영 안 오는 경우).
# 그건 나이가 아니라 **세션이 살아 있는지**로 판단해야 한다 — 살아 있으면 그 질문은 여전히
# 형을 기다리는 중이고, 죽었으면 나이와 무관하게 의미가 없다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import json
import time

import marina_mobile as mm

SID = "live-session-1"
mm.AGENT_QUESTIONS_DIR.mkdir(parents=True, exist_ok=True)


def 질문쓰기(sid, 나이초):
    path = mm.AGENT_QUESTIONS_DIR / f"claude-{sid}.json"
    path.write_text(json.dumps({
        "sid": sid, "toolUseId": "toolu_x", "ts": time.time() - 나이초,
        "questions": [{"question": "어떤 방식으로 진행할까요?", "header": "방식",
                       "options": [{"label": "A"}, {"label": "B"}]}],
    }, ensure_ascii=False), encoding="utf-8")


# ① 방금 온 질문은 당연히 보인다.
질문쓰기(SID, 5)
assert mm.mobile_pending_question("claude", SID), "방금 온 질문이 안 보인다"

# ② **살아 있는 세션의 질문은 몇 시간이 지나도 남는다.** 여기가 형이 겪은 자리다 —
# 폰을 15분 안에 못 보면 질문이 사라졌다.
살아있음 = lambda source, sid: {"pid": 1234, "sid": sid}
mm._agent_proc_lookup = 살아있음
질문쓰기(SID, 3 * 3600)
assert mm.mobile_pending_question("claude", SID), \
    "살아 있는 세션인데 시간이 지났다고 질문을 내렸다 — 폰엔 안 보이고 터미널엔 보인다"

# ③ 세션이 죽었으면 내린다. 답할 상대가 없는 카드는 눌러봐야 아무 일도 안 난다.
mm._agent_proc_lookup = lambda source, sid: None
질문쓰기(SID, 3 * 3600)
assert mm.mobile_pending_question("claude", SID) is None, "죽은 세션의 질문이 남아 있다"

# ④ 죽은 세션이어도 **방금 온 것**은 보여준다 — 등록이 아직 안 됐을 수 있다(입양 전).
# 여기서 성급하게 내리면 손으로 띄운 세션의 첫 질문을 놓친다.
질문쓰기(SID, 5)
assert mm.mobile_pending_question("claude", SID), "등록 전 세션의 새 질문을 놓친다"

# ⑤ 상한 자체는 남아 있어야 한다 — 살아 있는지 알 수 없을 때의 안전장치다.
assert mm._QUESTION_STALE_S >= 900, mm._QUESTION_STALE_S
print("ok 질문 만료: 살아 있으면 남고, 죽으면 내리고, 새 것은 항상 보인다")
PY

echo "PASS test-question-liveness"
