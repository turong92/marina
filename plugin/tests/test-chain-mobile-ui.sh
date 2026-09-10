#!/usr/bin/env bash
# 폰 화면 요소(스펙 7.2) — 고정 줄·배지·딸린 줄·메뉴. 역할 방은 "대화 N개"에 안 센다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
PYTHONPATH="$SCR" python3 - <<'PY'
import marina_chains as C
import marina_mobile as MM
imp = {"root": "/wt", "source": "claude", "sid": "impl", "socket": "uds:/x"}
c = C.new_chain(role="reviewer", implementer=imp, base={"p": "a"}, head={"p": "b"}, max_rounds=2, unlimited=False, now=1000.0, anchor=0)
c["roleRoom"] = {"tid": "t1", "model": "claude-sonnet-5"}; c["held"] = ["[보류] x"]
C.save_chain(c)
s = MM._session_chain_summary("claude", "impl", now=1001.0)
assert s["state"] == "reviewing" and s["round"] == 1 and s["heldCount"] == 1 and s["roleModel"] == "claude-sonnet-5", s
c["state"] = "done"; c["endedAt"] = 1002.0; c["endedReason"] = "clean"; C.save_chain(c)
assert MM._session_chain_summary("claude", "impl", now=1500.0)["state"] == "done"
assert MM._session_chain_summary("claude", "impl", now=1002.0 + 601) is None, "끝난 지 10분 넘은 묶음을 보여준다"
assert MM._session_chain_summary("claude", "nobody", now=1001.0) is None
print("PASS: 세션 묶음 요약")
PY

python3 - "$SCR" <<'PY' | node
import json, sys
from pathlib import Path
src = (Path(sys.argv[1]) / "marina_mobile.py").read_text(encoding="utf-8")
helpers = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
def block(tag, text=src):
    a, b = text.find(f"// {tag}_START"), text.find(f"// {tag}_END")
    if a < 0 or b < 0: raise SystemExit(f"{tag} 경계 없음")
    return text[a:b]
code = block("ESC_HELPERS", helpers) + block("STATUS_REASON") + block("ROOM_LIST") + block("ROOM_TABS") + block("CHAIN_STRIP")
print("const src = " + json.dumps(code) + ";")
print(r'''
const vm = require("vm"), assert = require("assert/strict");
const ctx = {}; vm.createContext(ctx);
vm.runInContext(src + "\nthis.renderRooms=renderRooms; this.renderChatMenu=renderChatMenu; this.renderChainStrip=renderChainStrip;", ctx);
const room = {root: "/pay", name: "결제", shortName: "결제", status: "작업중", lastAt: 1, chain: {state: "reviewing", round: 1, maxRounds: 2, unlimited: false},
  tabs: [{title: "쿠폰", source: "claude", sid: "impl", primary: true, chainEnabled: true},
         {title: "리뷰어", source: "claude", sid: "role", roleOf: {chainId: "c1", role: "reviewer"}}]};
const html = ctx.renderRooms([room], 10, false, "", "", "/pay", [{id: "claude", label: "Claude"}]);
assert.match(html, /class="roomChainBadge"[^>]*>🔁 리뷰 1\/2/, "배지 없음");
assert.match(html, />대화 1개/, "역할 방을 대화 수에 셌다");
assert.match(html, /class="roleRow"/, "딸린 줄 없음");
assert.ok(!/data-tab="claude:role"/.test(html), "역할 방을 일반 대화 줄로 그렸다");
assert.match(ctx.renderChatMenu("claude:impl", room.tabs[0]), /data-chain-request="claude:impl"/);
assert.ok(!/data-chain-request/.test(ctx.renderChatMenu("claude:x", {title: "x"})), "역할 없는 방에 리뷰 보내기");
const strip = ctx.renderChainStrip({chain: {state: "applying", role: "reviewer", round: 1, maxRounds: 2, unlimited: false}});
assert.match(strip, /리뷰 도는 중/); assert.match(strip, /data-chain-action="unlimited"/); assert.match(strip, /data-chain-action="stop"/);
assert.match(ctx.renderChainStrip({chain: {state: "reviewing", role: "reviewer", round: 3, maxRounds: 2, unlimited: true}}), /class="chipBtn on"[^>]*data-chain-action="unlimited"|data-chain-action="unlimited"[^>]*class="chipBtn on"/);
assert.equal(ctx.renderChainStrip({chain: {state: "done"}}), "");
assert.equal(ctx.renderChainStrip({}), "");
console.log("PASS: 배지·딸린 줄·메뉴·고정 줄");
''')
PY
bash "$HERE/test-mobile-element-refs.sh" >/dev/null && echo "PASS: 엘리먼트 참조"
bash "$HERE/test-room-accordion.sh" >/dev/null && echo "PASS: 기존 아코디언 계약"

