# 대시보드 worktree 콘솔 UI 구현 플랜

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 대시보드를 Orca 문법 카드(무테두리·상태점·hover 토글 액션) + 우측 워크스페이스 탭(로그|깃|터미널자리)으로 재설계한다 — 스펙 `docs/superpowers/specs/2026-07-10-dashboard-worktree-console-design.md` (D1~D7).

**Architecture:** ① 백엔드가 서비스별 정규화 `state`(+reason)를 내려주고(파생 로직을 `pillState()` 추측에서 제거), ② 프론트 카드는 state 기반으로 전면 재작성(전체 `render()`와 부분 패치 `updateServiceStates()` 두 경로 모두), ③ 우측은 탭 셸이 되어 기존 로그 뷰어를 첫 탭으로 감싸고, ④ 기구현 깃 그래프 브랜치(`claude/upbeat-shtern-c27104`, main과 충돌 0)를 merge 후 "깃" 탭으로 이식한다.

**Tech Stack:** 순수 JS(모듈 없음, 전역 공유, 템플릿 문자열+innerHTML — 기존 관례 유지), python3 stdlib 백엔드, plugin/tests/*.sh 테스트, 검증은 marina-preview(:3901)+Aside.

**작업 브랜치:** `claude/worktree-console-ui` (이 worktree). push 는 형 검토 후.

**핵심 참조 (탐색으로 확정된 사실):**
- 세션 payload: `GET /api/sessions` → `session_payload()` [marina_sessions.py:129-158], 서비스 dict 는 `build_compose_services()` [marina_compose_svc.py:131-165] + `_compose_services()` 오버레이 [412-447] + busy 머지 [marina_sessions.py:133-145]. 현재 서비스 필드: `service, port, running, health(ok|starting|bad|None), external, degraded, subrepo, profile, log, logRuns, busy?, busyError?`.
- 프론트 상태 파생 소비처는 정확히 4곳: `pillState()` [app-5:89], `serviceActHidden()` [app-5:83], `updateServiceStates()` [app-5:98], `serviceChip()` [app-5:7].
- 선택 계약: `selectLog(root, service, run, mode)` [app-4:313] + 전역 `selected` + `renderSelection()` [app-4:528].
- 깃 그래프: 브랜치 커밋 6개(d3fa571·cac7bd3·0756719·b732fc8 등), 신규 `marina_git.py`·`app-8-git.js`·`test-git-graph.sh`, main 과 파일 겹침 없음 → 그대로 merge 가능. 진입은 현재 헤더 ⎇ 버튼 + 전체화면 모달.

---

### Task 1: 백엔드 — 서비스 state 정규화 (`state` + `stateReason` + `targetPort`)

**Files:**
- Modify: `plugin/scripts/marina_compose_svc.py` (`_compose_services` — degradedReason·targetPort), `plugin/scripts/marina_sessions.py` (`session_payload` — state 판정)
- Test: `plugin/tests/test-svc-state.sh` (신규)

- [ ] **Step 1: 실패하는 테스트 작성** — `plugin/tests/test-svc-state.sh`

```bash
#!/usr/bin/env bash
# 서비스 정규화 state: busyError>busy>degraded>external>health(bad|starting)>running>stopped + reason/targetPort
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 - "$HERE/../scripts" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
import marina_sessions as ms

def st(sv): return ms.svc_state(sv)
assert st({"running":True,"health":"ok"}) == ("running", None)
assert st({"running":True,"health":"starting"}) == ("starting", None)
assert st({"running":True,"health":"bad"}) == ("error", "unhealthy")
assert st({"running":False}) == ("stopped", None)
assert st({"running":True,"health":"ok","external":True}) == ("external", None)
assert st({"running":False,"degraded":True,"degradedReason":"web/Dockerfile 없음"}) == ("degraded", "web/Dockerfile 없음")
assert st({"running":False,"busy":"start"}) == ("starting", None)
assert st({"running":True,"busy":"restart"}) == ("starting", None)
assert st({"running":False,"busyError":"start timed out (1800s)"}) == ("error", "start timed out (1800s)")
# busyError 가 busy·degraded 보다 우선, external 이 health 보다 우선
assert st({"running":True,"health":"bad","external":True})[0] == "external"
print("ok svc_state")
PY
echo "PASS test-svc-state"
```

- [ ] **Step 2: 실패 확인**

Run: `chmod +x plugin/tests/test-svc-state.sh && bash plugin/tests/test-svc-state.sh`
Expected: FAIL — `AttributeError: module 'marina_sessions' has no attribute 'svc_state'`

- [ ] **Step 3: `svc_state()` 구현** — `marina_sessions.py` 의 `session_payload` 위에 추가

```python
def svc_state(s: dict):
    """서비스 dict → (state, reason). state ∈ running|starting|error|stopped|external|degraded.
    UI 가 busy/health/external/degraded 불리언 조합을 추측하지 않게 백엔드가 한 곳에서 판정한다(스펙 D5·상태모델).
    우선순위: busyError > busy > degraded > external > health(bad→error, starting) > running > stopped."""
    if s.get("busyError"):
        return "error", s["busyError"]
    if s.get("busy"):
        return "starting", None
    if s.get("degraded"):
        return "degraded", s.get("degradedReason") or "Dockerfile 없음"
    if s.get("external"):
        return "external", None
    h = s.get("health")
    if h == "bad":
        return "error", "unhealthy"
    if h == "starting":
        return "starting", None
    return ("running", None) if s.get("running") else ("stopped", None)
```

그리고 `session_payload()` 의 busy 머지 for 루프 끝(각 서비스 dict 완성 직후)에:

```python
        s["state"], s["stateReason"] = svc_state(s)
```

- [ ] **Step 4: degradedReason·targetPort 를 payload 에 싣기** — `marina_compose_svc.py` `_compose_services()`

현재 (line 430-431 근방):

```python
        s["subrepo"] = submap.get(svc, "")
        s["degraded"] = svc in degraded
```

교체 (degraded dict 는 `{svc: dockerfile_path}` — 이미 경로를 갖고 있고 버리는 중 [line 290]):

```python
        s["subrepo"] = submap.get(svc, "")
        s["degraded"] = svc in degraded
        if svc in degraded:                                   # 원인 경로를 UI 까지 — 스펙 '조용한 무시 금지'
            s["degradedReason"] = f"{degraded[svc]} 없음"
        tgt = (port_map.get(svc) or {}).get("tgt") or []      # 컨테이너 내부 포트 — 스펙 D6 '내부→호스트' 표기용
        if tgt:
            s["targetPort"] = str(min(tgt))
```

(`port_map` 은 `_compose_config_maps` 반환값으로 이 함수 안에서 이미 사용 중 — liveness 코드 [436-443] 참고. 변수명이 다르면 그 이름을 따른다.)

- [ ] **Step 5: 테스트 통과 + 기존 회귀**

Run: `bash plugin/tests/test-svc-state.sh && bash plugin/tests/test-compose-dash-services.sh && bash plugin/tests/test-compose-port-liveness.sh && bash plugin/tests/test-lifecycle-busy.sh`
Expected: 전부 PASS (`test-compose-dash-services.sh` 의 키 존재 assert [line 29-30] 에 `state` 추가가 필요하면 그 파일도 갱신)

- [ ] **Step 6: Commit**

```bash
git add plugin/scripts/marina_sessions.py plugin/scripts/marina_compose_svc.py plugin/tests/test-svc-state.sh plugin/tests/test-compose-dash-services.sh
git commit -m "feat(dash): 서비스 state 정규화 — state/stateReason/targetPort 를 payload 로 (UI 추측 제거)"
```

---

### Task 2: CSS — 상태 팔레트 토큰 + Orca 카드 스타일

**Files:**
- Modify: `plugin/scripts/marina-web/styles.css`

- [ ] **Step 1: 상태 토큰 추가** — `:root` 블록(l.1-17)에 추가, `:root.dark`(l.445-460)에 다크 값

```css
:root {
  /* ── 상태 팔레트 (스펙 D5) — 실행/기동중/에러/정지/외부 ── */
  --st-run: #1f9d6b; --st-boot: #c07f14; --st-err: #d13438; --st-stop: #8a8f98; --st-ext: #1793a3;
  --st-err-bg: rgba(209,52,56,.08);
}
:root.dark {
  --st-run: #34c98e; --st-boot: #f0a132; --st-err: #e5484d; --st-stop: #5a5f6a; --st-ext: #38b6c4;
  --st-err-bg: rgba(229,72,77,.10);
}
```

- [ ] **Step 2: 카드 스타일 재작성** — 세션 카드 블록(l.246-365)의 `.session` 계열을 다음 원칙으로 교체 (무테두리·hover 승격·hover 액션). 기존 클래스명은 유지하되 시각만 교체하고, 새 클래스를 추가:

```css
/* ── Orca 문법 카드 (스펙 D3·D7) — 무테두리·간격 구분·hover/선택 승격 ── */
.session { border: none; background: transparent; border-radius: 10px; padding: 9px 11px; }
.session:hover { background: var(--sys-bg-surface-hover); }
.session.selected-card, .session.expanded-sel { background: var(--sys-bg-surface); }
.wt-dot { width: 8px; height: 8px; border-radius: 50%; flex: none; }
.wt-dot.run { background: var(--st-run); } .wt-dot.boot { background: var(--st-boot); }
.wt-dot.bad { background: var(--st-err); } .wt-dot.stop { background: var(--st-stop); }
.wt-dot.ext { background: var(--st-ext); }
.sect-label { font-size: 10px; letter-spacing: .08em; color: var(--sys-cont-neutral-light); font-weight: 600; cursor: pointer; }
.sect-counts { margin-left: 6px; font-weight: 600; }
.sect-counts .c-run { color: var(--st-run); } .sect-counts .c-boot { color: var(--st-boot); }
.sect-counts .c-err { color: var(--st-err); } .sect-counts .c-stop { color: var(--st-stop); }
.sect-counts .c-ext { color: var(--st-ext); }
.svc-why { margin-top: 6px; font-size: 11.5px; color: var(--st-err); background: var(--st-err-bg); border-radius: 6px; padding: 4px 8px; }
.svc-why a { color: var(--sys-cont-primary-default); text-decoration: none; }
.card-url { margin-top: 5px; font-size: 11.5px; }
.mono-port { font-family: ui-monospace, Menlo, monospace; font-size: 11px; color: var(--sys-cont-neutral-light); }
/* hover 액션 클러스터 — 카드 우상단·서비스 행 우측. 선택 카드는 상시(D7 발견성) */
.hov-acts { display: none; gap: 2px; align-items: center; background: var(--sys-bg-surface-hover); border-radius: 7px; padding: 1px 4px; }
.session:hover > .session-head .hov-acts, .session.selected-card > .session-head .hov-acts { display: inline-flex; }
.svc:hover .hov-acts, .svc.selected .hov-acts { display: inline-flex; }
.hov-acts button { border: none; background: transparent; padding: 1px 6px; border-radius: 5px; cursor: pointer; }
.hov-acts button:hover { background: var(--sys-cont-neutral-lightest); }
```

- [ ] **Step 3: `.stop` 계열의 빨간 톤 제거** — 기존 `.pill.stop`/`.svc-chip .dot.stop` 이 red-tint 인 것을 `--st-stop`(회색) 기반으로 교체 (스펙 D5: stopped=회색은 의미 변경임을 주석으로 명시).

- [ ] **Step 4: 검증 + Commit**

Run: `grep -c "st-run" plugin/scripts/marina-web/styles.css` → 2 이상 (라이트+다크). 시각 확인은 Task 6 에서 일괄.

```bash
git add plugin/scripts/marina-web/styles.css
git commit -m "feat(dash): 상태 팔레트 토큰(D5) + Orca 카드 스타일(무테두리·hover 액션) — 라이트/다크"
```

---

### Task 3: 카드 재작성 — state 기반 렌더 + 토글 액션 + 카운트 접힘

**Files:**
- Modify: `plugin/scripts/marina-web/app-5-sessions.js` (pillState/serviceActHidden 교체, render 카드부·makeSvcRow·serviceChip·updateServiceStates)
- Test: `plugin/tests/test-dash-state-ui.sh` (신규 — node 없이 grep 스모크) + 기존 test-compose-dash-*.sh 회귀

- [ ] **Step 1: 상태 메타·판정 헬퍼 교체** — `HEALTH_PILLS`/`pillState()`/`serviceActHidden()`(app-5:76-96) 를 다음으로 교체

```js
// 스펙 D5 — 백엔드 정규화 state 소비. 구버전 payload(state 없음) 폴백 포함.
const STATE_META = {
  running:  { dot:'run',  pill:'실행',   icon:'▶' },
  starting: { dot:'boot', pill:'기동중', icon:'⟳' },
  error:    { dot:'bad',  pill:'오류',   icon:'✕' },
  stopped:  { dot:'stop', pill:'꺼짐',   icon:'■' },
  external: { dot:'ext',  pill:'외부',   icon:'⇄' },
  degraded: { dot:'boot', pill:'비활성', icon:'⚠' },
};
function svcState(svc) {
  if (svc.state) return svc.state;
  if (svc.busyError) return 'error';
  if (svc.busy) return 'starting';
  if (svc.degraded) return 'degraded';
  if (svc.external) return 'external';
  if (svc.health === 'bad') return 'error';
  if (svc.health === 'starting') return 'starting';
  return svc.running ? 'running' : 'stopped';
}
function cardState(services) {           // worktree 종합 점 (스펙 D5)
  const st = services.map(svcState);
  if (st.includes('error')) return 'error';
  if (st.includes('starting')) return 'starting';
  const run = st.filter(s => s === 'running' || s === 'external').length;
  if (run === 0) return 'stopped';
  return run === st.length ? 'running' : 'starting';   // 일부 실행 = 주황
}
function stateCounts(services) {         // 접힘 요약 (스펙 D4) — 0 은 생략
  const c = {};
  for (const s of services.map(svcState)) c[s] = (c[s] || 0) + 1;
  const order = [['running','c-run','▶'],['starting','c-boot','⟳'],['error','c-err','✕'],['external','c-ext','⇄'],['stopped','c-stop','■'],['degraded','c-boot','⚠']];
  return order.filter(([k]) => c[k]).map(([k, cls, ic]) => `<span class="${cls}">${ic} ${c[k]}</span>`).join(' · ');
}
// 스펙 D7 — 토글 1개(▶/⏹) + ↻ 는 실행중만. 반환: [{act, icon, title}]
function svcActions(svc) {
  const st = svcState(svc);
  if (st === 'starting') return [{ act:'stop', icon:'⟳', title:'기동 중 — 클릭하면 정지(취소)' }];
  if (st === 'external') return [{ act:'stop-external', icon:'⏹', title:'외부 프로세스 정지 (SIGTERM)' }];
  if (st === 'running')  return [{ act:'stop', icon:'⏹', title:'정지' }, { act:'restart', icon:'↻', title:'재시작' }];
  if (st === 'degraded') return [];
  return [{ act:'start', icon:'▶', title: st === 'error' ? '재시도(시작)' : '시작' }];   // stopped·error
}
function cardActions(services) {
  const anyLive = services.some(s => ['running','starting','external'].includes(svcState(s)));
  return anyLive ? [{ act:'stop-all', icon:'⏹', title:'전체 정지' }, { act:'restart-all', icon:'↻', title:'전체 재시작' }]
                 : [{ act:'start-all', icon:'▶', title:'전체 시작' }];
}
```

(주의: `restart-all` 엔드포인트는 없음 — `sessionAction('restart-all')` 대신 기존 `/api/start-all` 이 재기동 포함인지 확인하고, 없으면 카드 ↻ 는 `stop-all 후 start-all` 순차 호출로 구현하거나 이번엔 카드 ↻ 를 뺀다. **결정: 카드 레벨은 토글(⏹/▶)만, ↻ 는 서비스 행에만** — 스펙 D7 의 "카드 토글 의미 단순 유지" 원칙과 일치하게 `cardActions` 에서 restart-all 항목을 제거한 형태로 구현한다.)

```js
function cardActions(services) {
  const anyLive = services.some(s => ['running','starting','external'].includes(svcState(s)));
  return anyLive ? [{ act:'stop-all', icon:'⏹', title:'전체 정지' }]
                 : [{ act:'start-all', icon:'▶', title:'전체 시작' }];
}
```

- [ ] **Step 2: 카드 헤더/섹션 재작성** — `render()` 의 카드 innerHTML 템플릿(app-5:220-248) 을 스펙 D3 구조로 교체. 우측 메타·URL 헬퍼부터 정의:

```js
function attachSummary(session, wt) {    // attach n/m (worktree 카드만 — main 은 생략)
  if (!wt || wt.isMain || !(wt.subrepos || []).length) return '';
  return `attach ${(wt.attachedSubrepos || []).length}/${wt.subrepos.length} · `;
}
function metaTime(wt) {                  // 우측 정렬 시간 메타 — idleDays 기반 (Orca 의 '49m/3h' 슬롯)
  if (!wt || wt.idleDays == null) return '';
  return wt.idleDays < 1 ? '오늘' : `${wt.idleDays}d`;
}
function gatewayLine(session) {          // 카드 하단 대표 URL (D3 고정 슬롯) — primary(web) 우선
  const svcs = visibleServices(session);
  const prim = svcs.find(s => /^(web|fe|front)/.test(s.service)) || svcs[0];
  const url = prim && gatewayUrlFor(session, prim);   // app-3-util.js:85
  return url ? `<a href="${url}" target="_blank" rel="noopener">${escapeHtml(url.replace(/^https?:\/\//, ''))} ↗</a>` : '';
}
```

카드 골자:

```js
const services = visibleServices(session);
const cst = cardState(services);
const secOpen = expandedRoots.has(session.root);
card.innerHTML = `
  <div class="session-head">
    <span class="wt-dot ${STATE_META[cst].dot}"></span>
    <span class="wt-name" data-alias-display>${escapeHtml(title)}</span>
    <span class="wt-right">${attachSummary(session, wt)}${metaTime(wt)}</span>
    <span class="hov-acts" data-card-acts></span>
  </div>
  ${branchRow}
  <div class="sect-label" data-sect-toggle>${secOpen ? '▾' : '▸'} SERVICES (${services.length})
    <span class="sect-counts">${secOpen ? '' : stateCounts(services)}</span></div>
  <div class="svc-list" ${secOpen ? '' : 'hidden'}></div>
  <div class="svc-why-slot"></div>
  <div class="card-url">${gatewayLine(session)}</div>
  <div class="root root-meta">…(기존 경로·디스크 라인 유지)…</div>`;
