# 공유 렌더 Reconciler + 웹 핵심 이주 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 폴링 재렌더가 상호작용 상태(포커스·캐럿·미저장값·스크롤·열린 select/메뉴)를 파괴하는 버그 클래스를, 사이트별 땜빵 대신 **공유 keyed reconciler 1개**로 근절한다 — 웹 핵심 사이트(인박스·세션카드)를 그 위로 이주하고 기존 가드를 삭제한다.

**Architecture:** 순수 vanilla JS. 프레임워크 도입 없음. `reconcile(container, items, {key, create, patch})` 한 개가 노드를 key로 재사용하고 바뀐 텍스트/속성만 patch → 노드를 부수지 않아 상호작용 상태가 구조적으로 생존. 웹 파일은 `<script>` 로 전역 스코프 concat 로드(모듈 아님).

**Tech Stack:** 브라우저 vanilla JS(전역 함수), 테스트는 node `vm` + 최소 DOM 스텁(순수 로직) + Aside 실브라우저 e2e(포커스/스크롤/드롭다운 보존). 백엔드 무관.

## Global Constraints

- 새 프론트 파일은 **전역 스코프 함수 선언**(IIFE/모듈 금지) — 로드 순서 무관, 다른 app-*.js 와 동일 패턴.
- top-level 에서 `document` 를 만지면 DOM 없는 단위테스트 vm 이 깨진다 → top-level 코드는 함수 선언만. (선례: `app-5-sessions.js` `typeof document` 가드 필요했던 회귀.)
- 마이그레이션은 **사이트 1개당 1커밋** — 각 이주에서 기존 가드 삭제 + Aside 검증까지 한 커밋. 회귀를 사이트 단위로 격리.
- 러닝 대시보드는 plugin 캐시 서빙이라 라이브 검증은 asdf 코드를 별도 포트(3910)에 실데이터로 띄워(auth off: `MARINA_AUTH_DB=<tmp>`, `MARINA_HOME=/Users/sumin/.marina`, `MARINA_CONTROL_PORT=3910`) Aside 로.
- 모든 커밋 메시지 끝에 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- asdf 브랜치 누적, 미push. 형 검토 후 push.

---

## File Structure

- **Create** `plugin/scripts/marina-web/app-0b-reconcile.js` — `reconcile()` + `patchNode()` 헬퍼 하나. `app-0-auth.js` 다음, 다른 render 보다 먼저 로드(전역 제공).
- **Modify** `plugin/scripts/marina-web/index.html` — 위 스크립트 태그 추가(다른 app-*.js 보다 앞).
- **Modify** `plugin/scripts/marina-web/app-1-core.js` — `renderAgentInbox` 를 reconcile 로, `lastInboxSig`+scroll/focus capture 삭제.
- **Modify** `plugin/scripts/marina-web/app-5-sessions.js` — `render()` 카드 리스트를 root-key reconcile 로, `panelEditing`/`renderDeferred`/focusout defer 삭제, `updateServiceStates` 를 patch 경로로 흡수.
- **Create** `plugin/tests/test-reconcile.sh` — reconcile 순수 로직 유닛(node vm + DOM 스텁).
- **Create** `plugin/tests/test-reconcile-e2e.sh` — Aside 실브라우저 보존 검증(3910 기동 → 인박스/카드 상호작용 중 폴 렌더 → 상태 유지).

---

## Task 1: `reconcile()` 프리미티브 + 순수 로직 유닛

**Files:**
- Create: `plugin/scripts/marina-web/app-0b-reconcile.js`
- Test: `plugin/tests/test-reconcile.sh`

**Interfaces:**
- Produces: `reconcile(container, items, opts)` where `opts = {key:(item)=>string, create:(item)=>Element, patch:(el,item)=>void}`. 컨테이너 자식을 items 에 맞춰 key 기준 재사용/생성/재정렬/삭제. 반환 없음. `create` 로 만든 노드엔 `el.dataset.rkey = key` 를 자동 세팅해 다음 회차에 매칭.

- [ ] **Step 1: 실패 테스트 작성** — `plugin/tests/test-reconcile.sh`