# 방 메뉴 처리기 — vm 블록 밖이라 정적으로 본다. 한때 첫 줄에 정의 안 된 session 을 읽어 모든 방 동작이 죽었다.
python3 - "$SCR" <<'PY'
import re, sys
from pathlib import Path
src = (Path(sys.argv[1]) / "marina_mobile.py").read_text(encoding="utf-8")
a = src.index("    async function handleRoomAction(target) {")
body = src[a:src.index("\n    }\n", a)]
assert 'target.hasAttribute("data-chain-request")' in body, "리뷰 보내기 분기 없음"
assert "renderChainStrip(" not in body and not re.search(r"\bsession\b(?!s)", body.split("\n", 1)[1].split("\n", 1)[0]), "처리기 첫 줄이 session 을 읽는다"
strip = src[src.index('chainStripEl.addEventListener("click"'):]
strip = strip[:strip.index("\n    });\n")]
assert 'classList.contains("on")' in strip and "on})" in strip, "끝까지가 켜기만 한다(토글 아님)"
print("PASS: 방 메뉴 처리기·끝까지 토글")
PY

# 방 조립(서버) — 결과 오기 전 장부엔 역할 방 sid 가 없다. term 기록(tid)으로 찾아야 리뷰어가 딸린 줄이 된다.
PYTHONPATH="$SCR" python3 - <<'PY'
import marina_mobile as MM
import marina_chain_runtime as RT
import marina_term
chains = [{"id": "c1", "role": "reviewer", "state": "reviewing", "round": 1, "maxRounds": 2, "unlimited": False,
           "implementer": {"sid": "impl"}, "roleRoom": {"tid": "t1", "model": "m"}}]
marina_term.term_list = lambda: {"sessions": [{"tid": "t0", "agent": {"sid": "x"}}, {"tid": "t1", "agent": {"sid": "rsid"}}]}
assert RT.role_room_sid(chains[0]) == "rsid", "tid 로 역할 방 sid 를 못 찾는다"
assert RT.role_room_sid({"roleRoom": {"sid": "s9", "tid": "t1"}}) == "s9"
assert RT.role_room_sid({"roleRoom": {}}) == ""
room = {"tabs": [{"sid": "impl"}, {"sid": "rsid"}, {"sid": "other"}]}
MM._decorate_room_chain(room, chains, True, RT.role_room_sid)
assert room["tabs"][1]["roleOf"] == {"chainId": "c1", "role": "reviewer"}, room
assert room["tabs"][1]["chainEnabled"] is False, "리뷰어 방에 리뷰 보내기가 뜬다"
assert room["tabs"][0]["chainEnabled"] is True and "roleOf" not in room["tabs"][0]
assert room["chain"] == {"state": "reviewing", "round": 1, "maxRounds": 2, "unlimited": False}
off = {"tabs": [{"sid": "impl"}]}
MM._decorate_room_chain(off, [], False, RT.role_room_sid)
assert off["chain"] is None and off["tabs"][0]["chainEnabled"] is False
print("PASS: 방 조립 — 역할 방 sid 를 term 기록으로")
PY