```

- 기존 `.session-tools`(✎·♻·✕ 상시 버튼)와 `.session-actions`(▶ 전체시작/■ 전체정지 상시 스트립)는 **제거** — ✎/♻/✕ 는 카드 `⋯` 메뉴로, 전체 토글은 `[data-card-acts]` hover 클러스터로.
- `[data-card-acts]` 채우기: `cardActions(services)` + `⋯` 메뉴 버튼. `withBusy` 래핑은 기존 `sessionAction` 재사용.
- `⋯` 메뉴: 간단한 팝오버(기존 switcher-menu 패턴 재사용) — 항목: ✎ compose 편집(`openComposeEdit`) · 캐시 정리 · 링크(`renderLinksRows` 대체) · 워크트리 제거(main 제외) · 프로젝트 설정.
- **에러/degraded 원인 줄**: 카드당 `svc-why-slot` 에 state 가 error|degraded 인 서비스마다 1줄:

```js
function whyLine(session, svc) {
  const st = svcState(svc);
  if (st !== 'error' && st !== 'degraded') return '';
  const reason = escapeHtml(svc.stateReason || (st === 'error' ? '실패' : '비활성'));
  const acts = st === 'error'
    ? `<a data-why-logs="${svc.service}">로그</a> · <a data-why-retry="${svc.service}">재시도</a>`
    : `<a data-why-compose="${svc.service}">compose 열기</a>`;
  return `<div class="svc-why">${escapeHtml(svc.service)}: ${reason} → ${acts}</div>`;
}
```

핸들러: `data-why-logs`→`selectLog(root, svc, 'current', 'service')`, `data-why-retry`→`action('start', root, svc)`, `data-why-compose`→`openServiceConfig(root, svc)`.

- [ ] **Step 3: 서비스 행 재작성** — `makeSvcRow()`(app-5:606-677) 를 D3·D6·D7 로:

```js
function portText(svc) {                 // 스펙 D6 — 내부→호스트, 상태별 대체 텍스트
  const st = svcState(svc);
  if (st === 'starting') return svc.busy ? (svc.busy === 'restart' ? 'restarting…' : 'starting…') : 'starting…';
  if (st === 'error') return svc.stateReason && /timed out/.test(svc.stateReason) ? 'timeout' : 'exit ≠0';
  if (!svc.port) return '';
  return svc.targetPort ? `${svc.targetPort}→${svc.port}` : `:${svc.port}`;
}
```

행 구조: `상태점(.wt-dot) · 이름 · (우측) .mono-port[data-port] · .hov-acts`(svcActions + 로그 + ⋯).
- 포트 텍스트 클릭 = 복사(`navigator.clipboard.writeText`), hover title = `컨테이너 ${targetPort} → 호스트 ${port} (자동할당·재시작마다 변동)`.
- `⋯` 메뉴: 게이트웨이로 열기(`gatewayUrlFor` — 기존 app-3:85) · 호스트포트로 열기(`http://127.0.0.1:${port}`) · 주소 복사 · ⓘ 서비스 설정(`openServiceConfig`).
- `로그` 버튼 = `selectLog(root, service)` (행 자체 클릭도 기존대로 selectLog — 유지).
- external 행: `⏹` 하나 = 기존 stop-external confirm 흐름(app-5:638) 재사용.
- 기존 3버튼 루프(l.628)와 `serviceActHidden` 은 삭제 — `svcActions()` 로 대체.
- 게이트웨이 sub-row(l.661-675)는 제거하고 ⋯ 메뉴로 흡수(카드 하단 대표 URL 이 D3 슬롯).

