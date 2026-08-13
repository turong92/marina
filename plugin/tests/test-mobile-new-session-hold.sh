#!/usr/bin/env bash
# 새 대화를 시작하면 **그 자리에 머문다** — 형: "새 대화 시작할 때 왜 밖으로 나가져,
# 그냥 여기서 기다렸다가 계속 이어서 하면 되는데".
#
# **왜 나갔나.** render 는 매 폴마다 `selectedSession()` 이 없으면 곧장 목록으로 되돌린다.
# 그런데 새로 연 대화는 잠깐 어느 목록에도 없다 — ① PTY 를 띄운 직후엔 서버가 아직 안 싣고,
# ② 첫 지시로 승격되는 순간엔 term 카드가 빠지고 agent 카드가 tid 를 달기까지 폴 한 번이 빈다.
# 그 한 번을 "사라졌다"로 읽어서 시작하자마자 튕겼다. 사라진 게 아니라 **오는 중**이다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from marina_mobile import render_mobile_html          # noqa: E402

html = render_mobile_html()
start, end = html.find("// SESSION_HOLD_START"), html.find("// SESSION_HOLD_END")
if start < 0 or end < 0 or end <= start:
    raise SystemExit("SESSION_HOLD 경계가 없다 — 판정이 render 안에 박혀 있으면 검증할 수 없다")
print("const holdSource = " + json.dumps(html[start:end]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const context = {};
vm.createContext(context);
vm.runInContext(`${holdSource}
this.holdSession = holdSession;
this.SESSION_HOLD_MS = SESSION_HOLD_MS;`, context, {filename: "marina_mobile.py::session-hold"});
const {holdSession, SESSION_HOLD_MS} = context;

const held = {key: "term:t1", title: "새 대화 (시작 중…)"};
const now = 1_000_000;

// 1) 실물이 있으면 그게 진실 — 붙들어둔 건 쓰지 않는다.
const live = {key: "term:t1", title: "실물"};
assert.equal(holdSession(live, held, now, "term:t1", now, SESSION_HOLD_MS), live);

// 2) 폴 한 번 빠졌다 → 화면을 지킨다(이게 "밖으로 안 나가진다").
assert.equal(holdSession(null, held, now - 3000, "term:t1", now, SESSION_HOLD_MS), held);

// 3) 유예가 끝나면 놓아준다 — 진짜 사라진 세션을 영영 붙들면 유령 화면이 된다.
assert.equal(holdSession(null, held, now - SESSION_HOLD_MS - 1, "term:t1", now, SESSION_HOLD_MS), null);

// 4) 다른 세션을 고른 뒤엔 남의 화면을 붙들지 않는다.
assert.equal(holdSession(null, held, now, "claude:sid-9", now, SESSION_HOLD_MS), null);

// 5) 선택이 비었으면(목록으로 나간 상태) 아무것도 붙들지 않는다.
assert.equal(holdSession(null, held, now, "", now, SESSION_HOLD_MS), null);

console.log("ok 기동·승격 틈에도 대화 화면을 지킨다");
''')
PY

html="$(PYTHONPATH="$SCR" python3 -c 'from marina_mobile import render_mobile_html; print(render_mobile_html())')"

# ① render 가 실제로 그 판정을 쓴다 — 헬퍼만 있고 안 쓰면 아무것도 안 고쳐진 것이다.
grep -qF 'holdSession(live, heldSession, heldSessionAt, selectedSessionKey' <<<"$html" \
  || { echo "FAIL: render 가 holdSession 을 쓰지 않는다 — 폴 한 번에 여전히 튕긴다"; exit 1; }

# ② 새 세션 진입 경로는 하나다. 손수 만든 두 번째 경로는 탭 등록도 history 푸시도 빠뜨렸다.
launch="$(sed -n '/async function launchAgent/,/^    }$/p' <<<"$html")"
grep -qF 'chooseSession(`term:${d.tid}`)' <<<"$launch" \
  || { echo "FAIL: 런치가 chooseSession 을 거치지 않는다 — 탭·히스토리가 갈린다"; exit 1; }
! grep -qF 'showChat(); render();' <<<"$launch" \
  || { echo "FAIL: 런치에 손수 만든 두 번째 진입 경로가 남아 있다"; exit 1; }

# ③ 보고 있는 탭은 폴 한 번 빠져도 지운다 — 돌아왔을 때 탭이 없어져 있으면 안 된다.
grep -qF 'openTabs.filter(key => key === selectedSessionKey || sessions.some' <<<"$html" \
  || { echo "FAIL: 활성 탭이 폴 한 번에 정리된다"; exit 1; }

echo "PASS test-mobile-new-session-hold"