```bash
#!/usr/bin/env bash
# reconcile() 순수 로직 — 노드 재사용/추가/삭제/재정렬. DOM 없는 node vm + 최소 스텁.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="$HERE/../scripts/marina-web/app-0b-reconcile.js"

node - "$SRC" <<'JS'
const fs = require('fs'); const vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');

// 최소 DOM 스텁: childNodes 배열, appendChild/insertBefore/removeChild, dataset, 간단 textContent.
function makeEl(tag='div') {
  const el = {
    tagName: tag.toUpperCase(), dataset: {}, _children: [], parentNode: null,
    get children(){ return this._children; },
    appendChild(c){ if(c.parentNode) c.parentNode.removeChild(c); c.parentNode=this; this._children.push(c); return c; },
    insertBefore(c, ref){ if(c.parentNode) c.parentNode.removeChild(c); c.parentNode=this;
      const i = ref? this._children.indexOf(ref): -1; if(i<0) this._children.push(c); else this._children.splice(i,0,c); return c; },
    removeChild(c){ const i=this._children.indexOf(c); if(i>=0)this._children.splice(i,1); c.parentNode=null; return c; },
    get firstChild(){ return this._children[0] || null; },
  };
  return el;
}
const ctx = { document: { createElement: makeEl }, console };
vm.createContext(ctx);
vm.runInContext(src, ctx, {filename:'app-0b-reconcile.js'});
const { reconcile } = ctx;
if (typeof reconcile !== 'function') { console.log('FAIL reconcile not defined'); process.exit(1); }

const box = makeEl();
const create = it => { const e = makeEl(); e._id = it.id; e._patched = it.v; return e; };
const patch = (e, it) => { e._patched = it.v; };
const key = it => String(it.id);

// 1) 최초 생성 — 순서대로
reconcile(box, [{id:'a',v:1},{id:'b',v:2},{id:'c',v:3}], {key,create,patch});
let ids = box.children.map(c=>c._id);
if (ids.join() !== 'a,b,c') { console.log('FAIL initial order', ids); process.exit(1); }
const nodeA = box.children[0], nodeB = box.children[1];

// 2) 값만 변경 — 같은 노드 재사용(정체성 유지) + patch 반영
reconcile(box, [{id:'a',v:10},{id:'b',v:2},{id:'c',v:3}], {key,create,patch});
if (box.children[0] !== nodeA) { console.log('FAIL node A not reused'); process.exit(1); }
if (box.children[0]._patched !== 10) { console.log('FAIL patch not applied'); process.exit(1); }

// 3) 중간 삭제
reconcile(box, [{id:'a',v:10},{id:'c',v:3}], {key,create,patch});
if (box.children.map(c=>c._id).join() !== 'a,c') { console.log('FAIL delete', box.children.map(c=>c._id)); process.exit(1); }

// 4) 재정렬 + 신규 삽입 — 기존 노드 재사용
reconcile(box, [{id:'c',v:3},{id:'d',v:4},{id:'a',v:10}], {key,create,patch});
if (box.children.map(c=>c._id).join() !== 'c,d,a') { console.log('FAIL reorder', box.children.map(c=>c._id)); process.exit(1); }
if (box.children[2] !== nodeA) { console.log('FAIL A identity lost after reorder'); process.exit(1); }

console.log('PASS reconcile keyed reuse/add/remove/reorder');
JS
```

- [ ] **Step 2: 실패 확인**

Run: `bash plugin/tests/test-reconcile.sh`
Expected: FAIL — `reconcile not defined` (파일 아직 없음/빈).

- [ ] **Step 3: 최소 구현** — `plugin/scripts/marina-web/app-0b-reconcile.js`

```javascript
    // app-0b-reconcile.js — 공유 keyed DOM reconciler. 폴링 재렌더가 노드를 부수지 않게 하는 단일 프리미티브.
    // 노드를 key 로 재사용하고 바뀐 것만 patch → 포커스·캐럿·미저장 입력값·스크롤·열린 select/메뉴·<details> open 이
    // 구조적으로 생존한다(노드가 안 사라지니까). 사이트별 signature-skip/defer/capture-restore 가드를 대체한다.
    function reconcile(container, items, opts) {
      const key = opts.key, create = opts.create, patch = opts.patch;
      // 현재 자식을 key→node 로 색인
      const existing = new Map();
      for (const node of Array.from(container.children)) {
        const k = node.dataset ? node.dataset.rkey : undefined;
        if (k != null) existing.set(k, node);
      }
      let cursor = null;   // 다음에 위치시킬 자리(직전에 배치한 노드의 다음)
      const seen = new Set();
      for (const item of items) {
        const k = String(key(item));
        seen.add(k);
        let node = existing.get(k);
        if (node) {
          if (patch) patch(node, item);
        } else {
          node = create(item);
          if (node.dataset) node.dataset.rkey = k;
        }
        // 제자리에 없으면 이동/삽입 — cursor 다음이 이 노드가 아니면 옮긴다
        const ref = cursor ? cursor.nextSibling || null : container.firstChild;
        if (ref !== node) container.insertBefore(node, ref);
        cursor = node;
      }
      // items 에 없는 잔여 노드 제거
      for (const [k, node] of existing) {
        if (!seen.has(k)) container.removeChild(node);
      }
    }
```