- [ ] **Step 4: 요약 칩·부분 패치 갱신** — `serviceChip()`(접힘 시 칩 row)는 **삭제**(D4 카운트가 대체, `renderServiceChips`/`trimChipRow` 포함). `updateServiceStates()`(app-5:98-137) 를 새 DOM 키에 맞게 재작성:

```js
function updateServiceStates() {
  const byRoot = new Map(sessions.map(s => [s.root, s]));
  document.querySelectorAll('.session[data-root]').forEach(card => {
    const session = byRoot.get(card.dataset.root); if (!session) return;
    const services = visibleServices(session);
    const cst = cardState(services);
    const dot = card.querySelector('.session-head .wt-dot');
    if (dot) dot.className = `wt-dot ${STATE_META[cst].dot}`;
    const counts = card.querySelector('.sect-counts');
    if (counts && card.querySelector('.svc-list[hidden]')) counts.innerHTML = stateCounts(services);
    for (const svc of services) {
      const row = card.querySelector(`[data-service-key="${CSS.escape(session.root + '::' + svc.service)}"]`);
      if (!row) continue;
      const rdot = row.querySelector('.wt-dot');
      if (rdot) rdot.className = `wt-dot ${STATE_META[svcState(svc)].dot}`;
      const port = row.querySelector('[data-port]');
      if (port) port.textContent = portText(svc);
      const acts = row.querySelector('[data-svc-acts]');
      if (acts && !acts.querySelector('button:disabled')) fillSvcActs(acts, session, svc);
    }
    const cacts = card.querySelector('[data-card-acts]');
    if (cacts && !cacts.querySelector('button:disabled')) fillCardActs(cacts, session, services);
  });
  renderSelection();
}
```

