#!/usr/bin/env bash
# 세션 패널 스캔성 — 스펙 docs/superpowers/specs/2026-07-31-session-panel-scannability-design.md
#   ① 정렬 결함: 예전 구조키가 .sort() 로 순서에 둔감해서, 세션에서 일해 ts 가 올라가도 화면에서
#      위로 안 올라왔다. 이제 reconciler 가 순서를 반영하되 **노드를 재사용**해야 한다(교체 아님).
#   ② 밀도: 간단(기본)에선 부제/미리보기를 CSS 로 가린다 — 토글이 재렌더를 안 부른다.
#   ③ 핀: 워크트리에 붙고 **서버 저장**(세션은 7일이면 사라져 대상이 증발한다).
#   ④ 워크트리 생성: /mobile/api/worktree-create (=/api/* 는 호스트 가드에 막힘).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

# ---------- ① 정렬: 순서 반영 + 노드 재사용 ----------
PYTHONPATH="$SCR" python3 - <<'PY' | node
from marina_mobile import render_mobile_html
import json

html = render_mobile_html()
a, b = html.find("// LIST_RECONCILE_START"), html.find("// LIST_RECONCILE_END")
if a < 0 or b < 0 or b <= a:
    raise SystemExit("LIST_RECONCILE boundaries missing")