> 참고: 스텁엔 `nextSibling` 이 없으므로 최소 구현은 `insertBefore(node, ref)` 로 순서를 잡되, 브라우저에선 `node.nextSibling`/`container.firstChild` 로 동작. 스텁 테스트가 순서만 검증하도록 위 테스트는 최종 순서 배열로 단정(구현이 매 아이템을 순서대로 insertBefore 하면 통과). **구현 시 스텁에 `nextSibling` getter가 없으면 `ref` 계산을 `container.children[placedCount]` 인덱스 기반으로 바꿔도 됨 — 테스트가 통과하는 방식으로.**

- [ ] **Step 4: 통과 확인**

Run: `bash plugin/tests/test-reconcile.sh`
Expected: PASS — `reconcile keyed reuse/add/remove/reorder`.

- [ ] **Step 5: index.html 에 스크립트 등록**

`plugin/scripts/marina-web/index.html` 에서 `app-1-core.js` 로드 **직전**(또는 `app-0-auth.js` 직후)에 추가:
```html
  <script src="/web/app-0b-reconcile.js"></script>
```

- [ ] **Step 6: 문법 확인 + 커밋**

```bash
node --check plugin/scripts/marina-web/app-0b-reconcile.js
git add plugin/scripts/marina-web/app-0b-reconcile.js plugin/scripts/marina-web/index.html plugin/tests/test-reconcile.sh
git commit -m "feat(web): shared keyed DOM reconciler primitive

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: 인박스 이주(reconcile) + 기존 가드 삭제

가장 단순하고 이미 가드가 있는 사이트 → reconcile 패턴을 검증하고 `lastInboxSig`+scroll/focus capture 를 지운다.

**Files:**
- Modify: `plugin/scripts/marina-web/app-1-core.js` (renderAgentInbox, 현재 ~90-134)

**Interfaces:**
- Consumes: `reconcile` (Task 1).

- [ ] **Step 1: 현재 renderAgentInbox 읽기**

Run: `sed -n '88,135p' plugin/scripts/marina-web/app-1-core.js`
확인: `lastInboxSig` 시그니처 skip, `prevScroll`/`focusedId` capture-restore, `panel.innerHTML=entries.map(...)` 전체 재빌드.

- [ ] **Step 2: reconcile 로 교체**

`renderAgentInbox` 본문에서 열린 경우(`agentInboxOpen`)의 렌더를 아래로 교체. `lastInboxSig` 선언·시그니처 비교·`prevScroll`/`focusedId` 캡처·복원 블록을 **삭제**하고:

```javascript
      // 아이템 = agentInboxEntries(); key = eventId. 그룹 헤더는 각 항목 앞에 필요 시 붙는 형제로 유지하기 위해
      // 프로젝트가 바뀌는 첫 항목만 group 클래스를 갖는 단일 버튼으로 렌더(구조 단순화).
      reconcile(panel, entries, {
        key: item => item.eventId,
        create: item => {
          const b = document.createElement('button');
          b.className = 'agent-inbox-item';
          b.dataset.agentInboxId = item.eventId;
          b.onclick = event => { event.stopPropagation(); openAgentInboxItem(b.dataset.agentInboxId); };
          patchInboxItem(b, item);
          return b;
        },
        patch: patchInboxItem,
      });