(`fillSvcActs`/`fillCardActs` = Step 2·3 의 클러스터 채움 로직을 함수로 분리해 render/patch 양쪽에서 사용.)

- [ ] **Step 5: 스모크 테스트** — `plugin/tests/test-dash-state-ui.sh` (구조 불변식 grep — JS 실행 없이 회귀 최소선)

```bash
#!/usr/bin/env bash
# 카드 재설계 구조 불변식: state 기반 헬퍼 존재·구 파생 제거·토글 문법
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
J="$HERE/../scripts/marina-web/app-5-sessions.js"
grep -q "function svcState" "$J" || { echo "FAIL: svcState 없음"; exit 1; }
grep -q "function cardState" "$J" || { echo "FAIL: cardState 없음"; exit 1; }
grep -q "function stateCounts" "$J" || { echo "FAIL: stateCounts 없음"; exit 1; }
grep -q "function svcActions" "$J" || { echo "FAIL: svcActions 없음"; exit 1; }
! grep -q "HEALTH_PILLS" "$J" || { echo "FAIL: 구 HEALTH_PILLS 잔존"; exit 1; }
! grep -q "serviceActHidden" "$J" || { echo "FAIL: 구 serviceActHidden 잔존"; exit 1; }
! grep -q "data-start-all.*전체 시작" "$J" || { echo "FAIL: 상시 전체시작 스트립 잔존"; exit 1; }
grep -q "targetPort" "$J" || { echo "FAIL: D6 내부→호스트 표기 없음"; exit 1; }
echo "PASS test-dash-state-ui"
```