print("const src = " + json.dumps(html[a:b]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");

// 최소 DOM — children/insertBefore/removeChild 만 있으면 reconcileKeyed 를 검증할 수 있다.
function makeNode(tag) {
  return {tag, dataset: {}, children: [],
    get firstChild() { return this.children[0] || null; },
    get nextSibling() {
      const p = this.parent; if (!p) return null;
      return p.children[p.children.indexOf(this) + 1] || null;
    },
    insertBefore(node, ref) {
      const i = this.children.indexOf(node); if (i >= 0) this.children.splice(i, 1);
      const at = ref ? this.children.indexOf(ref) : this.children.length;
      this.children.splice(at < 0 ? this.children.length : at, 0, node);
      node.parent = this; return node;
    },
    removeChild(node) {
      const i = this.children.indexOf(node); if (i >= 0) this.children.splice(i, 1);
      node.parent = null; return node;
    }};
}
const ctx = {document: {createElement: makeNode}, Date, Math, String, Number, state: {worktrees: []}};
vm.createContext(ctx);
vm.runInContext(`${src}\nthis.reconcileKeyed = reconcileKeyed; this.relTime = relTime;`, ctx, {filename: "list"});
const {reconcileKeyed, relTime} = ctx;

const container = makeNode("div");
const create = item => { const n = makeNode("div"); n.label = item; n.created = (n.created || 0) + 1; return n; };
const keys = c => c.children.map(n => n.dataset.rkey);

reconcileKeyed(container, ["a", "b", "c"], {key: x => x, create});
assert.deepEqual(keys(container), ["a", "b", "c"]);
const nodeA = container.children[0], nodeB = container.children[1], nodeC = container.children[2];

// 순서만 바뀐 경우 — **같은 노드가 이동**해야 한다(교체하면 스크롤/펼침이 튄다)
reconcileKeyed(container, ["c", "a", "b"], {key: x => x, create});
assert.deepEqual(keys(container), ["c", "a", "b"], "순서가 반영돼야 한다");
assert.equal(container.children[0], nodeC, "노드를 재사용해야 한다(c)");
assert.equal(container.children[1], nodeA, "노드를 재사용해야 한다(a)");
assert.equal(container.children[2], nodeB, "노드를 재사용해야 한다(b)");

// 추가/삭제
reconcileKeyed(container, ["a", "d"], {key: x => x, create});
assert.deepEqual(keys(container), ["a", "d"]);
assert.equal(container.children[0], nodeA, "남은 노드는 그대로");

// patch 는 재사용된 노드에만 불린다
let patched = [];
reconcileKeyed(container, ["a", "d"], {key: x => x, create, patch: (n, item) => patched.push(item)});
assert.deepEqual(patched, ["a", "d"]);

// key 없는 잔재(빈 상태 등)는 정리된다
const stray = makeNode("div"); container.insertBefore(stray, null);
reconcileKeyed(container, ["a"], {key: x => x, create});
assert.deepEqual(keys(container), ["a"], "key 없는 노드는 제거");

// 상대시간
const now = Math.floor(Date.now() / 1000);
assert.equal(relTime(now), "방금");
assert.equal(relTime(now - 120), "2분");
assert.equal(relTime(now - 7200), "2시간");
assert.equal(relTime(now - 90000), "어제");
assert.equal(relTime(0), "", "ts 가 없으면 빈 문자열");
console.log("PASS ① reconciler: 순서 반영 + 노드 재사용 + 추가/삭제 + 잔재 정리 + 상대시간");
''')
PY

# ---------- ②③④ 배선/CSS ----------
PYTHONPATH="$SCR" python3 - <<'PY'
import re
from marina_mobile import render_mobile_html

html = render_mobile_html()

# ① 순서에 둔감했던 옛 구조키가 되살아나면 안 된다
assert "sessionStructureKey" not in html, "순서에 둔감한 구조키가 남아 있으면 정렬이 다시 얼어붙는다"
assert ".sort().join(\"|\")" not in html, "구조키 .sort() 재발"

# ② 밀도 — CSS 로 가리고, 토글은 클래스만 건드린다(재렌더 없음)
assert ".session-list .session-subtitle, .session-list .session-preview { display: none; }" in html
assert ".session-list.density-detail .session-subtitle" in html
assert 'sessionList.classList.toggle("density-detail"' in html, "밀도 토글이 클래스 방식이 아니다"
assert "renderSessions()" not in re.search(r"densityBtn\.onclick = \(\) => \{(.+?)\};", html, re.S).group(1), \
    "밀도 토글이 재렌더를 부르면 스크롤/펼침이 튄다"
assert 'localStorage.setItem("marinaMobileDensity"' in html, "밀도가 기기별로 저장되지 않는다"

# ③ 핀 — 워크트리 단위 + 서버 저장 + 실패 시 되돌림
assert "data-pin-root" in html, "핀 버튼 없음"
assert '"/mobile/api/pins"' in html, "핀 서버 저장 경로 없음"
assert "pinnedRoots = new Set(state.pins || [])" in html, "서버 상태에서 핀을 못 읽는다"
assert "(pinnedRoots.has(b) ? 1 : 0) - (pinnedRoots.has(a) ? 1 : 0)" in html, "핀 우선 정렬이 없다"
assert "if (next) pinnedRoots.delete(root); else pinnedRoots.add(root);" in html, "핀 실패 시 롤백이 없다"

# ④ 워크트리 생성 — 모바일 전용 경로여야 한다(/api/* 는 호스트 가드)
assert '"/mobile/api/worktree-create"' in html, "모바일 워크트리 생성 경로 없음"
assert '"/api/worktree-create"' not in html, "/api/* 를 직접 부르면 펀넬에서 forbidden host 다"
assert 'id="newWorktreeBtn"' in html and 'id="densityBtn"' in html

# 접힘 기본 + 주의 그룹 자동 펼침
assert "node.open = info.asking > 0 || info.busy > 0" in html, "기본 접힘/자동 펼침 규칙이 없다"
# 접혀 있어도 안의 상황이 보여야 한다
assert 'class="wt-flag asking"' in html and 'class="wt-flag busy"' in html, "접힌 그룹의 상태 배지가 없다"

# 질문 대기는 **상태값 하나**로만 말한다. 별도 배지를 또 만들면 같은 뜻이 두 번 나오고,
# hidden 속성은 클래스의 display 에 져서 "죄다 ? 떠있는" 사고가 난다(형이 실제로 겪음).
assert "session-question-badge" not in html, "질문 배지가 되살아났다 — 상태값(blocked)으로만 표기한다"
assert 'const NOTABLE_STATUS = new Set(["blocked", "working", "failed"]);' in html, \
    "압축 모드에서 글자로 보여줄 상태 목록이 없다"
assert ".session-list .session-status.notable .session-status-label { display: inline;" in html, \
    "압축 모드에서 눈여겨볼 상태의 라벨이 안 보인다"
# 그룹 배지도 같은 상태값에서 센다 — 두 진실이 갈리면 카드와 헤더가 어긋난다
assert 'const asking = sessions.filter(s => s.status === "blocked").length;' in html, \
    "그룹 배지가 pendingQuestion 을 따로 센다"
assert 'const busy = sessions.filter(s => s.status === "working").length;' in html

# 응답 필요는 오류가 아니다 — 실패(빨강 ✕)와 색·기호를 둘 다 달리해야 "터진 줄" 알지 않는다.
assert 'blocked:   {dot: "ask",  label: "응답 필요"}' in html, "응답 필요가 실패와 같은 점을 쓴다"
assert 'failed:    {dot: "bad",  label: "실패"}' in html, "실패 점이 바뀌었다"
assert "--st-ask: #0b63ce" in html, "응답 필요 전용 색이 없다"
assert '.wt-dot.ask::after { content: "?"' in html, "응답 필요 전용 기호가 없다(색만으론 구분이 약하다)"
assert '.wt-dot.bad::after { content: "✕"' in html, "실패 기호가 바뀌었다"
assert 'dot: asking ? "ask"' in html, "그룹 점도 같은 뜻이어야 한다"

# 라벨이 '대화 추가'임을 드러내야 한다(형이 '＋'를 '워크트리 만들기'로 읽었던 혼선).
# 이제 헤더 버튼이 아니라 ⋯ 시트 항목이라 축약 없이 온전한 문장을 쓴다.
assert "Claude 대화 추가" in html and "Codex 대화 추가" in html, "대화 추가 라벨이 모호하다"

print("PASS ②③④ 배선: 밀도(CSS·기기별) · 핀(워크트리·서버·롤백) · 워크트리 생성(모바일 경로) · 접힘/배지/라벨")
PY

# ---------- 서버: 핀 저장 ----------
PYTHONPATH="$SCR" python3 - <<'PY'
from pathlib import Path
import marina_mobile as mm

root = Path("/tmp/wt-pin-a")
other = Path("/tmp/wt-pin-b")
mm.safe_root = lambda value: Path(value)

assert mm.mobile_pins() == [], "처음엔 비어 있어야 함"
mm.mobile_set_pin({"root": str(root), "pinned": True})
assert mm.mobile_pins() == [str(root.resolve())], mm.mobile_pins()
mm.mobile_set_pin({"root": str(other), "pinned": True})
assert mm.mobile_pins()[0] == str(other.resolve()), "새로 꽂은 게 앞"
assert len(mm.mobile_pins()) == 2
mm.mobile_set_pin({"root": str(root), "pinned": True})       # 중복 방지
assert len(mm.mobile_pins()) == 2, mm.mobile_pins()
mm.mobile_set_pin({"root": str(root), "pinned": False})
assert mm.mobile_pins() == [str(other.resolve())], mm.mobile_pins()

# 파일이 깨져도 죽지 않는다
mm.PINS_FILE.write_text("not json", encoding="utf-8")
assert mm.mobile_pins() == []
print("PASS 서버 핀 저장: 추가/중복방지/해제/최신우선 + 깨진 파일 내성")
PY

# ---------- 서버: 라우트가 모바일 표면에 있다 ----------
# 경로가 **각각** 있는지 본다. 예전엔 세 경로가 한 줄에 붙은 모양을 통째로 grep 했는데,
# 경로가 하나 늘어 줄바꿈이 생기자 기능은 멀쩡한데 테스트만 깨졌다 — 배치가 아니라 사실을 본다.
for route in /mobile/api/pins /mobile/api/hidden /mobile/api/worktree-create; do
  grep -q "\"$route\"" "$SCR/marina_handler.py" \
    || { echo "FAIL: 모바일 라우트 미등록 ($route)"; exit 1; }
done
grep -q 'def _worktree_create' "$SCR/marina_handler.py" \
  || { echo "FAIL: 워크트리 생성이 웹/모바일 공용 함수로 분리되지 않음"; exit 1; }
grep -q 'self._worktree_create(controller, principal, body)' "$SCR/marina_handler.py" \
  || { echo "FAIL: 웹 경로가 공용 함수를 안 쓴다(중복 구현)"; exit 1; }
echo "PASS 라우트: /mobile/api/{pins,worktree-create} + 웹·모바일 공용 구현"



# ---------- ⑤ 전체보기 · 숨기기 · 작업중 오탐 ----------
PYTHONPATH="$SCR" python3 - <<'PY'
import time
from pathlib import Path
import marina_sessions as ms
import marina_mobile as mm

# (1) "작업 중" 은 그 세션 트랜스크립트가 최근에 쓰였을 때만. 워크트리에 무관한 프로세스가 살아 있어도
#     오래 조용하면 작업 중이 아니다(실측: 8일째 떠 있던 claude 하나가 같은 root 세션을 전부 작업중으로).
now = time.time()
root = Path("/w")
live = {root}
fresh = ms.resolve_session_liveness("claude", "s1", root, native={"status": "working", "statusTs": now - 5},
                                    event=None, live_cwds=live, live_tids={}, now=now)
stale = ms.resolve_session_liveness("claude", "s1", root, native={"status": "working", "statusTs": now - 8 * 86400},
                                    event=None, live_cwds=live, live_tids={}, now=now)
blocked = ms.resolve_session_liveness("claude", "s1", root, native={"status": "blocked", "statusTs": now - 8 * 86400},
                                      event=None, live_cwds=live, live_tids={}, now=now)
assert fresh["status"] == "working", fresh
assert stale["status"] == "idle" and stale["reason"] == "오래 조용함", stale
assert blocked["status"] == "blocked", f"답 기다리는 중엔 조용한 게 정상이라 강등하면 안 된다: {blocked}"

# (2) 전체보기는 더 넓은 창을 훑는다(기본 7일 / 전체 90일) — 캐시 칸도 따로 써야 기본 폴링이 안 느려진다.
assert ms.AGENTS_MAX_AGE < ms.AGENTS_MAX_AGE_ALL, "전체보기 창이 기본보다 넓어야 한다"
import inspect
src = inspect.getsource(ms.claude_agent_sessions)
assert "include_all" in src and "_claude_agents_all_cache" in src, "전체보기 캐시가 분리되지 않았다"
# 소속 확인은 넓은 색인으로 — 오래된 세션에 전송이 막히면 전체보기가 반쪽이 된다
belongs = inspect.getsource(ms.agent_belongs_to_root)
assert "claude_agent_sessions(refresh, True)" in belongs, "소속 확인이 좁은 색인을 쓴다"

# (3) 숨기기: 서버 저장 · 토글 · 기본 목록에서 제외 · 전체보기에선 포함
assert mm.mobile_hidden() == []
mm.mobile_set_hidden({"source": "claude", "sid": "abc", "hidden": True})
assert mm.mobile_hidden() == ["claude:abc"], mm.mobile_hidden()
mm.mobile_set_hidden({"source": "claude", "sid": "abc", "hidden": True})    # 중복 방지
assert mm.mobile_hidden() == ["claude:abc"]
mm.mobile_set_hidden({"source": "claude", "sid": "abc", "hidden": False})
assert mm.mobile_hidden() == []
for bad in ({"source": "nope", "sid": "x"}, {"source": "claude", "sid": ""}):
    try:
        mm.mobile_set_hidden({**bad, "hidden": True})
    except ValueError:
        pass
    else:
        raise AssertionError(bad)
mm.HIDDEN_FILE.write_text("not json", encoding="utf-8")
assert mm.mobile_hidden() == [], "깨진 파일에도 죽지 않아야"
mm.HIDDEN_FILE.unlink(missing_ok=True)
print("PASS ⑤ 작업중 오탐 강등 + 전체보기 창/캐시 분리 + 숨기기 저장")
PY

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_mobile import render_mobile_html
html = render_mobile_html()
assert 'id="showAllBtn"' in html, "전체보기 버튼 없음"
assert '`/mobile/api/state${showAll ? "?all=1" : ""}`' in html, "전체보기가 서버에 안 전달된다"
assert '"/mobile/api/hidden"' in html, "숨기기 경로 없음"
assert 'sessionList.addEventListener("contextmenu"' in html, "길게 누르기/오른쪽 클릭 숨기기 없음"
assert ".session-list:not(.show-all) .session-card.hidden-session { display: none; }" in html, \
    "숨긴 세션이 기본 목록에서 안 빠진다"
assert "if (next) hiddenSessions.delete(key); else hiddenSessions.add(key);" in html, "숨기기 실패 롤백 없음"
assert "hiddenSessions = new Set(state.hidden || [])" in html, "서버 숨김 목록을 안 읽는다"
print("PASS ⑤ 배선: 전체보기 토글 + 숨기기(롤백 포함) + 기본 목록 제외")
PY
echo "PASS test-session-panel"