```
그리고 같은 스코프에 `patchInboxItem` 추가(텍스트/클래스만 갱신 — 노드 재사용):
```javascript
    function patchInboxItem(b, item) {
      const meta = AGENT_STATUS_META[item.status] || AGENT_STATUS_META.idle;
      const read = agentInboxRead.has(item.eventId);
      b.className = `agent-inbox-item${read ? ' read' : ' unread'}`;
      b.innerHTML = `<span class="wt-dot ${meta.dot}" aria-hidden="true"></span>
        <span class="agent-src ${item.source === 'codex' ? 'codex' : 'claude'}">${item.source === 'codex' ? 'CX' : 'CC'}</span>
        <span class="agent-inbox-copy"><b>${escapeHtml(item.title || item.sid)}</b><small>${escapeHtml(meta.label)} · ${escapeHtml(relTime(item.statusTs || item.ts))}</small></span>`;
    }
```
빈 목록 처리: `entries.length===0` 이면 `panel.innerHTML='<div class="agent-inbox-empty">확인할 에이전트 작업이 없습니다.</div>'` 로 두고 return(빈 상태는 reconcile 대상 아님). 닫힘이면 기존대로 `panel.hidden=true; return`.

> 그룹 헤더(프로젝트 라벨)는 이번 이주에서 **제거**(YAGNI — 항목에 프로젝트가 이미 표시됨). 스펙에 그룹 유지가 필요하면 별도 항목.

- [ ] **Step 3: 문법 확인**

Run: `node --check plugin/scripts/marina-web/app-1-core.js`
Expected: OK.

- [ ] **Step 4: 기존 인박스 테스트 회귀 확인**

Run: `bash plugin/tests/test-agent-inbox.sh`
Expected: PASS (AGENT_STATUS_META·status 사용 검증은 그대로 통과해야 함).

- [ ] **Step 5: 커밋**

```bash
git add plugin/scripts/marina-web/app-1-core.js
git commit -m "refactor(web): agent inbox via reconcile, drop lastInboxSig/capture-restore

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: 세션 카드 리스트 이주 + defer 가드/병렬패처 흡수

최고가치 사이트. `render()` 의 카드 리스트를 root-key reconcile 로, `updateServiceStates` 의 부분패치를 `patch` 로 흡수, `panelEditing`/`renderDeferred`/focusout 을 삭제(노드 재사용으로 포커스가 살아 defer 불필요).

**Files:**
- Modify: `plugin/scripts/marina-web/app-5-sessions.js` (render ~298-503, updateServiceStates ~223, defer 302-316)

**Interfaces:**
- Consumes: `reconcile` (Task 1).
- Produces: `patchCard(cardEl, session)` — 한 카드의 상태의존 부분(dot/label/서비스 상태/AGENTS/why/배지)만 갱신. 신규 카드는 `createCard(session)`.

- [ ] **Step 1: 현재 render/updateServiceStates 경계 읽기**

Run: `sed -n '298,340p;420,510p' plugin/scripts/marina-web/app-5-sessions.js`
확인: `frag`+`replaceChildren`(원자교체), `card.innerHTML=`(카드 통째), `updateServiceStates`(부분패치 별도 경로), defer 상단(302-316).

- [ ] **Step 2: createCard/patchCard 분리**

`render()` 안에서 카드 1개를 만드는 로직을 `createCard(session, ctx)` 로 추출(현재 `card.innerHTML=...` + 이벤트 바인딩). 상태의존 갱신(현 `updateServiceStates` 가 하던 dot/label/서비스행/AGENTS/why/배지 텍스트·클래스)을 `patchCard(card, session, ctx)` 로 추출. `createCard` 는 뼈대 생성 후 `patchCard` 를 호출해 초기 상태 채움.

> 핵심 규율: `patchCard` 는 **포커스된 `[data-alias]` input 의 `.value` 를 덮어쓰지 않는다**(편집 중 보존). alias display/input 토글 노드는 재사용.

- [ ] **Step 3: render() 를 reconcile 로 교체**

`render()` 의 카드 루프+`replaceChildren` 를 아래로:
```javascript
      reconcile(sessionsEl, visibleScoped, {
        key: s => s.root,
        create: s => createCard(s, ctx),
        patch: (el, s) => patchCard(el, s, ctx),
      });
```
그룹 라벨(소스 구분 `src-group-label`)은 항목 사이 형제라, key 를 `grp:claude`/`grp:codex` 로 부여한 라벨 pseudo-item 을 `visibleScoped` 에 인터리브해 같은 reconcile 로 처리(별도 컨테이너 조작 금지).

- [ ] **Step 4: defer 가드 + 병렬 패처 삭제**