- [ ] **Step 6: 회귀 + Commit**

Run: `chmod +x plugin/tests/test-dash-state-ui.sh && bash plugin/tests/test-dash-state-ui.sh && bash plugin/tests/test-compose-dash-services.sh && bash plugin/tests/test-links-tabs-ui.sh`
Expected: PASS (links UI 테스트가 제거된 `renderLinksRows` 진입을 검증하면 ⋯ 메뉴 경로로 테스트를 갱신)

```bash
git add plugin/scripts/marina-web/app-5-sessions.js plugin/tests/test-dash-state-ui.sh
git commit -m "feat(dash): Orca 문법 카드 — state 기반 렌더·카운트 접힘(D4)·토글+hover 액션(D7)·내부→호스트 포트(D6)"
```

---

### Task 4: 워크스페이스 탭 셸 — 로그를 첫 탭으로

**Files:**
- Modify: `plugin/scripts/marina-web/index.html` (section 구조), `plugin/scripts/marina-web/app-4-logs.js` (탭 등록), `plugin/scripts/marina-web/app-6-modals.js` (탭 클릭 와이어), `plugin/scripts/marina-web/styles.css` (.ws-tabs)
- Test: `plugin/tests/test-dash-workspace-tabs.sh` (신규)

- [ ] **Step 1: index.html 재구조화** — `<section>` 안을 탭 셸로 감싼다. **로그 관련 DOM id 는 전부 유지**(엔진 무수정 원칙) — `#tab-logs` 서브트리로 이동만:

```html
<section>
  <div class="ws-tabs" id="wsTabs">
    <button data-ws-tab="logs" class="on">로그</button>
    <button data-ws-tab="git">깃</button>
    <button data-ws-tab="term" disabled title="추후 — 터미널">터미널</button>
    <span class="ws-ctx" id="wsCtx"></span>
  </div>
  <div class="ws-pane" id="tab-logs">
    <!-- 기존 .log-head / #olderBar / #log 전체를 그대로 이 안으로 이동 -->
  </div>
  <div class="ws-pane" id="tab-git" hidden></div>
  <div class="ws-pane" id="tab-term" hidden></div>
</section>
```

- [ ] **Step 2: 탭 전환 + view registry** — `app-6-modals.js` 에 (로그 툴바 와이어링 411-505 근처):

```js
// 스펙 D2 — 워크스페이스 뷰 탭. 새 뷰 = WS_VIEWS 등록 + pane div 하나.
const WS_VIEWS = { logs: {}, git: {}, term: {} };   // {activate(pane, ctx)?, deactivate()?}
let wsActive = 'logs';
function wsContext() { return selected ? { root: selected.root, service: selected.service } : null; }
function setWsTab(name) {
  if (!WS_VIEWS[name] || name === wsActive) return;
  const prev = WS_VIEWS[wsActive];
  if (prev.deactivate) prev.deactivate();
  wsActive = name;
  document.querySelectorAll('[data-ws-tab]').forEach(b => b.classList.toggle('on', b.dataset.wsTab === name));
  document.querySelectorAll('.ws-pane').forEach(p => { p.hidden = p.id !== 'tab-' + name; });
  const v = WS_VIEWS[name];
  if (v.activate) v.activate(document.getElementById('tab-' + name), wsContext());
  updateWsCtx();
}
function updateWsCtx() {
  const el = document.getElementById('wsCtx');
  if (el) el.textContent = selected ? `${shortPath(selected.root)} · ${selected.service}` : '';
}
document.querySelectorAll('[data-ws-tab]').forEach(b => { if (!b.disabled) b.onclick = () => setWsTab(b.dataset.wsTab); });
```

- 로그 뷰 등록: `WS_VIEWS.logs = { deactivate(){ /* SSE 는 유지 — 탭 숨김만 */ } }` (엔진 그대로, pane 토글만).
- `selectLog()`(app-4:313) 끝에 `if (typeof setWsTab === 'function') { setWsTab('logs'); updateWsCtx(); }` 추가 — 카드에서 로그를 고르면 로그 탭으로 복귀(D2 "탭 컨텍스트는 선택 추종").
- 주의: app-4 가 app-6 보다 먼저 로드되므로 `typeof` 가드 필수.

- [ ] **Step 3: CSS** — styles.css 로그 헤드 블록 위에:

