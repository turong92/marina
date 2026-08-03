# web·mobile 정합 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **이 레포 규칙:** 구현은 Claude 가 직접(Edit/Write) 한다. 서브에이전트에 통째로 위임하지 않는다. 리뷰만 codex 에 맡긴다.

**Goal:** marina 의 web·mobile 두 프론트엔드를 정합시킨다 — 웹에 대화 워크스페이스(브라우저식 세션 멀티탭 · 이미지 · 질문카드 · 전송)를 붙이고, claude/codex CLI 버전 업데이트를 양쪽 배너로 노출하고, 모바일에 로그·깃 읽기를 준다.

**Architecture:** 백엔드는 기존 `/mobile/api/*` 라우트에 `/api/agent/*` 경로 별칭과 인증 술어 하나를 더해 웹·모바일이 같은 구현을 공유한다. 프론트는 모바일의 타임라인 렌더러를 `/web/chat-render.js` 로 추출해 양쪽이 같은 마크업 계약을 쓰게 한다(재분기 방지). 웹 대화 워크스페이스는 열어 둔 에이전트 세션을 브라우저 탭처럼 여러 개 띄우고 탭마다 커서·스크롤·초안을 독립으로 들고 있으며, 폴링은 활성 탭 하나만 한다. CLI 버전은 신규 `marina_cliver.py` 가 `--version` 과 npm registry 를 비교해 기존 `/api/update-status` 페이로드에 얹는다.

**Tech Stack:** Python 3.9 표준 라이브러리만 (`http.server`, `urllib`, `subprocess`), 클래식 `<script>` JS (번들러 없음, 파일 간 전역 스코프 공유), bash 테스트.

**Spec:** `docs/superpowers/specs/2026-08-03-web-mobile-parity-design.md`

## Global Constraints