- `let renderDeferred`, `panelEditing()`, `document.addEventListener('focusout', ...)`(302-316) **삭제**.
- `render()` 상단 `if (panelEditing()) {...return;}` **삭제**.
- `updateServiceStates` 호출부를 없애고(폴 passive 경로 `app-6-modals.js:281`), 대신 passive 폴도 `render()` 를 호출하되 reconcile 이 변경분만 patch 하므로 값싸다. (또는 `updateServiceStates` 를 `patchCard` 반복 호출하는 얇은 래퍼로 유지 — 둘 중 회귀 적은 쪽. 우선 후자: `updateServiceStates` 내부를 `document.querySelectorAll('#sessions > [data-rkey]')` 순회 → 각 root 로 session 찾아 `patchCard` 로 재작성.)

- [ ] **Step 5: 문법 + 기존 테스트 회귀**

```bash
node --check plugin/scripts/marina-web/app-5-sessions.js
bash plugin/tests/test-agents-section.sh
```
Expected: 문법 OK, test-agents-section PASS.

- [ ] **Step 6: 커밋**

```bash
git add plugin/scripts/marina-web/app-5-sessions.js
git commit -m "refactor(web): session cards via reconcile; fold updateServiceStates into patchCard; drop render defer-guard

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Aside 실브라우저 보존 e2e

reconcile 이 실제 브라우저에서 포커스·값·스크롤·열린 드롭다운을 보존하는지 3910 실데이터로 검증.

**Files:**
- Create: `plugin/tests/test-reconcile-e2e.sh` (Aside 스크립트 — CI 아님, 로컬 수동/문서용)

- [ ] **Step 1: 3910 기동(asdf 코드, 실데이터, auth off)**

```bash
SCRATCH="$(mktemp -d)"
MARINA_CONTROL_PORT=3910 MARINA_CONTROL_HOST=127.0.0.1 MARINA_HOME=/Users/sumin/.marina \
  MARINA_AUTH_DB="$SCRATCH/auth.db" nohup python3 plugin/scripts/marina-control.py >"$SCRATCH/ctrl.log" 2>&1 &
sleep 3; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3910/
```
Expected: `200`.

- [ ] **Step 2: Aside 로 보존 단정(한 repl 스크립트)**

`~/.local/bin/aside repl` 로 `openTab('http://127.0.0.1:3910/')` 후 p.evaluate 로:
- 카드 alias input 포커스+값 → `render()` → `activeElement===input && value 유지` 단정.
- 인박스 열고 스크롤 12 → `render()` → 첫 노드 identity 유지 + scrollTop 유지.
- (터미널/스위처는 Task 5+ 이주 후 추가.)
Expected 출력: 모두 true.

- [ ] **Step 3: 3910 종료 + 커밋(문서)**

```bash
pkill -f "MARINA_CONTROL_PORT=3910" || true
git add plugin/tests/test-reconcile-e2e.sh
git commit -m "test(web): Aside e2e — reconcile preserves focus/value/scroll

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## 후속(별도 Plan)

- **Task 5+ (이 Plan 연장 or Plan 1b):** 터미널 select/side, 프로젝트 스위처, ⋯액션메뉴를 reconcile 로 이주하고 `termSideSig`/`termNewWtSig`/`termRenderDeferred` 삭제.
- **Plan 2 (liveness):** 단일 `resolve_session_liveness` resolver + PTY 레지스트리 영속화/재구성 + 모바일 큐 reconcile(tid/id 기반).
- **Plan 3 (모바일):** 모바일 세션리스트/타임라인 reconcile 이주 + 에이전트 질문 로버스트 surface(캡처 하드닝·리스트 마커·텍스트 폴백).

## Self-Review

- **Spec coverage:** 뿌리1의 reconciler+핵심사이트(인박스·세션카드)와 e2e 검증 커버. 터미널/스위처/모바일/liveness/질문은 후속 Plan 으로 명시 분리(스코프 체크 준수).
- **Placeholder scan:** Task 3 Step 4 에 "둘 중 회귀 적은 쪽" 판단 여지가 있으나 **우선안(후자: updateServiceStates=patchCard 래퍼)을 명시**해 실행 가능. 나머지 스텝은 구체 코드/명령 포함.
- **Type consistency:** `reconcile(container, items, {key, create, patch})` 시그니처가 Task 1/2/3 에서 동일. `patchCard`/`createCard`/`patchInboxItem` 이름 일관.