```css
.ws-tabs { display: flex; gap: 2px; align-items: flex-end; padding: 6px 10px 0; border-bottom: 1px solid var(--sys-style-neutral-light); }
.ws-tabs button { border: none; background: transparent; padding: 4px 14px; border-radius: 8px 8px 0 0; color: var(--sys-cont-neutral-light); cursor: pointer; }
.ws-tabs button.on { background: var(--sys-bg-surface); color: var(--sys-cont-neutral-default); font-weight: 600; }
.ws-tabs button:disabled { opacity: .4; cursor: default; }
.ws-ctx { margin-left: auto; color: var(--sys-cont-neutral-light); font-size: 11px; padding-bottom: 4px; }
.ws-pane { display: flex; flex-direction: column; flex: 1; min-height: 0; }
```

- [ ] **Step 4: 스모크 테스트** — `plugin/tests/test-dash-workspace-tabs.sh`

```bash
#!/usr/bin/env bash
# 워크스페이스 탭 셸: 탭 3개(터미널 disabled)·로그 DOM id 보존·setWsTab 존재
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
H="$HERE/../scripts/marina-web/index.html"
grep -q 'data-ws-tab="logs"' "$H" || { echo "FAIL: 로그 탭 없음"; exit 1; }
grep -q 'data-ws-tab="git"' "$H" || { echo "FAIL: 깃 탭 없음"; exit 1; }
grep -q 'data-ws-tab="term" disabled' "$H" || { echo "FAIL: 터미널 자리 없음"; exit 1; }
for id in log logFilter runSelect logModeTabs olderBar gaugeTrack; do
  grep -q "id=\"$id\"" "$H" || { echo "FAIL: 로그 DOM #$id 소실"; exit 1; }
done
grep -q "function setWsTab" "$HERE/../scripts/marina-web/app-6-modals.js" || { echo "FAIL: setWsTab 없음"; exit 1; }
echo "PASS test-dash-workspace-tabs"
```

- [ ] **Step 5: 회귀 + Commit**

Run: `chmod +x plugin/tests/test-dash-workspace-tabs.sh && bash plugin/tests/test-dash-workspace-tabs.sh && bash plugin/tests/test-compose-dash-logs-e2e.sh`
Expected: PASS (로그 e2e 는 DOM id 불변이라 통과해야 함)

```bash
git add plugin/scripts/marina-web/index.html plugin/scripts/marina-web/app-4-logs.js plugin/scripts/marina-web/app-6-modals.js plugin/scripts/marina-web/styles.css plugin/tests/test-dash-workspace-tabs.sh
git commit -m "feat(dash): 워크스페이스 뷰 탭 셸(D2) — 로그를 첫 탭으로, 터미널 자리 예약"
```

---

### Task 5: 깃 그래프 브랜치 merge + "깃" 탭 이식

**Files:**
- Merge: `claude/upbeat-shtern-c27104` (marina_git.py·app-8-git.js·test-git-graph.sh 등 — main 과 파일 겹침 없음 확인됨)
- Modify: `plugin/scripts/marina-web/app-8-git.js` (renderGitPanel 분리), `plugin/scripts/marina-web/index.html` (⎇ 버튼 제거), `plugin/scripts/marina-web/styles.css` (.git-panel)

- [ ] **Step 1: merge**

```bash
git merge --no-ff claude/upbeat-shtern-c27104 -m "merge: 깃 그래프 패널 1단계 (worktree 콘솔 깃 탭 재료)"
bash plugin/tests/test-git-graph.sh
```

Expected: 충돌 없이 merge(사전 조사로 파일 겹침 0 확인), 테스트 PASS. 충돌 시 styles.css/index.html append-at-end 훙크만 수동 해소.

- [ ] **Step 2: 모달 → 패널 분리** — `app-8-git.js` 의 `loadGitGraph` 에서 `#gitModalBack` 의존을 파라미터로:

```js
// 탭/모달 공용 진입 — container 에 탭바+바디를 그린다 (스펙 D2 깃 탭)
async function renderGitPanel(container, root) {
  container.innerHTML = '<div class="git-tabs" data-git-tabs></div><div class="git-body git-panel" data-git-body>불러오는 중…</div>';
  await loadGitGraphInto(container, root || gitMainRoot(), gitRepoTab, false);
}
```

`loadGitGraph(root, repo, refresh)` 내부의 `document.querySelector('#gitModalBack ...')` 조회를 전달받은 `container.querySelector('[data-git-tabs]'/'[data-git-body]')` 로 바꾼 `loadGitGraphInto(container, root, repo, refresh)` 로 일반화하고, 기존 모달 경로는 이 함수를 호출하게 유지(또는 모달 자체를 제거 — Step 3).

- [ ] **Step 3: 탭 등록 + 헤더 ⎇ 제거**

```js
// app-8-git.js 하단 — 탭 등록 (탭 셸은 app-6 에서 정의, app-8 이 나중에 로드되므로 직접 대입)
WS_VIEWS.git = {
  activate(pane, ctx) { renderGitPanel(pane, ctx && ctx.root); },
};
```