- Python 은 **3.9** 기준이다. `tomllib` 없음, `match` 없음, `X | Y` 런타임 제네릭 금지(`from __future__ import annotations` 는 이미 쓰고 있으니 어노테이션에는 가능).
- 외부 의존성 추가 금지. 표준 라이브러리만.
- 모든 `plugin/tests/test-*.sh` 는 **첫 줄 셸뱅 다음에** `. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"` 를 반드시 소스한다. 실 `~/.marina` 오염 금지.
- 사용자 대면 문자열은 **한국어**. 기존 톤(반말 아님, `~해요` 체)을 따른다.
- `marina-web/*.js` 는 클래식 스크립트다. `import`/`export` 금지. 단 `chat-render.js` 는 모바일과 공유하므로 **IIFE + `window.MarinaChat`** 로 캡슐화한다.
- 기존 `/mobile/api/*` 경로·응답은 **불변**이다. 모바일 회귀는 실패로 간주한다.
- 커밋 메시지는 한국어 제목 + 본문, 끝에 `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- 테스트 실행: `cd plugin/tests && bash test-<name>.sh` (개별), 전체는 `for f in plugin/tests/test-*.sh; do bash "$f"; done`.

## File Structure

**생성**

| 파일 | 책임 |
|---|---|
| `plugin/scripts/marina_cliver.py` | claude/codex CLI 설치본·최신 버전 조회, 설치 방식 판별, 업데이트 명령 실행 |
| `plugin/scripts/marina-web/chat-render.js` | 타임라인 렌더러 (웹·모바일 공유). `window.MarinaChat` 노출 |
| `plugin/scripts/marina-web/app-11-chat.js` | 웹 대화 탭 — 세션 셀렉터, `[대화\|원본]` 토글, 폴링, 컴포저 |
| `plugin/tests/test-agent-api-dual-prefix.sh` | `/api/agent/*` ≡ `/mobile/api/*` |
| `plugin/tests/test-cli-version.sh` | 버전 파싱·behind 판정·설치방식 매핑·busy 가드 |
| `plugin/tests/test-chat-render-shared.sh` | 렌더러 추출이 되돌아가지 않게 잠금 |
| `plugin/tests/test-mobile-logs-git.sh` | 모바일 읽기 라우트 권한·페이로드, 쓰기 라우트 부재 |

**수정**

| 파일 | 무엇 |
|---|---|
| `plugin/scripts/marina_handler.py` | `/api/agent/*` 별칭, `_agent_api_ok`, `/mobile/api/update-status`, `/mobile/api/logs/*`, `/mobile/api/git-*`, `cli-update` |
| `plugin/scripts/marina_update.py` | `update_status()` 페이로드에 `cli` 키 병합 |
| `plugin/scripts/marina_mobile.py` | 렌더러 함수 제거 + `<script src>` 로드, CLI 배너, 로그·깃 시트 |
| `plugin/scripts/marina-web/index.html` | `대화` 탭 버튼·pane, 스크립트 태그 2개 |
| `plugin/scripts/marina-web/app-5-sessions.js` | AGENTS 행 클릭 → 대화 탭 |
| `plugin/scripts/marina-web/app-10-term.js` | 셸 사이드바에서 에이전트 PTY 제외, `mountAgentTerm` 추출 |
| `plugin/scripts/marina-web/app-6-modals.js` | `openAgentTranscript` 삭제, 배너에 CLI 섹션 |
| `plugin/scripts/marina-web/styles.css` | 대화 탭·타임라인 스킨 |

---

## Phase 1 — 백엔드 이중 프리픽스

### Task 1: `/api/agent/*` 경로 별칭과 인증 술어

**Files:**
- Modify: `plugin/scripts/marina_handler.py` (do_GET 진입부 `:325-337`, do_POST 진입부 `:1154-1167`, 모바일 라우트 17곳의 인증 검사)
- Test: `plugin/tests/test-agent-api-dual-prefix.sh`

**Interfaces:**
- Consumes: `mobile_request_ok(handler, parsed)` (`marina_mobile.py:404`), `is_loopback_client(handler)` (`marina_auth_http.py:30`)
- Produces: `Handler._agent_api_ok(self, parsed, principal) -> bool`, `Handler._agent_api_alias(self, parsed) -> urllib.parse.ParseResult`. 이후 모든 태스크가 `/api/agent/<op>` 로 웹에서 에이전트 API 를 부른다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`plugin/tests/test-agent-api-dual-prefix.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import urllib.parse
import marina_handler as mh

H = mh.Handler


class FakeHandler:
    """Handler 의 메서드만 빌려 쓰는 최소 스텁 — 소켓 없이 술어만 검증한다."""
    def __init__(self, loopback=True, token=""):
        self._loopback = loopback
        self.headers = {"x-marina-mobile-token": token} if token else {}
        self.client_address = ("127.0.0.1" if loopback else "10.0.0.5", 1234)

    _agent_api_ok = H._agent_api_ok
    _agent_api_alias = H._agent_api_alias


# 1) 경로 별칭 — /api/agent/<op> 가 /mobile/api/<op> 로 정규화되고 웹 플래그가 선다
h = FakeHandler()
parsed = h._agent_api_alias(urllib.parse.urlparse("/api/agent/send?root=/x"))
assert parsed.path == "/mobile/api/send", parsed.path
assert parsed.query == "root=/x", parsed.query
assert h._agent_api_web is True

# 2) 별칭이 아닌 경로는 건드리지 않는다
h2 = FakeHandler()
p2 = h2._agent_api_alias(urllib.parse.urlparse("/mobile/api/send"))
assert p2.path == "/mobile/api/send"
assert getattr(h2, "_agent_api_web", False) is False

# 3) 웹 경로 + 루프백 + auth 꺼짐(principal None) → 통과 (모바일 토큰 불필요)
h3 = FakeHandler(loopback=True)
h3._agent_api_alias(urllib.parse.urlparse("/api/agent/send"))
assert h3._agent_api_ok(urllib.parse.urlparse("/mobile/api/send"), None) is True

# 4) 웹 경로 + 비루프백 + principal 없음 → 거부
h4 = FakeHandler(loopback=False)
h4._agent_api_alias(urllib.parse.urlparse("/api/agent/send"))
assert h4._agent_api_ok(urllib.parse.urlparse("/mobile/api/send"), None) is False

# 5) 모바일 경로 + 토큰 없음 → 거부, 올바른 토큰 → 통과
import marina_mobile as mm
token = mm.ensure_mobile_token()
h5 = FakeHandler(loopback=False)
assert h5._agent_api_ok(urllib.parse.urlparse("/mobile/api/send"), None) is False
h6 = FakeHandler(loopback=False, token=token)
assert h6._agent_api_ok(urllib.parse.urlparse("/mobile/api/send"), None) is True

# 6) principal 이 있으면 경로·루프백과 무관하게 통과
h7 = FakeHandler(loopback=False)
assert h7._agent_api_ok(urllib.parse.urlparse("/mobile/api/send"), object()) is True

# 7) 옛 모바일 인증 검사가 라우트에 남아 있지 않다 — 전부 술어로 교체됐는지
src = open(mh.__file__, encoding="utf-8").read()
assert "principal is None and not mobile_request_ok" not in src, \
    "모바일 라우트에 옛 인증 검사가 남아 있다 — _agent_api_ok 로 교체해야 한다"
print("ok")
PY
```

`FakeHandler.headers` 는 dict 이고 `mobile_request_ok` 는 `handler.headers.get(...)` 만 쓰므로 그대로 동작한다. `is_loopback_client` 가 `client_address` 를 본다는 전제는 다음 스텝에서 확인한다.

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd plugin/tests && bash test-agent-api-dual-prefix.sh
```
Expected: FAIL — `AttributeError: type object 'Handler' has no attribute '_agent_api_ok'`

- [ ] **Step 3: `is_loopback_client` 가 무엇을 읽는지 확인하고 스텁을 맞춘다**

```bash
sed -n '30,40p' plugin/scripts/marina_auth_http.py
```
`client_address` 외의 필드(예: `headers` 의 `x-forwarded-for`)를 본다면 Step 1 의 `FakeHandler` 에 그 필드를 더해 실제 계약과 맞춘다. 스텁이 실제와 어긋나면 테스트가 거짓 통과한다.

- [ ] **Step 4: 두 메서드를 구현한다**

`marina_handler.py` 의 `Handler` 클래스 안, `_policy` 바로 위(`:182` 근처)에 넣는다:

```python
    # ── 에이전트 API 이중 프리픽스 ──
    # 웹은 /mobile/api/* 를 못 부른다(auth 꺼진 로컬에서 principal=None → 모바일 토큰 검사에 걸림).
    # 모바일은 /api/* 를 못 부른다(host_guarded 가 펀넬 호스트를 막음). 그래서 웹 전용 별칭
    # /api/agent/<op> 를 /mobile/api/<op> 로 정규화해 **같은 라우트 본문**을 공유한다.
    _AGENT_API_ALIAS = "/api/agent/"

    def _agent_api_alias(self, parsed: urllib.parse.ParseResult) -> urllib.parse.ParseResult:
        if not parsed.path.startswith(self._AGENT_API_ALIAS):
            return parsed
        self._agent_api_web = True
        return parsed._replace(path="/mobile/api/" + parsed.path[len(self._AGENT_API_ALIAS):])

    def _agent_api_ok(self, parsed: urllib.parse.ParseResult, principal: Any) -> bool:
        """에이전트 API 인증. 웹 경로는 이미 host_guarded(POST 는 origin/CSRF 도)를 통과했으므로
        모바일 토큰을 요구하지 않는다. 자원 권한(_require_root_access·can_resource)은 라우트 본문에서
        종전대로 검사하므로 이 술어는 '이 표면에 말을 걸 자격'만 판정한다."""
        if principal is not None:
            return True
        if getattr(self, "_agent_api_web", False):
            return is_loopback_client(self)   # auth 꺼진 로컬 대시보드
        return mobile_request_ok(self, parsed)
```

- [ ] **Step 5: 진입부에서 별칭을 적용한다**

`do_GET` (`:325-327`):

```python
    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        host_guarded = parsed.path.startswith("/api/") and parsed.path not in ("/api/mobile-state",)
        if host_guarded and not self._host_allowed():
            self.send_json({"error": "forbidden host"}, 403)
            return
        parsed = self._agent_api_alias(parsed)   # /api/agent/<op> → /mobile/api/<op> (host_guarded 통과 후)
```

`do_POST` (`:1154-1157`) 도 동일하게, `host_guarded` 검사 **다음** 줄에 `parsed = self._agent_api_alias(parsed)` 를 넣는다. 순서가 중요하다 — 별칭을 먼저 적용하면 `/api/agent/*` 가 host_guarded 를 우회하게 된다.

- [ ] **Step 6: 17곳의 인증 검사를 술어로 교체한다**

```bash
cd plugin/scripts && python3 - <<'PY'
from pathlib import Path
p = Path("marina_handler.py")
s = p.read_text(encoding="utf-8")
old = "if principal is None and not mobile_request_ok(self, parsed):"
new = "if not self._agent_api_ok(parsed, principal):"
n = s.count(old)
assert n == 17, f"예상 17곳, 실제 {n}곳 — 손으로 확인할 것"
p.write_text(s.replace(old, new), encoding="utf-8")
print("replaced", n)
PY
```

- [ ] **Step 7: 테스트가 통과하는지 확인한다**

```bash
cd plugin/tests && bash test-agent-api-dual-prefix.sh
```
Expected: `ok`

- [ ] **Step 8: 모바일 무회귀를 확인한다**

```bash
cd plugin/tests && for f in test-agent-*.sh test-mobile-*.sh test-access-*.sh test-host-guard.sh; do
  [ -f "$f" ] || continue; echo "== $f"; bash "$f" >/dev/null && echo OK || echo "FAIL $f"
done
```
Expected: 전부 OK. 하나라도 FAIL 이면 진행하지 말고 원인을 잡는다.

- [ ] **Step 9: 커밋**

```bash
git add plugin/scripts/marina_handler.py plugin/tests/test-agent-api-dual-prefix.sh
git commit -m "$(cat <<'EOF'
feat(api): 에이전트 API 를 웹·모바일이 공유 — /api/agent/* 경로 별칭

웹은 /mobile/api/* 를 못 불렀다(auth 꺼진 로컬에서 principal=None 이라
모바일 토큰 검사에 403). 모바일은 /api/* 를 못 부른다(host_guarded).
그래서 라우트를 옮기는 대신 웹 전용 별칭을 두고 같은 본문을 공유한다.

반복되던 인증 검사 17곳을 _agent_api_ok 술어 하나로 모았다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — 타임라인 렌더러 추출

### Task 2: 추출 경계 확정

**Files:**
- Read: `plugin/scripts/marina_mobile.py` (`_MOBILE_HTML` 안 JS)
- Create: `/private/tmp/claude-501/.../scratchpad/render-boundary.txt` (작업 메모, 커밋 안 함)

**Interfaces:**
- Produces: 이동할 함수 목록과 각 함수가 참조하는 외부 심볼 목록. Task 3 의 입력이다.

- [ ] **Step 1: 후보 함수와 참조를 뽑는다**

```bash
cd plugin/scripts && python3 - <<'PY'
import re
s = open("marina_mobile.py", encoding="utf-8").read()
html = s[s.index('_MOBILE_HTML = r"""'):]

CANDIDATES = [
    "renderInlineMarkdown", "renderRichText", "renderMarkdownBlocks", "mdRenderList",
    "renderActivityCode", "timelineFromTurns", "mergeTimelineItems", "mergeHistoryTurns",
    "renderTurnMeta", "renderLiveAction", "renderTurnAttachments", "renderTimelineImages",
    "renderTimelineMessage", "timelineDetailAttrs", "activityItemKey",
    "activityItemFingerprint", "activityGroupSummary", "renderActivityItem",
    "renderActivityGroup", "reconcileActivityList", "renderTimelineSequence",
    "questionsFromActivity", "pendingQuestionActivity", "renderQuestionCard",
    "renderConversationSequence", "timelineItemKeyParts", "exchangeRenderKey",
]

# 각 함수 본문을 잘라 낸다 (다음 최상위 function 선언까지)
starts = {}
for m in re.finditer(r'\n(\s*)(?:async\s+)?function\s+([A-Za-z0-9_]+)\s*\(', html):
    starts.setdefault(m.group(2), []).append(m.start())

bounds = sorted((pos, name) for name, poss in starts.items() for pos in poss)
body = {}
for i, (pos, name) in enumerate(bounds):
    end = bounds[i + 1][0] if i + 1 < len(bounds) else len(html)
    body[name] = html[pos:end]

defined = set(starts)
external = {}
for name in CANDIDATES:
    if name not in body:
        print("MISSING", name); continue
    refs = set(re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)\b', body[name]))
    out = sorted(r for r in refs
                 if r in defined and r not in CANDIDATES)
    external[name] = out

print("== 추출 대상이 참조하는 '남는' 함수 ==")
allout = sorted({r for v in external.values() for r in v})
for r in allout:
    print(" ", r, "<-", [k for k, v in external.items() if r in v])
PY
```

- [ ] **Step 2: DOM·전역 참조를 뽑는다**

```bash
cd plugin/scripts && python3 - <<'PY'
import re
s = open("marina_mobile.py", encoding="utf-8").read()
html = s[s.index('_MOBILE_HTML = r"""'):]
CANDIDATES = ["renderTimelineMessage", "renderActivityItem", "renderActivityGroup",
              "reconcileActivityList", "renderQuestionCard", "renderTimelineImages",
              "renderRichText", "renderMarkdownBlocks", "timelineFromTurns"]
for name in CANDIDATES:
    m = re.search(r'\n\s*(?:async\s+)?function\s+' + name + r'\s*\(', html)
    if not m: continue
    nxt = re.search(r'\n\s*(?:async\s+)?function\s+', html[m.end():])
    seg = html[m.start(): m.end() + (nxt.start() if nxt else 2000)]
    hits = sorted(set(re.findall(
        r'\b(document|window|localStorage|selectedSession|state|turnsEl|liveAnswer|'
        r'selected[A-Za-z]*|currentRoot|API_BASE|authToken|fetch)\b', seg)))
    if hits: print(name, "->", hits)
PY
```

- [ ] **Step 3: 경계를 확정해 메모로 남긴다**

위 두 출력으로 세 부류를 가른다:

1. **순수 렌더** (DOM·전역 참조 없음, 문자열만 만듦) → `chat-render.js` 로 이동.
2. **DOM 조작** (`document`, `turnsEl` 참조) → 이동하되 **엘리먼트를 인자로 받게** 시그니처를 바꾼다. 예: `reconcileActivityList(listEl, items)`.
3. **모바일 상태 의존** (`selectedSession`, `liveAnswer`, `fetch`) → **이동하지 않는다**. 모바일에 남기고, 렌더러에는 필요한 값만 인자로 넘긴다.

부류 3에 속하는 함수가 부류 1·2를 호출하는 방향이어야 한다. 반대 방향(렌더러가 모바일 상태를 읽음)이 하나라도 있으면 그 함수는 부류 3이다.

메모에 최종 이동 목록과 시그니처 변경 목록을 적는다.

- [ ] **Step 4: 커밋 없음**

분석 단계다. 코드 변경이 없으므로 커밋하지 않는다.

---

### Task 3: `chat-render.js` 추출 + 모바일 전환

**Files:**
- Create: `plugin/scripts/marina-web/chat-render.js`
- Modify: `plugin/scripts/marina_mobile.py` (`_MOBILE_HTML` — 함수 제거, `<script src>` 추가, 호출부에 `MarinaChat.` 접두)
- Test: `plugin/tests/test-chat-render-shared.sh`

**Interfaces:**
- Consumes: Task 2 의 이동 목록.
- Produces: `window.MarinaChat` — Task 2 에서 확정한 순수 렌더/DOM 함수들을 담은 객체. 최소한 다음을 포함한다: `timelineFromTurns(turns)`, `mergeTimelineItems(prev, next)`, `renderTimelineSequence(items, opts)`, `renderTimelineMessage(item, opts)`, `renderActivityGroup(group, opts)`, `reconcileActivityList(listEl, items, opts)`, `renderQuestionCard(question, opts)`, `renderRichText(text)`, `escapeHtml(text)`. `opts` 는 `{imageUrl(ref), fileUrl(path), source}` 형태의 호스트 어댑터다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`plugin/tests/test-chat-render-shared.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
JS="$SCR/marina-web/chat-render.js"

[ -f "$JS" ] || { echo "FAIL: chat-render.js 없음"; exit 1; }

PYTHONPATH="$SCR" python3 - "$JS" "$SCR/marina_mobile.py" <<'PY'
import re
import sys

js = open(sys.argv[1], encoding="utf-8").read()
mob = open(sys.argv[2], encoding="utf-8").read()
html = mob[mob.index('_MOBILE_HTML = r"""'):]

# 1) 네임스페이스 하나로만 노출한다 — 전역 오염 금지
assert "window.MarinaChat" in js, "MarinaChat 네임스페이스가 없다"

# 2) 모바일이 공유 파일을 로드한다
assert '/web/chat-render.js' in html, "모바일 HTML 이 chat-render.js 를 로드하지 않는다"

# 3) 추출된 함수가 모바일 인라인에 중복 정의돼 있지 않다 (다시 벌어지는 것 차단)
EXPORTED = re.findall(r'^\s{4}([A-Za-z0-9_]+)[,:]', js, re.M)
assert EXPORTED, "MarinaChat 노출 목록을 파싱하지 못했다 — 테스트의 정규식을 확인할 것"
dupes = [n for n in EXPORTED
         if re.search(r'\n\s*(?:async\s+)?function\s+' + re.escape(n) + r'\s*\(', html)]
assert not dupes, f"모바일에 중복 정의가 남았다: {dupes}"

# 4) 공유 렌더러는 모바일 전용 전역을 참조하지 않는다
BANNED = ["selectedSession", "liveAnswer", "promptInput", "turnsEl", "statusEl", "apiFetch"]
leaks = [b for b in BANNED if re.search(r'\b' + re.escape(b) + r'\b', js)]
assert not leaks, f"공유 렌더러가 모바일 전역을 참조한다: {leaks}"
print("ok")
PY

# 5) 문법 검사 — node 가 있으면
if command -v node >/dev/null 2>&1; then
  node --check "$JS" || { echo "FAIL: chat-render.js 문법 오류"; exit 1; }
fi
echo "ok"
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd plugin/tests && bash test-chat-render-shared.sh
```
Expected: FAIL — `chat-render.js 없음`

- [ ] **Step 3: `chat-render.js` 뼈대를 만든다**

```javascript
// chat-render.js — 에이전트 대화 타임라인 렌더러. **웹 대시보드와 모바일이 공유한다.**
//
// 왜 공유하나. 예전엔 모바일에만 타임라인이 있었고 웹은 읽기전용 텍스트 모달이었다. 웹에 채팅을
// 붙이면서 렌더러를 새로 짜면 두 벌이 되고, 그러면 지금 고치고 있는 "둘이 벌어짐"이 그대로
// 재생산된다. 그래서 마크업 계약(클래스명·구조)을 여기 한 곳에 두고 CSS 스킨만 각자 입힌다.
//
// 규칙. 이 파일은 **호스트 상태를 모른다**. DOM 엘리먼트와 어댑터(opts)를 인자로만 받는다.
// 모바일 전역(selectedSession·liveAnswer·turnsEl 등)을 참조하면 test-chat-render-shared.sh 가 막는다.
(function () {
  'use strict';

  function escapeHtml(text) {
    return String(text == null ? '' : text)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  // ── 여기에 Task 2 에서 확정한 함수들을 marina_mobile.py 에서 그대로 옮긴다 ──
  // 옮길 때 바꾸는 것은 두 가지뿐이다:
  //   1) 호스트 전역 참조 → opts 어댑터 인자 (예: transcriptImageUrl(ref) → opts.imageUrl(ref))
  //   2) 모듈 내부 상호 호출은 이름 그대로 유지 (IIFE 스코프 안이라 그대로 보인다)

  window.MarinaChat = {
    escapeHtml,
    // timelineFromTurns,
    // mergeTimelineItems,
    // renderTimelineSequence,
    // renderTimelineMessage,
    // renderActivityGroup,
    // reconcileActivityList,
    // renderQuestionCard,
    // renderRichText,
  };
})();
```

- [ ] **Step 4: 함수를 하나씩 옮긴다**

Task 2 의 이동 목록 순서대로, **의존이 없는 것부터**(`escapeHtml` → `renderInlineMarkdown` → `renderMarkdownBlocks` → `renderRichText` → `renderActivityCode` → `timelineFromTurns` → … → `reconcileActivityList`) 한 번에 하나씩:

1. `marina_mobile.py` 의 `_MOBILE_HTML` 에서 그 함수 정의를 잘라낸다.
2. `chat-render.js` 의 표시된 자리에 붙인다.
3. 호스트 전역 참조를 `opts` 어댑터로 바꾼다.
4. `MarinaChat` 노출 목록에 이름을 추가한다.
5. 모바일 쪽 호출부에 `MarinaChat.` 접두를 붙인다.

한 함수를 옮길 때마다 Step 5 를 돌린다. 여러 개를 몰아서 옮기면 어느 것이 깨졌는지 못 찾는다.

- [ ] **Step 5: 매 함수마다 검증한다**

```bash
cd plugin/tests && bash test-chat-render-shared.sh && bash test-agent-timeline.sh
```
Expected: 둘 다 통과. 실패하면 방금 옮긴 함수만 되돌린다.

- [ ] **Step 6: 모바일 HTML 에 스크립트 태그를 넣는다**

`_MOBILE_HTML` 의 인라인 `<script>` **앞에** 넣는다:

```html
    <script src="/web/chat-render.js"></script>
```

`/web/` 는 `PUBLIC_PREFIXES` 라 auth 가 켜져도 접근 가능하고 `host_guarded` 는 `/api/` 만 검사하므로 펀넬에서도 뜬다. `cache-control: no-store` 라 stale 위험도 없다.

- [ ] **Step 7: 모바일 전체 회귀를 확인한다**

```bash
cd plugin/tests && for f in test-agent-timeline.sh test-agent-history-pagination.sh \
  test-agent-question-surfacing.sh test-activity-counts.sh test-agent-usage.sh \
  test-agent-inbox.sh test-chat-render-shared.sh; do
  echo "== $f"; bash "$f" >/dev/null && echo OK || echo "FAIL $f"
done
```
Expected: 전부 OK. **이것이 Phase 2 의 게이트다** — 하나라도 FAIL 이면 Phase 3 으로 넘어가지 않는다.

- [ ] **Step 8: 브라우저로 모바일을 실측한다**

marina 대시보드에서 `/mobile` 을 열어 세션 하나의 대화를 연다. 확인 항목: 타임라인이 그려지는가, 도구 활동 그룹이 접히는가, 이미지가 인라인으로 뜨는가, 질문 카드가 뜨는가, 새 메시지 버튼이 동작하는가.

CLAUDE.md 규칙대로 Aside 를 쓴다. Aside MCP 가 없으면 `~/.local/bin/aside repl "<js>"` 로 셸 폴백한다.

- [ ] **Step 9: 커밋**

```bash
git add plugin/scripts/marina-web/chat-render.js plugin/scripts/marina_mobile.py \
        plugin/tests/test-chat-render-shared.sh
git commit -m "$(cat <<'EOF'
refactor(chat): 타임라인 렌더러를 /web/chat-render.js 로 추출 — 웹·모바일 공유

웹에 대화를 붙이면서 렌더러를 새로 짜면 두 벌이 되고, 지금 고치는 "둘이
벌어짐"이 그대로 재생산된다. 마크업 계약을 한 곳에 두고 CSS 스킨만 각자
입히게 했다. 공유 파일은 호스트 상태를 모르고 어댑터만 인자로 받는다.

모바일 동작은 불변 — 기존 모바일 테스트 전량과 실브라우저로 확인.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — 웹 대화 탭

### Task 4: 탭 골격과 브라우저식 세션 멀티탭

**Files:**
- Create: `plugin/scripts/marina-web/app-11-chat.js`
- Modify: `plugin/scripts/marina-web/index.html` (`ws-tabs` `:71-77`, pane `:116-118`, 스크립트 태그 `:337`)
- Modify: `plugin/scripts/marina-web/styles.css`

**Interfaces:**
- Consumes: `window.MarinaChat` (Task 3), 전역 `api(path, opts)`, `escapeHtml`, `showToast`, `worktreeData`, `selectedRoot` 계열 (`app-1-core.js`), `/api/agent/transcript`.
- Produces:
  - `openAgentChat(root, agent)` — 대화 워크스페이스를 활성화하고 그 세션 탭을 열거나, 이미 열려 있으면 그 탭으로 이동한다. Task 6 이 `app-5-sessions.js` 에서 호출한다.
  - `chatTabs: ChatTab[]` — 열린 세션 탭. `ChatTab = {root, source, sid, title, view, cursor, items, hasMore, draft, scrollTop, seenTs}`. `view` 는 `'chat'` 또는 `'raw'`.
  - `chatActive: number` — 활성 탭 인덱스. `activeChatTab()` 가 `chatTabs[chatActive]` 또는 `null` 을 준다.
  - `renderChatPane()`, `closeChatTab(i)`, `saveChatTabs()`.

- [ ] **Step 1: `index.html` 에 탭과 pane 을 추가한다**

`ws-tabs` 의 `터미널` 버튼 **뒤에**:

```html
        <button data-ws-tab="chat" title="대화 — 선택한 에이전트 세션의 타임라인·이미지·질문 카드">대화</button>
```

`<div class="ws-pane" id="tab-term" hidden></div>` **뒤에**:

```html
      <div class="ws-pane" id="tab-chat" hidden></div>
```

`</body>` 앞 스크립트 목록에서 `app-10-term.js` **뒤**, `app-7-init.js` **앞**에:

```html
  <script src="/web/chat-render.js"></script>
  <script src="/web/app-11-chat.js"></script>
```

순서가 중요하다 — `app-11-chat.js` 는 `MarinaChat` 과 `app-10-term.js` 의 `mountAgentTerm` 을 둘 다 쓴다.

- [ ] **Step 2: 탭이 뜨는지 확인한다**

대시보드를 새로고침해 `대화` 탭이 보이고 클릭하면 빈 pane 이 열리는지 본다. 이 시점엔 내용이 없는 게 정상이다.

- [ ] **Step 3: 탭 모델과 영속화를 쓴다**

```javascript
    // ── 대화 워크스페이스 — 에이전트 세션 멀티탭 ──
    // 멘탈 모델: 에이전트 세션은 여기서, 셸은 터미널 탭에서. 같은 세션의 두 시점([대화|원본])을
    // 세그먼트로 묶어 "다른 채널이 아니라 다른 렌즈"임을 보이게 한다.
    // 타임라인 렌더는 chat-render.js(모바일과 공유)가 하고, 이 파일은 탭 셸·폴링·전송만 맡는다.
    //
    // 탭은 **브라우저 탭처럼 워크트리를 넘나든다.** 다른 워크트리 세션을 열면 교체가 아니라 추가다 —
    // 여러 워크트리를 동시에 돌릴 때 좌측 패널을 왔다 갔다 하지 않아도 된다.
    // 탭마다 상태가 독립이다(커서·스크롤·view·초안). 탭을 바꿔도 치던 글이 날아가지 않는다.
    const CHAT_TABS_KEY = 'marina.chat.tabs';
    let chatTabs = [];
    let chatActive = -1;
    let chatTimer = null;
    let chatSending = false;     // 전송 중 — 폴링 재렌더 금지
    let chatAnswering = false;   // 질문 카드 응답 중 — 폴링 재렌더 금지

    function activeChatTab() {
      return chatActive >= 0 && chatActive < chatTabs.length ? chatTabs[chatActive] : null;
    }

    function chatTabKey(tab) { return `${tab.root} ${tab.source} ${tab.sid}`; }

    function saveChatTabs() {
      // 영속화는 '어느 세션이 열려 있었나'만 — 트랜스크립트 본문은 다시 받으면 된다.
      const slim = chatTabs.map(t => ({root: t.root, source: t.source, sid: t.sid,
                                       title: t.title, view: t.view, draft: t.draft || ''}));
      try { localStorage.setItem(CHAT_TABS_KEY, JSON.stringify({tabs: slim, active: chatActive})); }
      catch {}
    }

    function loadChatTabs() {
      let saved;
      try { saved = JSON.parse(localStorage.getItem(CHAT_TABS_KEY) || 'null'); } catch { saved = null; }
      if (!saved || !Array.isArray(saved.tabs)) return;
      chatTabs = saved.tabs.map(t => ({...t, cursor: null, items: [], hasMore: false,
                                       scrollTop: 0, seenTs: 0}));
      chatActive = Math.min(Math.max(0, saved.active | 0), chatTabs.length - 1);
    }

    // 세션이 사라졌으면(7일 지남·삭제) 조용히 걷어낸다. worktreeData 가 아직 안 왔으면 건드리지 않는다.
    function pruneChatTabs() {
      if (!worktreeData.length) return;
      const alive = new Set();
      for (const wt of worktreeData) {
        for (const a of (wt.agents || [])) if (a.sid) alive.add(`${wt.root} ${a.source} ${a.sid}`);
      }
      const before = chatTabs.length;
      const activeKey = activeChatTab() && chatTabKey(activeChatTab());
      chatTabs = chatTabs.filter(t => alive.has(chatTabKey(t)));
      if (chatTabs.length === before) return;
      chatActive = Math.max(0, chatTabs.findIndex(t => chatTabKey(t) === activeKey));
      saveChatTabs();
    }

    function openAgentChat(root, agent) {
      selectWsTab('chat');
      const key = `${root} ${agent.source} ${agent.sid}`;
      const at = chatTabs.findIndex(t => chatTabKey(t) === key);
      if (at >= 0) chatActive = at;
      else {
        chatTabs.push({root, source: agent.source, sid: agent.sid, title: agent.title || agent.sid.slice(0, 8),
                       view: 'chat', cursor: null, items: [], hasMore: false, draft: '',
                       scrollTop: 0, seenTs: agent.statusTs || agent.ts || 0});
        chatActive = chatTabs.length - 1;
      }
      saveChatTabs();
      renderChatPane();
      loadChatTranscript(true).catch(console.error);
    }

    function closeChatTab(i) {
      if (i < 0 || i >= chatTabs.length) return;
      chatTabs.splice(i, 1);
      if (chatActive >= chatTabs.length) chatActive = chatTabs.length - 1;
      else if (i < chatActive) chatActive -= 1;
      saveChatTabs();
      renderChatPane();
      if (activeChatTab()) loadChatTranscript(true).catch(console.error);
    }
```

`selectWsTab` 이 이미 있는지 확인하고 이름이 다르면 그 이름을 쓴다:

```bash
grep -rn "ws-tab\|wsTab" plugin/scripts/marina-web/*.js | grep -i "function\|onclick" | head
```

- [ ] **Step 4: 탭 스트립을 렌더한다**

```javascript
    function chatAgentsFor(root) {
      const wt = worktreeData.find(w => w.root === root);
      return (wt && wt.agents || []).filter(a => a.sid);
    }

    function chatTabLabel(tab, showRoot) {
      const head = tab.source === 'codex' ? 'Codex' : 'Claude';
      const wtName = showRoot ? `${escapeHtml(tab.root.split('/').pop())} · ` : '';
      return `${wtName}${head} · ${escapeHtml(tab.title)}`;
    }

    function renderChatPane() {
      const pane = document.getElementById('tab-chat');
      if (!pane) return;
      if (!chatTabs.length) {
        pane.innerHTML = `<div class="empty">열린 대화가 없어요
          <span class="hint">왼쪽 AGENTS 행을 누르거나, 아래에서 세션을 고르세요</span>
          <button class="chat-open-btn" data-chat-open>세션 열기</button></div>`;
        pane.querySelector('[data-chat-open]').onclick = (e) => openChatPicker(e.target);
        return;
      }
      const tab = activeChatTab();
      // 워크트리가 둘 이상 열려 있을 때만 워크트리명을 붙인다 — 같은 워크트리끼리는 군더더기.
      const showRoot = new Set(chatTabs.map(t => t.root)).size > 1;
      pane.innerHTML = `
        <div class="chat-tabstrip" data-chat-tabstrip>
          ${chatTabs.map((t, i) => `
            <button class="chat-tab${i === chatActive ? ' active' : ''}${t.unread ? ' unread' : ''}"
                    data-chat-tab="${i}" title="${escapeHtml(t.root)}">
              <span class="chat-tab-dot" aria-hidden="true"></span>
              <span class="chat-tab-label">${chatTabLabel(t, showRoot)}</span>
              <span class="chat-tab-x" data-chat-tab-close="${i}" title="닫기">✕</span>
            </button>`).join('')}
          <button class="chat-tab-add" data-chat-add title="세션 탭 추가">+</button>
        </div>
        <div class="chat-head">
          <div class="segments chat-view-tabs">
            <button data-chat-view="chat" class="${tab.view === 'chat' ? 'active' : ''}"
              title="정리된 타임라인 — 이미지·도구활동·질문 카드">대화</button>
            <button data-chat-view="raw" class="${tab.view === 'raw' ? 'active' : ''}"
              title="이 세션의 터미널 원본 — 권한 프롬프트·/명령·TUI 조작">원본</button>
          </div>
        </div>
        <div class="chat-body" data-chat-body></div>`;

      pane.querySelectorAll('[data-chat-tab]').forEach(btn => {
        const i = Number(btn.dataset.chatTab);
        btn.onclick = (e) => {
          if (e.target.closest('[data-chat-tab-close]')) return;
          if (i === chatActive) return;
          chatActive = i; chatTabs[i].unread = false;
          saveChatTabs(); renderChatPane();
          loadChatTranscript(true).catch(console.error);
        };
        // 브라우저처럼 가운데 클릭으로도 닫는다
        btn.onauxclick = (e) => { if (e.button === 1) { e.preventDefault(); closeChatTab(i); } };
      });
      pane.querySelectorAll('[data-chat-tab-close]').forEach(x => {
        x.onclick = (e) => { e.stopPropagation(); closeChatTab(Number(x.dataset.chatTabClose)); };
      });
      pane.querySelector('[data-chat-add]').onclick = (e) => openChatPicker(e.target);
      pane.querySelectorAll('[data-chat-view]').forEach(btn => {
        btn.onclick = () => { tab.view = btn.dataset.chatView; saveChatTabs(); renderChatPane(); };
      });

      const body = pane.querySelector('[data-chat-body]');
      if (tab.view === 'raw') mountAgentTerm(body, tab.root, tab);
      else renderChatConversation(body);
    }
```

- [ ] **Step 5: `+` 피커를 구현한다**

```javascript
    // + 버튼 — 지금 선택된 워크트리에서 아직 안 열린 세션을 고르게 한다.
    // 세션이 하나도 없으면 새로 띄우는 길을 준다.
    function openChatPicker(anchor) {
      const root = selected && selected.root || (sessions[0] && sessions[0].root);
      if (!root) { showToast('워크트리를 먼저 고르세요', 'err'); return; }
      const open = new Set(chatTabs.map(chatTabKey));
      const rest = chatAgentsFor(root).filter(a => !open.has(`${root} ${a.source} ${a.sid}`));
      const ex = document.getElementById('chatPicker'); if (ex) ex.remove();
      const menu = document.createElement('div');
      menu.id = 'chatPicker';
      menu.className = 'chat-picker';
      menu.innerHTML = rest.length
        ? rest.map(a => `<button data-pick-sid="${escapeHtml(a.sid)}" data-pick-source="${escapeHtml(a.source)}"
            >${a.source === 'codex' ? 'Codex' : 'Claude'} · ${escapeHtml(a.title)}</button>`).join('')
        : `<div class="chat-picker-empty">열 수 있는 세션이 없어요</div>
           <button data-pick-launch>세션 시작</button>`;
      document.body.appendChild(menu);
      const r = anchor.getBoundingClientRect();
      menu.style.left = `${Math.min(r.left, window.innerWidth - menu.offsetWidth - 8)}px`;
      menu.style.top = `${r.bottom + 4}px`;
      const close = () => { menu.remove(); document.removeEventListener('click', onDoc, true); };
      const onDoc = (e) => { if (!menu.contains(e.target) && e.target !== anchor) close(); };
      setTimeout(() => document.addEventListener('click', onDoc, true), 0);
      menu.querySelectorAll('[data-pick-sid]').forEach(btn => {
        btn.onclick = () => {
          const a = rest.find(x => x.sid === btn.dataset.pickSid);
          close(); if (a) openAgentChat(root, a);
        };
      });
      const launch = menu.querySelector('[data-pick-launch]');
      if (launch) launch.onclick = () => { close(); launchChatSession(root); };
    }
```

`selected` 와 `sessions` 가 `app-1-core.js` 의 전역 이름과 맞는지 확인한다:

```bash
grep -n "^    let selected\|^    let sessions" plugin/scripts/marina-web/app-1-core.js
```

- [ ] **Step 6: 안 읽은 표시를 붙인다**

비활성 탭은 트랜스크립트를 폴링하지 않는다 — 탭 N개면 N배 부하다. 이미 5초마다 도는 `loadWorktrees()` 의 `agents[].statusTs` 만 본다. `loadWorktrees` 완료 지점에 다음을 건다:

```javascript
    // 비활성 탭의 '새 턴' 점 — 트랜스크립트를 받지 않고 statusTs 변화만으로 판정한다.
    function markChatUnread() {
      let changed = false;
      chatTabs.forEach((t, i) => {
        const wt = worktreeData.find(w => w.root === t.root);
        const a = (wt && wt.agents || []).find(x => x.sid === t.sid && x.source === t.source);
        if (!a) return;
        const ts = a.statusTs || a.ts || 0;
        if (i === chatActive) { t.seenTs = ts; if (t.unread) { t.unread = false; changed = true; } return; }
        if (ts > (t.seenTs || 0) && !t.unread) { t.unread = true; changed = true; }
      });
      if (changed) renderChatPane();
    }
```

- [ ] **Step 7: 부팅에 배선한다**

`app-7-init.js` 의 부트스트랩에 `loadChatTabs()` 를, `loadWorktrees()` 성공 후에 `pruneChatTabs(); markChatUnread();` 를 건다.

- [ ] **Step 8: 멀티탭이 동작하는지 확인한다**

- AGENTS 행을 여러 개(서로 다른 워크트리 포함) 클릭하면 탭이 쌓이는가
- 이미 열린 세션을 다시 클릭하면 새 탭이 아니라 그 탭으로 이동하는가
- `✕` 와 가운데 클릭으로 닫히고, 활성 탭을 닫으면 이웃이 활성화되는가
- `+` 로 같은 워크트리의 다른 세션을 열 수 있는가 (이미 열린 건 목록에서 빠지는가)
- 새로고침하면 탭이 복원되는가
- 워크트리가 하나뿐일 땐 라벨에 워크트리명이 안 붙는가

- [ ] **Step 9: 커밋**

```bash
git add plugin/scripts/marina-web/index.html plugin/scripts/marina-web/app-11-chat.js \
        plugin/scripts/marina-web/styles.css plugin/scripts/marina-web/app-7-init.js
git commit -m "$(cat <<'EOF'
feat(web): 대화 워크스페이스 — 브라우저식 세션 멀티탭

에이전트 세션을 탭으로 여러 개 띄운다. 워크트리를 넘나들고(다른 워크트리
세션을 열면 교체가 아니라 추가), 탭마다 커서·스크롤·view·초안이 독립이라
탭을 바꿔도 치던 글이 안 날아간다. 열린 목록은 localStorage 로 복원한다.

비활성 탭은 트랜스크립트를 폴링하지 않는다 — 탭 N개면 N배 부하다.
이미 도는 loadWorktrees 의 statusTs 변화로만 '새 턴' 점을 찍는다.

내용 렌더는 다음 커밋.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: 타임라인 렌더·폴링·컴포저

**Files:**
- Modify: `plugin/scripts/marina-web/app-11-chat.js`
- Modify: `plugin/scripts/marina-web/styles.css`

**Interfaces:**
- Consumes: `window.MarinaChat` 의 `timelineFromTurns`/`mergeTimelineItems`/`renderTimelineSequence`/`reconcileActivityList`/`renderQuestionCard`, `/api/agent/transcript`, `/api/agent/send`, `/api/agent/upload`, `/api/agent/answer`, `/api/agent/interrupt`, `/api/agent/activity`.
- Produces: `renderChatConversation(bodyEl)`, `loadChatTranscript(initial)`, `sendChatMessage(text, attachments)`, `launchChatSession(root)`. Task 6 이 `openAgentChat` 경유로만 쓰므로 외부 계약은 늘지 않는다.

- [ ] **Step 1: 트랜스크립트 로드를 구현한다**

상태는 전부 **활성 탭 객체 안에** 산다. 전역에 두면 탭을 바꿀 때 다른 세션의 커서·아이템이 새어 든다.

```javascript
    async function loadChatTranscript(initial) {
      const tab = activeChatTab();
      if (!tab) return;
      const key = chatTabKey(tab);
      const before = !initial && tab.cursor != null ? `&before=${enc(tab.cursor)}` : '';
      const d = await api(`/api/agent/transcript?root=${enc(tab.root)}&source=${enc(tab.source)}&sid=${enc(tab.sid)}${before}`);
      // 응답이 오는 사이 형이 탭을 바꿨을 수 있다 — 그러면 이 응답은 남의 것이다.
      const now = activeChatTab();
      if (!now || chatTabKey(now) !== key) return;
      const fresh = MarinaChat.timelineFromTurns(d.turns || []);
      tab.items = initial ? fresh : MarinaChat.mergeTimelineItems(fresh, tab.items);
      tab.cursor = d.cursor != null ? d.cursor : null;
      tab.hasMore = Boolean(d.hasMore);
      tab.unread = false;
      const body = document.querySelector('#tab-chat [data-chat-body]');
      if (body && tab.view === 'chat') renderChatConversation(body);
    }
```

`enc` 는 `app-3-util.js` 의 기존 헬퍼다. 없으면 `encodeURIComponent` 를 쓴다:

```bash
grep -n "function enc" plugin/scripts/marina-web/app-3-util.js
```

- [ ] **Step 2: 대화 렌더를 구현한다**

```javascript
    function chatAdapter(tab) {
      const q = `root=${enc(tab.root)}&source=${enc(tab.source)}&sid=${enc(tab.sid)}`;
      return {
        source: tab.source,
        imageUrl: (ref) => `/api/agent/transcript-image?${q}&ref=${enc(ref)}`,
        fileUrl: (path) => `/api/agent/session-file?root=${enc(tab.root)}&path=${enc(path)}`,
      };
    }

    function renderChatConversation(body) {
      const tab = activeChatTab();
      if (!tab) return;
      // renderChatPane 이 pane 을 갈아엎으므로 탭 전환마다 여기 골격을 다시 만든다.
      // 그래서 초안(draft)·스크롤 위치는 탭 객체에서 복원한다.
      if (!body.querySelector('[data-chat-turns]')) {
        body.innerHTML = `
          <button class="chat-older-btn" data-chat-older hidden>이전 메시지</button>
          <div class="chat-turns" data-chat-turns></div>
          <div class="chat-question" data-chat-question></div>
          <div class="chat-composer" data-chat-composer></div>`;
        body.querySelector('[data-chat-older]').onclick = () => loadChatTranscript(false);
        renderChatComposer(body.querySelector('[data-chat-composer]'), tab);
      }
      body.querySelector('[data-chat-older]').hidden = !tab.hasMore;
      const list = body.querySelector('[data-chat-turns]');
      const first = !list.childElementCount;
      const atBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 40;
      MarinaChat.reconcileActivityList(list, tab.items, chatAdapter(tab));
      if (first) list.scrollTop = tab.scrollTop || list.scrollHeight;
      else if (atBottom) list.scrollTop = list.scrollHeight;
      list.onscroll = () => { tab.scrollTop = list.scrollTop; };
    }
```

`reconcileActivityList` 의 실제 시그니처는 Task 2·3 에서 확정된다. 다르면 여기를 그 시그니처에 맞춘다.

- [ ] **Step 3: 컴포저와 전송을 구현한다**

```javascript
    function renderChatComposer(el, tab) {
      el.innerHTML = `
        <div class="chat-attach-strip" data-chat-attach hidden></div>
        <div class="chat-input-row">
          <button class="chat-attach-btn" data-chat-attach-btn title="이미지·파일 첨부">+</button>
          <textarea class="chat-prompt" data-chat-prompt rows="1"
            placeholder="메시지 — Enter 전송 · Shift+Enter 줄바꿈"></textarea>
          <button class="chat-stop-btn" data-chat-stop title="현재 턴 정지" hidden>정지</button>
          <button class="chat-send-btn" data-chat-send>전송</button>
        </div>
        <input type="file" data-chat-file hidden multiple />`;
      const prompt = el.querySelector('[data-chat-prompt]');
      prompt.value = tab.draft || '';               // 탭마다 초안이 독립 — 바꿔도 안 날아간다
      prompt.oninput = () => { tab.draft = prompt.value; };
      const file = el.querySelector('[data-chat-file]');
      el.querySelector('[data-chat-attach-btn]').onclick = () => file.click();
      file.onchange = () => uploadChatFiles(tab, [...file.files])
        .catch(e => showToast(`첨부 실패 · ${e.message}`, 'err'));
      el.querySelector('[data-chat-send]').onclick = () => submitChat(prompt, tab);
      el.querySelector('[data-chat-stop]').onclick = () => interruptChat(tab).catch(console.error);
      prompt.onkeydown = (e) => {
        if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submitChat(prompt, tab); }
      };
    }

    async function submitChat(prompt, tab) {
      const text = prompt.value.trim();
      if (!text && !(tab.attachments || []).length) return;
      prompt.value = ''; tab.draft = '';
      chatSending = true;
      try {
        await api('/api/agent/send', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({
            root: tab.root, text,
            target: {type: 'agent', source: tab.source, sid: tab.sid},
            attachments: (tab.attachments || []).map(a => a.name),
          }),
        });
        tab.attachments = [];
        saveChatTabs();
        await loadChatTranscript(true);
      } catch (e) {
        prompt.value = text; tab.draft = text;   // 실패하면 입력을 돌려준다 — 날리면 다시 못 친다
        showToast(`전송 실패 · ${e.message}`, 'err');
      } finally {
        chatSending = false;
      }
    }
```

`mobile_send` 가 받는 body 스키마를 확인해 필드명을 맞춘다:

```bash
sed -n '937,1020p' plugin/scripts/marina_mobile.py
```

- [ ] **Step 4: 폴링을 붙인다 (defer-guard 포함)**

```javascript
    // **활성 탭 하나만** 폴링한다. 탭 N개를 각각 돌리면 N배 부하다 — 비활성 탭의 '새 턴' 점은
    // 이미 도는 loadWorktrees 의 statusTs 로 markChatUnread 가 찍는다.
    // 입력 중·전송 중·질문 응답 중에는 재렌더를 미룬다 — 폴링 재렌더가 포커스와 입력값을 날리는
    // 사고가 예전에 있었다(모바일 defer-guard 와 같은 규칙).
    function startChatPolling() {
      if (chatTimer) return;
      chatTimer = setInterval(() => {
        const pane = document.getElementById('tab-chat');
        const tab = activeChatTab();
        if (!pane || pane.hidden || !tab || tab.view !== 'chat') return;
        const prompt = pane.querySelector('[data-chat-prompt]');
        const typing = prompt && (prompt.value.trim() || document.activeElement === prompt);
        if (typing || chatSending || chatAnswering) return;
        loadChatTranscript(true).catch(console.error);
      }, 3000);
    }
```

`app-7-init.js` 의 `visibilitychange` 핸들러와 하단 부트스트랩에 `startChatPolling()` 을 추가하고, `document.hidden` 일 때 `clearInterval(chatTimer); chatTimer = null;` 로 멈춘다.

- [ ] **Step 5: 실브라우저로 확인한다**

Aside 로 대시보드를 열어 확인한다:
- 타임라인이 뜨고 `이전 메시지` 로 과거가 붙는가
- 이미지가 인라인으로 렌더되는가 (**형이 제기한 원래 문제**)
- 메시지를 보내면 세션에 도달하고 타임라인에 나타나는가
- 입력 중에 폴링이 입력값을 날리지 않는가 (텍스트를 치고 5초 기다려 본다)
- 질문 카드가 뜨고 선택이 먹는가
- **탭 A 에 글을 치다가 탭 B 로 갔다 돌아오면 초안이 그대로인가**
- **비활성 탭 세션이 응답하면 그 탭 라벨에 점이 찍히고, 그 탭을 누르면 점이 사라지는가**
- **탭을 빠르게 전환해도 다른 세션의 타임라인이 섞이지 않는가** (응답 레이스 가드 확인)

- [ ] **Step 6: 커밋**

```bash
git add plugin/scripts/marina-web/app-11-chat.js plugin/scripts/marina-web/styles.css
git commit -m "$(cat <<'EOF'
feat(web): 대화 탭 타임라인·전송·첨부 — 이미지를 웹에서 볼 수 있게

웹은 세션을 터미널로만 열 수 있어 이미지·diff 를 보기 힘들었다. 모바일과
같은 렌더러로 타임라인을 그리고 전송·첨부·질문 카드를 붙였다.

폴링 재렌더는 입력 중·전송 중·응답 중엔 미룬다(모바일 defer-guard 와 동일).

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: 터미널 역할 분리

**Files:**
- Modify: `plugin/scripts/marina-web/app-5-sessions.js:271-279` (`wireAgentRows`)
- Modify: `plugin/scripts/marina-web/app-10-term.js:63-71` (셸 사이드바), `:462` 부근 (`openAgentTerminal` → `mountAgentTerm` 추출)
- Modify: `plugin/scripts/marina-web/app-6-modals.js:655-714` (`openAgentTranscript` 삭제)

**Interfaces:**
- Consumes: `openAgentChat(root, agent)` (Task 4)
- Produces: `mountAgentTerm(paneEl, root, agent)` — 주어진 엘리먼트에 그 세션의 PTY 를 xterm 으로 붙인다. Task 4 의 `원본` 뷰가 쓴다.

- [ ] **Step 1: `mountAgentTerm` 을 추출한다**

`app-10-term.js` 의 `openAgentTerminal` 을 읽는다:

```bash
sed -n '455,508p' plugin/scripts/marina-web/app-10-term.js
```

터미널 탭에 마운트하는 부분과 PTY 를 여는 부분을 가른다. PTY 를 열고 임의의 엘리먼트에 붙이는 부분을 `mountAgentTerm(paneEl, root, agent)` 으로 뽑고, `openAgentTerminal` 은 남겨두되 이 태스크 마지막에 삭제한다.

PTY 가 없는 세션은 안내를 띄운다:

```javascript
    // 대화 탭 '원본' 뷰 — 그 세션의 PTY 를 이 엘리먼트에 붙인다. 터미널 탭(셸 전용)과는 별개다.
    async function mountAgentTerm(paneEl, root, agent) {
      paneEl.innerHTML = '<div class="chat-raw-host" data-raw-host></div>';
      const host = paneEl.querySelector('[data-raw-host]');
      let opened;
      try {
        opened = await api('/api/term-open', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({root, agent: {source: agent.source, sid: agent.sid}}),
        });
      } catch (e) {
        host.innerHTML = `<div class="empty">원본을 열지 못했어요 · ${escapeHtml(e.message)}</div>`;
        return;
      }
      if (!opened || !opened.tid) {
        host.innerHTML = `<div class="empty">이 세션은 지금 붙어있는 터미널이 없어요
          <span class="hint">대화에서 메시지를 보내면 이어받아요</span></div>`;
        return;
      }
      mountTermInstance(host, opened.tid);
    }
```

`/api/term-open` 의 실제 body 스키마를 확인해 맞춘다:

```bash
sed -n '1442,1470p' plugin/scripts/marina_handler.py
```

- [ ] **Step 2: AGENTS 행 클릭을 대화 탭으로 돌린다**

`app-5-sessions.js` 의 `wireAgentRows` 를 바꾼다:

```javascript
    // 행 클릭 = 대화 탭(에이전트 세션 워크스페이스), '>_' = 그 세션의 원본 터미널.
    // 예전엔 행 클릭이 터미널 attach 였다 — 터미널이 셸과 에이전트 조종을 겸해 경계가 없었고,
    // 그래서 detach 된 세션·과거 세션의 이미지를 볼 길이 없었다.
    function wireAgentRows(container, session, agents) {
      container.querySelectorAll('[data-agent-row][data-agent-sid]').forEach((row, i) => {
        const agent = agents.filter(a => a.sid)[i];
        row.onclick = (e) => { e.stopPropagation(); openAgentChat(session.root, agent); };
        const raw = row.querySelector('[data-agent-raw]');
        if (raw) raw.onclick = (e) => {
          e.stopPropagation();
          openAgentChat(session.root, agent);       // 탭을 열거나 이미 열린 탭으로 이동
          const tab = activeChatTab();
          if (tab) { tab.view = 'raw'; saveChatTabs(); renderChatPane(); }
        };
      });
    }
```

`renderAgentRow` (`:28` 부근)의 `data-agent-peek` 버튼을 `data-agent-raw` 로 바꾸고 라벨을 `대화` → `>_`, `title` 을 `원본 터미널로 열기` 로 바꾼다.

- [ ] **Step 3: 셸 사이드바에서 에이전트 PTY 를 뺀다**

`app-10-term.js:63-71` 의 목록 구성에서 `s.agent` 가 있는 항목을 거른다:

```javascript
        // 터미널 탭은 셸 전용이다. 에이전트 PTY 는 대화 탭 '원본' 뷰가 맡는다 — 한 세션을 여는
        // 길이 둘이면 어디서 뭘 하는지 알 수 없다.
        .filter(s => !s.agent)
```

- [ ] **Step 4: 읽기전용 모달을 삭제한다**

`app-6-modals.js:655-714` 의 `openAgentTranscript` 함수 전체를 지운다. 대화 탭이 상위 호환이다. 남은 참조가 없는지 확인한다:

```bash
grep -rn "openAgentTranscript\|openAgentTerminal\|data-agent-peek" plugin/scripts/marina-web/
```
Expected: 결과 없음.

- [ ] **Step 5: 실브라우저로 확인한다**

- AGENTS 행을 클릭하면 대화 탭이 열리고 그 세션이 선택되는가
- `>_` 아이콘은 같은 세션의 `원본` 뷰로 여는가
- 터미널 탭 사이드바에 에이전트 PTY 가 더 이상 안 보이는가
- 터미널 탭의 셸 기능(새 탭·4분할)이 그대로인가

- [ ] **Step 6: 커밋**

```bash
git add plugin/scripts/marina-web/app-5-sessions.js plugin/scripts/marina-web/app-10-term.js \
        plugin/scripts/marina-web/app-6-modals.js
git commit -m "$(cat <<'EOF'
refactor(web): 터미널은 셸만, 에이전트는 대화 탭 — 역할 분리

터미널 탭이 셸과 에이전트 조종을 겸해 경계가 없었다. 한 세션을 여는 길이
둘이면 어디서 뭘 하는지 알 수 없다. AGENTS 행 클릭을 대화 탭으로 돌리고,
원본 TUI 가 필요할 땐 대화 탭 안 [원본] 세그먼트로 같은 세션을 본다.

읽기전용 대화 모달은 대화 탭이 상위 호환이라 삭제.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4 — CLI 버전 배너

### Task 7: `marina_cliver.py`

**Files:**
- Create: `plugin/scripts/marina_cliver.py`
- Test: `plugin/tests/test-cli-version.sh`

**Interfaces:**
- Produces:
  - `cli_status() -> dict` — `{"claude": {...}, "codex": {...}}`. 각 항목은 `installed`, `latest`, `behind`, `method`, `cmd`, `autoUpdates` 키를 가진다. 조회 실패한 하네스는 딕셔너리에서 빠진다.
  - `cli_update(harness: str) -> dict` — `{"ok": True, "harness": ..., "installed": ..., "output": ...}`. 실패하면 `ValueError`.
  - `busy_agents(source: str) -> list` — `[{"title": ..., "status": ...}]`. 비어 있으면 업데이트 가능.
  - `_parse_version(text: str) -> str` — `"2.1.220 (Claude Code)"` → `"2.1.220"`, `"codex-cli 0.146.0"` → `"0.146.0"`.
  - `_version_behind(installed: str, latest: str) -> bool` — 숫자 세그먼트 비교.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`plugin/tests/test-cli-version.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import marina_cliver as cv

# ── 버전 파싱 — 두 CLI 의 실제 출력 형식 ──
assert cv._parse_version("2.1.220 (Claude Code)") == "2.1.220"
assert cv._parse_version("codex-cli 0.146.0") == "0.146.0"
assert cv._parse_version("0.146.0\n") == "0.146.0"
assert cv._parse_version("") == ""
assert cv._parse_version("garbage output") == ""

# ── behind 판정 — 숫자 세그먼트 비교(문자열 비교면 2.1.9 > 2.1.10 오판) ──
assert cv._version_behind("2.1.220", "2.2.0") is True
assert cv._version_behind("2.1.9", "2.1.10") is True
assert cv._version_behind("2.2.0", "2.2.0") is False
assert cv._version_behind("2.3.0", "2.2.0") is False
assert cv._version_behind("", "2.2.0") is False      # 모르면 배너 없음
assert cv._version_behind("2.2.0", "") is False      # 네트워크 실패 → 배너 없음
assert cv._version_behind("2.1.220", "2.1.220") is False

# ── 설치 방식 → 업데이트 명령 ──
assert cv._update_cmd("claude", "native") == ["claude", "update"]
assert cv._update_cmd("claude", "global") == ["npm", "i", "-g", "@anthropic-ai/claude-code"]
assert cv._update_cmd("codex", "brew") == ["brew", "upgrade", "codex"]
assert cv._update_cmd("codex", "npm") == ["npm", "i", "-g", "@openai/codex"]
assert cv._update_cmd("codex", "unknown") is None

# ── codex 설치 방식 판별 ──
assert cv._codex_method("/opt/homebrew/bin/codex") == "brew"
assert cv._codex_method("/usr/local/bin/codex") == "brew"
assert cv._codex_method("/Users/x/.nvm/versions/node/v22/bin/codex") == "npm"
assert cv._codex_method("") == ""

# ── 네트워크 실패는 조용히 ──
cv._LATEST_CACHE.clear()
orig = cv._fetch_latest
cv._fetch_latest = lambda pkg: None
try:
    st = cv.cli_status(refresh=True)
    for h in st.values():
        assert h["behind"] is False, "최신 버전을 모르면 behind 는 False 여야 한다"
        assert h["latest"] is None
finally:
    cv._fetch_latest = orig

# ── busy 가드 ──
assert isinstance(cv.busy_agents("claude"), list)

# ── busy 면 업데이트를 거부한다 ──
orig_busy = cv.busy_agents
cv.busy_agents = lambda source: [{"title": "asdf", "status": "running"}]
try:
    try:
        cv.cli_update("claude")
        raise AssertionError("busy 인데 업데이트가 실행됐다")
    except cv.BusyError as exc:
        assert exc.busy and exc.busy[0]["status"] == "running"
finally:
    cv.busy_agents = orig_busy

print("ok")
PY
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd plugin/tests && bash test-cli-version.sh
```
Expected: FAIL — `ModuleNotFoundError: No module named 'marina_cliver'`

- [ ] **Step 3: 모듈을 구현한다**

```python
"""marina_cliver.py — claude/codex **CLI 자체** 버전 감지·업데이트.

marina_update.py 와 다르다: 저쪽은 marina 플러그인의 SHA 를, 여기는 하네스 CLI 의 버전을 본다.
CLI 새 버전은 터미널에서 CLI 를 띄울 때만 보였다 — 대시보드·모바일에서는 알 길이 없었다.
(형 환경은 installMethod=native, autoUpdates=false 라 자동으로 올라가지도 않는다.)
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
import urllib.request
from pathlib import Path
from typing import Any

CLAUDE_JSON = Path(os.environ.get("CLAUDE_JSON", str(Path.home() / ".claude.json")))
PACKAGES = {"claude": "@anthropic-ai/claude-code", "codex": "@openai/codex"}
_LATEST_TTL_S = float(os.environ.get("MARINA_CLI_VERSION_TTL", "1800"))   # 30분 — 버전은 하루 단위로 바뀐다
_LATEST_CACHE: dict[str, Any] = {}
_STATUS_CACHE: dict[str, Any] = {}

_VERSION_RE = re.compile(r"(\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.]+)?)")


class BusyError(Exception):
    """작업 중인 세션이 있어 업데이트를 거부했다."""
    def __init__(self, busy: list[dict[str, str]]):
        super().__init__("작업 중인 세션이 있어요")
        self.busy = busy


def _parse_version(text: str) -> str:
    m = _VERSION_RE.search(text or "")
    return m.group(1) if m else ""


def _version_key(v: str) -> list[int]:
    return [int(x) for x in re.findall(r"\d+", v or "")]


def _version_behind(installed: str, latest: str) -> bool:
    # 모르면 False — 오탐(없는 업데이트를 있다고)보다 미탐이 낫다.
    if not installed or not latest:
        return False
    return _version_key(installed) < _version_key(latest)


def _installed_version(harness: str) -> str:
    exe = shutil.which(harness)
    if not exe:
        return ""
    try:
        out = subprocess.check_output([exe, "--version"], text=True, timeout=10,
                                      stderr=subprocess.STDOUT)
    except Exception:
        return ""
    return _parse_version(out)


def _fetch_latest(pkg: str) -> str | None:
    try:
        req = urllib.request.Request(f"https://registry.npmjs.org/{pkg}/latest",
                                     headers={"accept": "application/json"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            return str(json.loads(resp.read().decode("utf-8")).get("version") or "") or None
    except Exception:
        return None   # 네트워크 실패는 조용히 — 배너를 안 띄우면 된다


def _latest_version(pkg: str) -> str | None:
    now = time.time()
    hit = _LATEST_CACHE.get(pkg)
    if hit and now - hit["ts"] < _LATEST_TTL_S:
        return hit["version"]
    version = _fetch_latest(pkg)
    if version is not None:      # 실패하면 마지막 성공값을 유지한다
        _LATEST_CACHE[pkg] = {"ts": now, "version": version}
        return version
    return hit["version"] if hit else None


def _claude_config() -> dict[str, Any]:
    try:
        return json.loads(CLAUDE_JSON.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _codex_method(path: str) -> str:
    if not path:
        return ""
    return "brew" if path.startswith(("/opt/homebrew/", "/usr/local/")) else "npm"


def _update_cmd(harness: str, method: str) -> list[str] | None:
    if harness == "claude" and method == "native":
        return ["claude", "update"]
    if method == "brew":
        return ["brew", "upgrade", harness]
    if method in ("npm", "global"):
        return ["npm", "i", "-g", PACKAGES[harness]]
    return None


def cli_status(refresh: bool = False) -> dict[str, Any]:
    now = time.time()
    if not refresh and _STATUS_CACHE and now - _STATUS_CACHE.get("ts", 0) < _LATEST_TTL_S:
        return _STATUS_CACHE["payload"]
    cfg = _claude_config()
    out: dict[str, Any] = {}
    for harness, pkg in PACKAGES.items():
        installed = _installed_version(harness)
        if not installed:
            continue          # 설치 안 됨 — 항목 자체를 안 낸다
        latest = _latest_version(pkg)
        method = (str(cfg.get("installMethod") or "") if harness == "claude"
                  else _codex_method(shutil.which("codex") or ""))
        cmd = _update_cmd(harness, method)
        item = {
            "installed": installed,
            "latest": latest,
            "behind": _version_behind(installed, latest or ""),
            "method": method,
            "cmd": " ".join(cmd) if cmd else "",
        }
        if harness == "claude":
            item["autoUpdates"] = bool(cfg.get("autoUpdates"))
        out[harness] = item
    _STATUS_CACHE.update({"ts": now, "payload": out})
    return out


def busy_agents(source: str) -> list[dict[str, str]]:
    """그 하네스의 '작업 중' 세션. running/waiting 이면 업데이트를 막는다 —
    업데이트가 실행 파일을 갈아치우면 돌고 있는 세션이 깨진다."""
    from marina_sessions import agents_payload
    from marina_registry import load_projects   # 등록된 프로젝트의 워크트리들

    busy: list[dict[str, str]] = []
    seen: set[str] = set()
    for proj in load_projects():
        for root in _project_roots(proj):
            key = str(root)
            if key in seen:
                continue
            seen.add(key)
            try:
                agents = agents_payload(root)
            except Exception:
                continue
            for a in agents:
                if a.get("source") == source and a.get("status") in ("running", "waiting"):
                    busy.append({"title": str(a.get("title") or ""), "status": str(a.get("status"))})
    return busy


def cli_update(harness: str) -> dict[str, Any]:
    if harness not in PACKAGES:
        raise ValueError(f"알 수 없는 하네스: {harness}")
    busy = busy_agents(harness)
    if busy:
        raise BusyError(busy)
    status = cli_status(refresh=True).get(harness) or {}
    cmd = _update_cmd(harness, str(status.get("method") or ""))
    if not cmd:
        raise ValueError(f"{harness} 설치 방식을 알 수 없어 자동 업데이트를 못 해요")
    try:
        out = subprocess.check_output(cmd, text=True, timeout=300, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as exc:
        raise ValueError(f"{' '.join(cmd)} 실패: {(exc.output or '').strip()[-200:]}")
    except Exception as exc:
        raise ValueError(f"{harness} 업데이트 실패: {exc}")
    # 무효화는 완료 "후" — 진행 중 폴링이 옛 버전으로 캐시를 재충전하는 레이스 차단.
    _STATUS_CACHE.clear()
    return {"ok": True, "harness": harness,
            "installed": _installed_version(harness), "output": out.strip()[-200:]}
```

`_project_roots(proj)` 와 `load_projects` 의 실제 이름·반환형을 확인해 맞춘다:

```bash
grep -n "def load_projects" -A 10 plugin/scripts/marina_registry.py
grep -n "def worktree_roots\|def project_worktrees\|worktrees(" plugin/scripts/marina_registry.py | head
```
헬퍼가 없으면 `marina_sessions.py` 에서 워크트리 목록을 얻는 기존 경로를 찾아 쓴다 (`/api/worktrees` 가 쓰는 함수).

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
cd plugin/tests && bash test-cli-version.sh
```
Expected: `ok`

- [ ] **Step 5: 실제 환경에서 눈으로 확인한다**

```bash
cd plugin/scripts && python3 -c "
import json, marina_cliver as cv
print(json.dumps(cv.cli_status(refresh=True), indent=2, ensure_ascii=False))
"
```
Expected: `claude` 는 `method: "native"`, `autoUpdates: false`, `cmd: "claude update"`. `codex` 는 `method: "brew"`, `cmd: "brew upgrade codex"`. 두 `installed` 가 `claude --version`·`codex --version` 과 일치해야 한다.

- [ ] **Step 6: 커밋**

```bash
git add plugin/scripts/marina_cliver.py plugin/tests/test-cli-version.sh
git commit -m "$(cat <<'EOF'
feat(cliver): claude·codex CLI 버전 감지 — 터미널 밖에서도 새 버전을 알게

CLI 새 버전은 터미널에서 CLI 를 띄울 때만 보였다. 대시보드·모바일에서는
알 길이 없었고, native 설치 + autoUpdates=false 면 자동으로 올라가지도 않는다.

installed 는 --version, latest 는 npm registry. 모르면 behind=False —
오탐보다 미탐이 낫다. 업데이트는 돌고 있는 세션이 있으면 거부한다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: 라우트와 배너 (web + mobile)

**Files:**
- Modify: `plugin/scripts/marina_update.py` (`update_status` 에 `cli` 병합)
- Modify: `plugin/scripts/marina_handler.py` (`/mobile/api/update-status` GET, `/mobile/api/cli-update` POST)
- Modify: `plugin/scripts/marina-web/app-6-modals.js` (`renderUpdateBanner` 에 CLI 섹션)
- Modify: `plugin/scripts/marina_mobile.py` (`cliUpdateBanner` 요소·폴링)
- Modify: `plugin/tests/test-cli-version.sh` (라우트 검증 추가)

**Interfaces:**
- Consumes: `cli_status()`, `cli_update(harness)`, `BusyError` (Task 7)
- Produces: `/api/update-status` 응답의 `cli` 키. `/api/agent/cli-update` 와 `/mobile/api/cli-update` POST (`{harness}` → 200 또는 409 `{busy: [...]}`).

- [ ] **Step 1: `update_status` 에 `cli` 를 얹는다**

`marina_update.py` 의 `update_status()` 안, `payload` 를 만든 직후:

```python
    try:
        from marina_cliver import cli_status
        payload["cli"] = cli_status()
    except Exception:
        payload["cli"] = {}     # CLI 조회 실패가 플러그인 업데이트 배너를 막으면 안 된다
```

- [ ] **Step 2: 라우트를 추가한다**

`marina_handler.py` do_GET 의 `/mobile/api/activity` 블록 뒤에:

```python
        if parsed.path == "/mobile/api/update-status":
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            self.send_json(update_status())
            return
```

do_POST 의 `/mobile/api/interrupt` 블록 뒤에:

```python
            if parsed.path == "/mobile/api/cli-update":
                if not self._agent_api_ok(parsed, principal):
                    self.send_json({"error": "mobile disabled or invalid token"}, 403)
                    return
                if not self._require_admin_access():
                    return
                try:
                    from marina_cliver import BusyError, cli_update
                    body = self.read_json()
                    self.send_json(cli_update(str(body.get("harness", ""))))
                except BusyError as exc:
                    # 돌고 있는 세션이 있으면 실행 파일을 갈아치우지 않는다.
                    self.send_json({"error": "busy", "busy": exc.busy}, 409)
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
```

`update_status` 가 이미 import 돼 있는지 확인한다:

```bash
grep -n "from marina_update import" plugin/scripts/marina_handler.py
```

- [ ] **Step 3: 라우트 검증을 테스트에 더한다**

`test-cli-version.sh` 의 python 블록 끝(`print("ok")` 앞)에:

```python
# ── 라우트가 배선돼 있다 ──
import marina_handler as mh
src = open(mh.__file__, encoding="utf-8").read()
assert '"/mobile/api/update-status"' in src, "모바일 update-status 라우트가 없다"
assert '"/mobile/api/cli-update"' in src, "cli-update 라우트가 없다"
assert "BusyError" in src, "busy 가드가 라우트에 없다"

# ── update_status 페이로드에 cli 키가 있다 ──
import marina_update as mu
assert "cli" in mu.update_status(), "update_status 에 cli 키가 없다"
```

```bash
cd plugin/tests && bash test-cli-version.sh
```
Expected: `ok`

- [ ] **Step 4: 웹 배너에 CLI 섹션을 붙인다**

`app-6-modals.js` 의 `renderUpdateBanner(s)` 를 고친다. 지금은 `s.state` 가 `current`/`unknown` 이면 배너를 통째로 숨기는데(`:305`), CLI 가 뒤처졌으면 떠야 하므로 조건을 바꾼다:

```javascript
      const cli = s && s.cli || {};
      const cliBehind = Object.keys(cli).filter(h => cli[h].behind);
      if (!s || ((s.state === 'current' || s.state === 'unknown') && !cliBehind.length)) {
        el.hidden = true; el.innerHTML = ''; return;
      }
```

`sig` 계산에도 `cli` 를 넣어야 변화가 반영된다:

```javascript
      const sig = JSON.stringify(s ? [s.state, s.serving, s.installed, s.origin, s.harnessStatus, s.cli] : null);
```

CLI 칩과 버튼을 렌더한다 (marina 배너 내용 뒤에 이어붙인다):

```javascript
      // CLI 버전 — marina 플러그인 업데이트와 같은 배너에 산다(폴링도 같은 /api/update-status).
      if (cliBehind.length) {
        const chips = cliBehind.map(h => `<span class="ub-hchip old" title="${escapeHtml(cli[h].cmd)}">
          <i></i>${escapeHtml(h)} <span class="sha">${escapeHtml(cli[h].installed)} → ${escapeHtml(cli[h].latest)}</span>
          <button class="ub-btn" data-cli-update="${escapeHtml(h)}">받기</button></span>`).join('');
        el.insertAdjacentHTML('beforeend', `<span class="ub-cli">${chips}</span>`);
        el.querySelectorAll('[data-cli-update]').forEach(btn => {
          btn.onclick = () => doCliUpdate(btn, btn.dataset.cliUpdate);
        });
      }
```

```javascript
    async function doCliUpdate(btn, harness) {
      btn.disabled = true; btn.innerHTML = BUSY_DOTS;
      try {
        const r = await api('/api/agent/cli-update', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({harness}),
        });
        showToast(`${harness} ${r.installed} 로 업데이트했어요`, 'ok');
        updateBannerSig = '';                       // 다음 폴링에 새 상태로 다시 그리게
        await loadUpdateStatus();
      } catch (e) {
        // 409 = 돌고 있는 세션이 있음. api() 가 어떤 형태로 에러를 던지는지에 맞춘다.
        const busy = e && e.payload && e.payload.busy;
        showToast(busy && busy.length
          ? `${harness} 세션 ${busy.length}개 작업 중 — 끝나면 받아요`
          : `업데이트 실패 · ${e.message}`, 'err');
      } finally {
        btn.disabled = false; btn.innerHTML = '받기';
      }
    }
```

`api()` 가 비-2xx 응답의 body 를 어떻게 실어 던지는지 확인해 `e.payload` 를 맞춘다:

```bash
grep -n "async function api" -A 20 plugin/scripts/marina-web/app-3-util.js
```

- [ ] **Step 5: 모바일 배너를 붙인다**

`_MOBILE_HTML` 의 `updateBanner`(데몬 재시작용) **옆에** 별도 요소를 넣는다 — 이름이 겹치면 안 된다:

```html
    <div class="cliUpdateBanner" id="cliUpdateBanner" hidden></div>
```

폴링은 기존 상태 폴링에 얹되 주기를 낮춘다(60초에 1회). 뒤처진 하네스가 있을 때만 표시하고, 탭하면 `POST /mobile/api/cli-update` 를 부른다. 409 면 `busy` 개수를 그대로 문구에 쓴다.

- [ ] **Step 6: 양쪽을 실측한다**

실제로 뒤처진 상태를 만들 수 없으면 강제로 만든다:

```bash
MARINA_CLI_VERSION_TTL=0 python3 -c "
import marina_cliver as cv
cv._fetch_latest = lambda pkg: '99.0.0'
cv._LATEST_CACHE.clear(); cv._STATUS_CACHE.clear()
print(cv.cli_status(refresh=True))
"
```

데몬에 같은 스텁을 물릴 수 없으므로, UI 검증은 `/api/update-status` 응답을 브라우저 devtools 에서 가로채거나 `_fetch_latest` 를 잠시 하드코딩해 데몬을 재시작한 뒤 확인한다. 확인 항목: 웹·모바일 배너가 `installed → latest` 로 뜨는가, `받기` 가 동작하는가, 세션이 돌고 있을 때 409 문구가 뜨는가.

- [ ] **Step 7: 커밋**

```bash
git add plugin/scripts/marina_update.py plugin/scripts/marina_handler.py \
        plugin/scripts/marina-web/app-6-modals.js plugin/scripts/marina_mobile.py \
        plugin/tests/test-cli-version.sh
git commit -m "$(cat <<'EOF'
feat(update): CLI 버전 배너 — 웹·모바일 양쪽

기존 /api/update-status 페이로드에 cli 키를 얹어 폴링을 하나로 유지한다.
모바일엔 update-status 라우트 자체가 없었어서 같이 추가.

받기는 돌고 있는 세션이 있으면 409 로 거부하고 개수를 문구로 돌려준다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 5 — 모바일 로그·깃

### Task 9: 읽기 라우트

**Files:**
- Modify: `plugin/scripts/marina_handler.py` (do_GET — `/mobile/api/logs/*`, `/mobile/api/git-*`)
- Test: `plugin/tests/test-mobile-logs-git.sh`

**Interfaces:**
- Consumes: `read_log_chunk`, `scan_log_matches`, `selected_log` (`marina_logtext.py`), `git_graph`, `git_wip_stat`, `git_diff`, `git_commit_info` (`marina_git.py`)
- Produces: `/mobile/api/logs/chunk`, `/mobile/api/logs/matches`, `/mobile/api/git-graph`, `/mobile/api/git-wip-stat`, `/mobile/api/git-diff`, `/mobile/api/git-commit-info`. 응답은 대응하는 `/api/*` 라우트와 동일하다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`plugin/tests/test-mobile-logs-git.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import re
import marina_handler as mh

src = open(mh.__file__, encoding="utf-8").read()

# ── 읽기 라우트가 있다 ──
READ = ["/mobile/api/logs/chunk", "/mobile/api/logs/matches", "/mobile/api/git-graph",
        "/mobile/api/git-wip-stat", "/mobile/api/git-diff", "/mobile/api/git-commit-info"]
for path in READ:
    assert f'"{path}"' in src, f"라우트 없음: {path}"

# ── 쓰기 라우트는 모바일 프리픽스에 없다 ──
WRITE = ["git-commit", "git-push", "git-merge", "git-rebase", "git-stash", "git-fetch",
         "git-pull", "logs/download"]
for op in WRITE:
    assert f'"/mobile/api/{op}"' not in src, f"쓰기 라우트가 모바일에 새어 나갔다: {op}"

# ── 각 읽기 라우트가 root 접근을 검사한다 ──
for path in READ:
    idx = src.index(f'"{path}"')
    block = src[idx: idx + 1200]
    assert "_require_root_access" in block, f"{path} 가 root 접근을 검사하지 않는다"
    assert "_agent_api_ok" in block, f"{path} 가 인증을 검사하지 않는다"
print("ok")
PY
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd plugin/tests && bash test-mobile-logs-git.sh
```
Expected: FAIL — `라우트 없음: /mobile/api/logs/chunk`

- [ ] **Step 3: 라우트를 구현한다**

`marina_handler.py` do_GET, `/mobile/api/activity` 블록 뒤에 넣는다. 기존 `/api/*` 라우트의 로직을 그대로 재사용하되 인증·권한만 모바일 규약을 따른다:

```python
        if parsed.path in ("/mobile/api/logs/chunk", "/mobile/api/logs/matches"):
            # 모바일 로그 뷰어(읽기 전용) — 서버 로직은 웹 /api/logs/* 와 같은 함수를 쓴다.
            # 다운로드·콘솔로그·게이지는 넣지 않는다(작은 화면 ROI).
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                if not self._require_root_access(root):
                    return
                service = safe_service(query.get("service", [""])[0])
                run = query.get("run", ["current"])[0]
                path = selected_log(root, service, run)
                if parsed.path.endswith("/matches"):
                    q = query.get("q", [""])[0]
                    err_only = query.get("errOnly", ["0"])[0] == "1"
                    payload = ({"matches": [], "total": 0, "size": 0, "truncated": False}
                               if not q and not err_only else scan_log_matches(path, q, err_only))
                else:
                    after_raw = query.get("after", [None])[0]
                    payload = (read_log_chunk(path, after=int(after_raw)) if after_raw is not None
                               else read_log_chunk(path, before=int(query.get("before", ["0"])[0])))
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_json(payload)
            return

        if parsed.path in ("/mobile/api/git-graph", "/mobile/api/git-wip-stat",
                           "/mobile/api/git-diff", "/mobile/api/git-commit-info"):
            # 모바일 깃(읽기 전용) — 커밋·푸시·머지 같은 쓰기는 의도적으로 노출하지 않는다.
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                if not self._require_root_access(root):
                    return
                repo = query.get("repo", ["."])[0]
                if parsed.path.endswith("git-graph"):
                    payload = git_graph(root, repo,
                                        refresh=query.get("refresh", ["0"])[0] == "1",
                                        all_remotes=False, want_avatars=False)
                elif parsed.path.endswith("git-wip-stat"):
                    payload = git_wip_stat(root, repo)
                elif parsed.path.endswith("git-commit-info"):
                    payload = git_commit_info(root, repo, query.get("commit", [""])[0])
                else:
                    payload = self._git_diff_payload(root, repo, query)
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_json(payload)
            return
```

`/api/git-diff` (`:1045-1056`) 가 인자를 어떻게 넘기는지 읽고, 같은 호출을 `_git_diff_payload(self, root, repo, query)` 헬퍼로 뽑아 두 라우트가 공유하게 한다. 인자 조합을 복붙하면 한쪽만 고쳐질 위험이 있다.

```bash
sed -n '1045,1057p' plugin/scripts/marina_handler.py
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
cd plugin/tests && bash test-mobile-logs-git.sh
```
Expected: `ok`

- [ ] **Step 5: 커밋**

```bash
git add plugin/scripts/marina_handler.py plugin/tests/test-mobile-logs-git.sh
git commit -m "$(cat <<'EOF'
feat(mobile): 로그·깃 읽기 라우트 — 밖에서 빌드 상태를 볼 수 있게

모바일엔 로그도 깃도 없어서 "빌드 깨졌나"를 확인할 방법이 없었다.
서버 로직은 웹과 같은 함수를 그대로 쓴다(신규 0). 쓰기 계열(커밋·푸시·
머지·리베이스·스태시)은 의도적으로 노출하지 않는다 — 테스트로 잠갔다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: 모바일 로그·깃 시트 UI

**Files:**
- Modify: `plugin/scripts/marina_mobile.py` (`_MOBILE_HTML` — 시트 2개, CSS, 스크립트)

**Interfaces:**
- Consumes: Task 9 의 라우트.
- Produces: 사용자 대면 기능. 다른 태스크가 의존하지 않는다.

- [ ] **Step 1: 시트 마크업을 넣는다**

기존 시트(`servicesSheet`, `gallerySheet`) 패턴을 그대로 따른다. `gallerySheet` 뒤에:

```html
    <div class="sheet" id="logsSheet" hidden>
      <div class="sheetHead"><span id="logsSheetTitle">로그</span>
        <button id="logsCloseBtn" type="button">✕</button></div>
      <div class="sheetTools">
        <select id="logsService"></select>
        <select id="logsRun"></select>
        <input id="logsFilter" placeholder="필터" />
        <button id="logsErrOnly" type="button">에러만</button>
      </div>
      <div class="logsBody" id="logsBody"></div>
    </div>
    <div class="sheet" id="gitSheet" hidden>
      <div class="sheetHead"><span id="gitSheetTitle">깃</span>
        <button id="gitCloseBtn" type="button">✕</button></div>
      <div class="gitStatus" id="gitStatus"></div>
      <div class="gitBody" id="gitBody"></div>
    </div>
```

- [ ] **Step 2: 진입점을 붙인다**

세션 카드의 기존 액션 줄(서비스 시트를 여는 버튼 옆)에 `로그`·`깃` 버튼을 넣는다. 위치는 `servicesSheet` 를 여는 버튼을 찾아 그 옆이다:

```bash
grep -n "servicesSheet\|openServices" plugin/scripts/marina_mobile.py | head
```

- [ ] **Step 3: 로그 시트를 구현한다**

- 열 때 `/mobile/api/services?root=…` 로 서비스 목록을 받아 `logsService` 를 채운다.
- `/mobile/api/logs/chunk?root=…&service=…&run=current` 로 tail 을 받아 `logsBody` 에 넣는다.
- `logsFilter`·`logsErrOnly` 는 `/mobile/api/logs/matches` 를 부르고 매치 줄만 보인다.
- 시트가 열려 있을 때만 3초 폴링한다. 사용자가 위로 스크롤했으면 하단 추적을 끈다.

- [ ] **Step 4: 깃 시트를 구현한다**

- `/mobile/api/git-wip-stat` 로 변경 파일 목록과 ahead/behind 를 받아 `gitStatus` 에 요약을 그린다.
- 파일을 탭하면 `/mobile/api/git-diff` 로 그 파일 diff 를 받아 펼친다. diff 색은 기존 `.activityCode .diffHunk` 스타일을 재사용한다.
- `/mobile/api/git-graph` 로 최근 커밋을 받아 리스트로 그린다(레인 없음). 커밋을 탭하면 `/mobile/api/git-commit-info` 로 파일 목록을 펼친다.

- [ ] **Step 5: 실측한다**

모바일(또는 좁은 뷰포트 브라우저)에서 확인한다: 로그가 뜨고 필터·에러만이 먹는가, 깃에서 변경 파일과 diff 가 보이는가, 커밋 목록이 뜨는가, 쓰기 버튼이 하나도 없는가.

- [ ] **Step 6: 커밋**

```bash
git add plugin/scripts/marina_mobile.py
git commit -m "$(cat <<'EOF'
feat(mobile): 로그·깃 시트 — 읽기 전용

기존 시트 패턴 그대로. 로그는 tail+필터+에러만+run 선택, 깃은 WIP 변경
파일·파일별 diff·최근 커밋 목록·커밋 상세. 레인 그래프는 작은 화면에
안 맞아 커밋 리스트로만 그린다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: 전체 회귀와 마무리

**Files:**
- Modify: 필요 시 발견된 회귀 지점

- [ ] **Step 1: 전체 테스트를 돌린다**

```bash
cd plugin/tests && pass=0; fail=0
for f in test-*.sh; do
  if bash "$f" >/tmp/marina-test-out 2>&1; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL $f"; tail -5 /tmp/marina-test-out; fi
done
echo "pass=$pass fail=$fail"
```
Expected: `fail=0`

- [ ] **Step 2: 실브라우저 통합 확인**

끝까지 해 본다: 워크트리 선택 → `대화` 워크스페이스 → 서로 다른 워크트리의 세션 3개를 탭으로 열기 → 탭 A 에 초안을 치다가 B 로 전환 후 복귀(초안 보존) → B 세션이 응답하면 A 에 있을 때 B 탭에 점 → 메시지 전송 → 이미지가 온 응답 확인 → `원본` 토글 → 탭 하나 닫기 → 새로고침 후 탭 복원 → `터미널` 탭에서 셸 명령(에이전트 PTY 없음 확인) → 모바일에서 같은 세션 열기 → 모바일 로그·깃 시트 → 양쪽 CLI 배너.

- [ ] **Step 3: codex 리뷰를 받는다**

이 레포 규칙대로 구현은 Claude 가 했고 리뷰는 codex 가 한다. 브랜치 diff 를 넘겨 리뷰를 받고, 지적은 `superpowers:receiving-code-review` 로 검증한 뒤 반영한다.

- [ ] **Step 4: 스펙에 완료를 기록한다**

`docs/superpowers/specs/2026-08-03-web-mobile-parity-design.md` 의 상태 줄을 갱신하고, 구현 중 설계와 달라진 점이 있으면 그 이유와 함께 적는다.

- [ ] **Step 5: 형에게 검토를 요청한다**

push 하지 않는다. 브랜치에 쌓아 두고 형의 검토·승인을 받은 뒤 push 한다.

---

## Self-Review

**스펙 커버리지**

| 스펙 절 | 태스크 |
|---|---|
| 멘탈 모델 (역할 분리) | Task 4, 6 |
| §1 이중 프리픽스 | Task 1 |
| §2 렌더러 공유 | Task 2, 3 |
| §3 대화 탭 — 세션 멀티탭 | Task 4 (Step 3~8) |
| §3 대화 탭 — 타임라인·전송 | Task 5 |
| §3 대화 탭 — 진입점·역할 분리 | Task 6 |
| §4 CLI 버전 배너 | Task 7, 8 |
| §5 모바일 로그·깃 | Task 9, 10 |
| 테스트 5종 | Task 1, 3, 7, 8, 9 + Task 11 전체 회귀 |

**미해결로 남기는 것 (의도적)**

- Task 2 는 분석 태스크라 커밋이 없다. 산출물은 Task 3 의 입력인 메모다.
- **세션 멀티탭에는 bash 테스트가 없다.** `localStorage`·탭 전환·초안 보존은 브라우저 상태라 이 레포의 테스트 형식(bash + python 모듈 단언)으로는 검증이 안 된다. Task 4 Step 8 과 Task 5 Step 5 의 실브라우저 확인이 유일한 게이트다 — 그래서 확인 항목을 구체적으로 적어 두었다.
- Task 10 의 시트 구현은 코드 블록 대신 동작 명세로 적었다. 모바일 HTML 은 인라인 문자열이라 정확한 삽입 지점이 Task 3 의 추출 결과에 따라 달라지기 때문이다. Task 3 을 끝낸 뒤 그 자리에서 확정한다.
- `reconcileActivityList` 등 공유 렌더러의 최종 시그니처는 Task 2 에서 확정된다. Task 5 의 호출부는 그때 맞춘다 — 계획에 적은 시그니처는 목표이지 확정이 아니다.