- index.html 의 `<button id="gitGraph">⎇</button>` 제거 + app-8 상단의 `document.getElementById('gitGraph').onclick = openGitGraph;` 제거(버튼 없으면 throw — 조사 확인됨). `openGitGraph` 전체 모달 경로도 함께 제거(진입점이 탭뿐이면 죽은 코드).
- diff 모달(`openGitDiff`)은 그대로 — 탭 위에 겹치는 모달로 유지. WIP diff 의 root 는 `wsContext().root`(선택 워크트리)를 넘긴다 — main 전용이던 기존보다 개선.
- CSS: `.git-panel { max-height: none; }` 등 모달 크기 제약 해제 변형 추가.

- [ ] **Step 4: 검증 + Commit**

Run: `bash plugin/tests/test-git-graph.sh && bash plugin/tests/test-dash-workspace-tabs.sh && ! grep -q 'id="gitGraph"' plugin/scripts/marina-web/index.html && echo OK`
Expected: PASS + OK

```bash
git add plugin/scripts/marina-web/app-8-git.js plugin/scripts/marina-web/index.html plugin/scripts/marina-web/styles.css
git commit -m "feat(dash): 깃 그래프를 워크스페이스 '깃' 탭으로 — 모달 진입 제거, 선택 워크트리 컨텍스트"
```

---

### Task 6: 안정화 + 실브라우저 검증

**Files:**
- Modify: `plugin/scripts/marina-web/styles.css` (오버플로·반응형), 필요시 app-5

- [ ] **Step 1: 오버플로·고정 높이** — styles.css:

```css
.wt-name { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.svc .svc-name { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.session-head { min-height: 24px; } .svc { min-height: 26px; }
```

좁은 화면 `@media (max-width: 980px)` 블록에 `.ws-tabs button { padding: 4px 8px; }` 추가, aside 접기(기존 `#asideToggle`) 동작 확인.

- [ ] **Step 2: marina-preview 로 실브라우저 검증** (내 규약 — Aside 사용)

1. `marina start marina-preview` 또는 기존 :3901 프리뷰 재시작 → 대시보드가 새 UI 로 뜨는지
2. Aside(`mcp__aside__repl` / `~/.local/bin/aside repl`)로:
   - `snapshot(page, {interactive:true})` — 카드: 무테두리·상태점·SERVICES 카운트 확인
   - 카드 hover → 토글 클러스터 노출, 정지 카드에 `▶` 만·실행 카드에 `⏹ ↻`
   - 접힘/펼침 토글, 카운트 갱신
   - 서비스 행 클릭 → 로그 탭 포커스 + `#wsCtx` 갱신
   - 깃 탭 클릭 → 레인 그래프 렌더, 커밋 행 클릭 → diff 모달
   - 포트 텍스트 `내부→호스트` 표기 + 클릭 복사
   - 다크/라이트 토글, 좁은 창(≈700px) 카드 깨짐 없음
3. 실패 원인 줄: 서비스 하나를 고의로 죽여(`docker stop` 대신 잘못된 env 로 재시작) `✕` + why 줄 + 재시도 링크 확인 — 어려우면 busyError 경로는 payload mock 으로 단위 확인만.

- [ ] **Step 3: 전체 대시보드 테스트 일괄**

```bash
for t in test-svc-state.sh test-dash-state-ui.sh test-dash-workspace-tabs.sh test-git-graph.sh \
         test-compose-dash-services.sh test-compose-dash-api.sh test-compose-dash-logs-e2e.sh \
         test-compose-port-liveness.sh test-lifecycle-busy.sh test-links-tabs-ui.sh; do
  echo "== $t"; bash "plugin/tests/$t" || break
done
```

Expected: 전부 PASS (docker 필요 테스트는 데몬 없으면 SKIP 메시지 확인)

- [ ] **Step 4: 스펙 상태 갱신 + Commit**

스펙 상단 `상태:` → `구현 완료 (형 검토 대기)`.

```bash
git add -A plugin/scripts/marina-web docs/superpowers/specs/2026-07-10-dashboard-worktree-console-design.md
git commit -m "feat(dash): 안정화 — 오버플로·반응형·실브라우저 검증 완료 (worktree 콘솔 1단계)"
```

push 는 하지 않는다 — 형 검토 후 결정.

---

## 리스크·주의

- **render/patch 이중 경로**: 카드 DOM 을 바꾸면 `updateServiceStates()` 의 셀렉터도 반드시 함께 — Task 3 Step 4 가 그 계약. 놓치면 "10초마다 상태가 안 바뀌는" 버그.
- **로그 엔진 무수정 원칙**: Task 4 는 DOM 이동+탭 토글만. `#log` 계열 id 나 app-4 함수 시그니처를 바꾸지 않는다.
- **깃 브랜치 merge**: 사전 조사로 충돌 0 이지만, styles.css append 훙크는 확인.
- **삭제 대상 명시**: `HEALTH_PILLS`·`pillState`·`serviceActHidden`·`serviceChip`·`renderServiceChips`·`trimChipRow`·`.session-actions` 스트립·헤더 ⎇ 버튼 — 죽은 코드로 남기지 않는다.
- `session.kind !== 'compose'` 분기(app-5:212 등)는 compose-only 시스템이므로 이번 재작성에서 만나는 곳만 단순화(전면 정리는 비범위).
