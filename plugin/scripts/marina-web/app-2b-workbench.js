    // ── 등록 워크벤치 (M2 골격 + M3 재료 서랍) ─────────────────────────────────
    // 스펙: docs/superpowers/specs/2026-07-11-register-workbench-design.md R2
    // 위저드를 대체하는 2열 화면: 좌(#wbLeft) = 재료(M3, data-wb-materials)/marina 옵션(M4, 아직 플레이스홀더),
    // 우(#wbRight) = 기존 compose 에디터(#composeSection — DOM 은 index.html 에서 이미 이곳으로 이동해둠,
    // 하이라이트·키핸들러(app-2 의 yamlEditor*)는 그대로 동작). 등록/편집 두 진입점을 openWorkbench 하나로 흡수.
    //
    // mode 는 문자열 제목 비교 대신 모듈 변수(wbMode)로 보관 — app-2 의 composeConfirm 핸들러가 참조한다.
    let wbMode = 'new';   // 'new' | 'edit'
    let wbRoot = '';      // 현재 워크벤치가 다루는 프로젝트 root ('' = 아직 미지정 신규 등록)

    // 신규 등록(mode:'new')·compose 편집(mode:'edit') 공용 진입점.
    // opts: { root, mode }
    function openWorkbench(opts) {
      const o = opts || {};
      const mode = o.mode === 'edit' ? 'edit' : 'new';
      const root = o.root || '';
      wbMode = mode; wbRoot = root;

      switcherOpen = false;
      setRegisterView('new');   // entry/paste/candidates 숨기고 경로행 노출 — composeSection 표시는 아래서 별도 처리
      document.getElementById('registerTitle').textContent = mode === 'edit' ? 'compose 편집' : '프로젝트 등록';

      const pathInput = document.getElementById('registerPath');
      pathInput.value = root;
      pathInput.disabled = mode === 'edit';               // 편집: 경로 고정, 신규: 직접 입력
      document.getElementById('registerBrowse').hidden = mode === 'edit';
      document.getElementById('registerInfer').hidden = true;   // 워크벤치 경로에선 infer 체크리스트 안 씀(subrepos 편집 전용)
      document.getElementById('registerPreview').hidden = true;
      document.getElementById('registerError').hidden = true;
      document.getElementById('browsePanel').hidden = true;
      if (typeof setRegisterKind === 'function') setRegisterKind('compose');   // 워크벤치 = compose-only

      if (mode === 'new') {
        composeStoredEnv = { envVar: '', envDefault: '' };
        setComposeYaml('');
        if (typeof wbFormSyncFromEditor === 'function') wbFormSyncFromEditor();   // M4 훅 — 빈 x-marina 로 폼 초기화(app-2c)
      }

      document.getElementById('composeSection').hidden = false;
      syncRegisterWorkspace();   // .workbench 폭/높이 + #registerWorkbench2b 노출 동기화(app-1)
      showRegisterPanel(true);
      renderSwitcher();
      wbHideDraftBanner();
      if (typeof wbLintReset === 'function') wbLintReset();   // M5 — 이전 세션의 검증/마커 상태를 새 진입에 남기지 않음
      if (typeof wbExplainReset === 'function') wbExplainReset();   // M5 R3 — '해석' 탭에 머물러 있던 상태 초기화(app-2d)
      wbResetMaterials(root);   // 재료 서랍 초기화 — 스캔 결과는 비우고(버튼 눌러야 재스캔), 기존 compose 목록만 가볍게 재조회(M3)

      if (mode === 'edit') {
        setComposeYaml('불러오는 중…');
        wbLoadEditCompose(root);   // 비동기 — 완료 후 초안 비교
      } else {
        wbCheckDraft();
      }
    }

    // 편집 모드 — 보관된 compose 를 불러와 채운다 (구 openComposeEdit 본문 이전).
    async function wbLoadEditCompose(root) {
      const err = document.getElementById('registerError');
      try {
        const r = await api('/api/compose-detect?path=' + enc(root));
        if (r && r.stored) {
          setComposeYaml(r.stored.yaml || '');
          composeStoredEnv = { envVar: r.stored.envVar || '', envDefault: r.stored.envDefault || '' };
        } else {
          setComposeYaml('');
          err.textContent = '보관된 compose 를 찾지 못했습니다'; err.hidden = false;
        }
      } catch (e) {
        setComposeYaml('');
        err.textContent = String(e.message || e); err.hidden = false;
      }
      if (typeof wbFormSyncFromEditor === 'function') wbFormSyncFromEditor();   // M4 훅 — 로드된 compose 로 폼 갱신(app-2c)
      if (typeof wbScheduleLint === 'function') wbScheduleLint();   // M5 — 로드된 실제 내용으로 마커/검증 갱신("불러오는 중…" placeholder 는 무시)
      wbCheckDraft();   // 서버 로드본이 자리 잡은 뒤에 초안과 비교해야 오탐이 없다
    }

    // ── 초안 자동 보관 (localStorage) ───────────────────────────────────────
    // 키: marinaWbDraft:<root|new> — 경로 미확정(신규 등록 초반)이면 'new' 슬롯 하나 공유.
    function wbDraftKey() {
      const p = (document.getElementById('registerPath').value || '').trim();
      return 'marinaWbDraft:' + (p || 'new');
    }
    function wbSaveDraftNow() {
      const ta = document.getElementById('composeYaml');
      const yaml = ta ? ta.value : '';
      if (!yaml || !yaml.trim() || yaml === '불러오는 중…') return;   // 빈 값/로딩 placeholder 는 저장 안 함
      try { localStorage.setItem(wbDraftKey(), JSON.stringify({ yaml, ts: Date.now() })); } catch {}
    }
    let wbDraftTimer = null;
    function wbScheduleDraftSave() {
      clearTimeout(wbDraftTimer);
      wbDraftTimer = setTimeout(wbSaveDraftNow, 500);   // 디바운스 500ms
    }
    function wbClearDraft() {
      clearTimeout(wbDraftTimer);   // 대기 중인 디바운스 저장이 삭제 직후 초안을 되살리는 것 방지(실측 발견)
      try { localStorage.removeItem(wbDraftKey()); } catch {}
    }
    function wbHideDraftBanner() {
      const banner = document.getElementById('wbDraftBanner');
      if (banner) banner.hidden = true;
    }
    function wbShowDraftBanner(draft) {
      const banner = document.getElementById('wbDraftBanner');
      if (!banner) return;
      banner.innerHTML = '';
      const msg = document.createElement('span');
      msg.textContent = '저장 안 된 초안이 있어요';
      banner.appendChild(msg);
      const resume = document.createElement('button');
      resume.type = 'button'; resume.textContent = '이어서 작성';
      resume.onclick = () => {
        setComposeYaml(draft.yaml);
        if (typeof wbFormSyncFromEditor === 'function') wbFormSyncFromEditor();   // M4 훅 — 초안 복원 후 폼 갱신(app-2c)
        if (typeof wbScheduleLint === 'function') wbScheduleLint();   // M5 — 복원된 내용으로 마커/검증 갱신
        wbHideDraftBanner();
      };
      banner.appendChild(resume);
      const discard = document.createElement('button');
      discard.type = 'button'; discard.textContent = '버리기';
      discard.onclick = () => { wbClearDraft(); wbHideDraftBanner(); };
      banner.appendChild(discard);
      banner.hidden = false;
    }
    // 현재 에디터 내용과 저장된 초안을 비교 — 다르면(그리고 초안이 비어있지 않으면) 배너로 알림. alert 금지(인라인).
    function wbCheckDraft() {
      let raw;
      try { raw = localStorage.getItem(wbDraftKey()); } catch { raw = null; }
      if (!raw) { wbHideDraftBanner(); return; }
      let draft;
      try { draft = JSON.parse(raw); } catch { wbHideDraftBanner(); return; }
      if (!draft || typeof draft.yaml !== 'string' || !draft.yaml.trim()) { wbHideDraftBanner(); return; }
      const current = document.getElementById('composeYaml').value;
      if (draft.yaml !== current) wbShowDraftBanner(draft);
      else wbHideDraftBanner();
    }

    // composeYaml 은 이미 app-2 가 하이라이트/탭 키 핸들러를 붙여둠 — 여기선 초안 저장용 리스너만 추가로 얹는다.
    (function wireWorkbenchDraft() {
      const ta = document.getElementById('composeYaml');
      if (!ta) return;
      ta.addEventListener('input', wbScheduleDraftSave);
    })();

    // ── M5: 인라인 검증(/api/compose-validate) + ??? 마커 검사 ──────────────────
    // 스펙: docs/superpowers/specs/2026-07-11-register-workbench-design.md R2 우측 ②③.
    // 마커(???) 검사는 입력마다 즉시(네트워크 없음) — 검증 호출(디바운스 900ms)과는 별개 상태로 취급하고,
    // [data-wb-lint] 에는 마커가 남아있으면 그 경고를 우선 표시한다(composeConfirm 클릭 차단의 근거이기도 함 — app-2-register.js).
    let wbLintTimer = null;
    let wbLintSeq = 0;          // in-flight 중복 방지 — 늦게 도착한 응답이 최신 상태를 덮지 않도록
    let wbLintResult = null;    // 마지막 /api/compose-validate 응답 { ok, errors[], warnings[] } — 아직 없으면 null
    let wbMarkerLines = [];     // 현재 에디터에서 '???' 가 남아있는 줄 번호(1-based)들

    function wbFindMarkerLines(yaml) {
      const out = [];
      (yaml || '').split('\n').forEach((ln, i) => { if (ln.includes('???')) out.push(i + 1); });
      return out;
    }
    // docker 에러 문자열에서 행 번호 추출 — "line 12" / "12 줄" 류만 가볍게(무리한 파싱 금지, 못 찾으면 null).
    function wbExtractErrorLine(msg) {
      const m = String(msg || '').match(/(?:line|줄)\s*[:#]?\s*(\d+)/i) || String(msg || '').match(/(\d+)\s*번?\s*줄/);
      return m ? Number(m[1]) : null;
    }

    function wbRenderLint() {
      const el = document.querySelector('[data-wb-lint]');
      if (!el) return;
      el.classList.remove('wb-lint-ok', 'wb-lint-warn');
      if (wbMarkerLines.length) {   // ??? 잔존 — 검증 응답과 무관하게 최우선 표시
        el.textContent = '⚠ 채워야 할 값 ' + wbMarkerLines.length + '개 (' + wbMarkerLines.join(', ') + '행)';
        el.classList.add('wb-lint-warn');
        return;
      }
      if (!wbLintResult) { el.textContent = '검증 전 — [검증 후 등록]을 누르면 확인해요'; return; }
      if (wbLintResult.ok) { el.textContent = '✓ 문법 OK'; el.classList.add('wb-lint-ok'); return; }
      const errs = wbLintResult.errors || [];
      const first = errs[0] || '';
      const ln = wbExtractErrorLine(first);
      const summary = first.length > 90 ? first.slice(0, 90) + '…' : first;
      el.textContent = '⚠ ' + errs.length + '건' + (ln ? ' (' + ln + '행)' : '') + (summary ? ' — ' + summary : '');
      el.classList.add('wb-lint-warn');
    }

    // 응답 대기 없이 화면/상태만 초기화(네트워크 호출 없음) — 워크벤치 진입·로딩 placeholder 표시 중 등.
    function wbLintReset() {
      wbLintSeq++;   // 대기 중이던 이전 validate 응답을 무효화
      wbLintResult = null;
      const ta = document.getElementById('composeYaml');
      wbMarkerLines = wbFindMarkerLines(ta ? ta.value : '');
      wbRenderLint();
    }
    // 실제 편집 반영 — 마커는 즉시 재계산해 그리고, 검증 호출은 900ms 디바운스.
    function wbScheduleLint() {
      const ta = document.getElementById('composeYaml');
      wbMarkerLines = wbFindMarkerLines(ta ? ta.value : '');
      wbRenderLint();
      clearTimeout(wbLintTimer);
      wbLintTimer = setTimeout(wbRunValidate, 900);
    }
    async function wbRunValidate() {
      const root = wbMatRoot();
      const ta = document.getElementById('composeYaml');
      const yaml = ta ? ta.value : '';
      if (!root || !yaml.trim()) { wbLintResult = null; wbRenderLint(); return; }   // 경로 없으면 스킵(스펙)
      const seq = ++wbLintSeq;
      let r;
      try {
        r = await api('/api/compose-validate', {
          method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ path: root, yaml, envVar: composeStoredEnv.envVar, envDefault: composeStoredEnv.envDefault }),
        });
      } catch (e) {
        r = { ok: false, errors: [String((e && e.message) || e)], warnings: [] };
      }
      if (seq !== wbLintSeq) return;   // 최신 요청만 반영 — 더 늦게 시작한 요청이 이미 있으면 이 응답은 버림
      wbLintResult = r;
      wbRenderLint();
    }
    (function wireWorkbenchLint() {
      const ta = document.getElementById('composeYaml');
      if (!ta) return;
      ta.addEventListener('input', wbScheduleLint);
    })();

    // ── 재료 서랍 (M3) ───────────────────────────────────────────────────────
    // 스펙 R2 좌 상단 "서비스 재료": 서브레포 스캔(Dockerfile·자체 compose)·기존 compose 를 근거와 함께 나열,
    // 클릭 = 우측 에디터에 블록 삽입(compose-scan/scaffold/detect 재사용). 자동 결정 0 — 스캔은 버튼으로만 실행,
    // 기존 compose 목록은 파일 glob 뿐이라 워크벤치 진입 시 가볍게 자동 로드(스펙 명시). 구 .compose-rail
    // (renderComposeSubrepos 등, app-1-core.js)이 하던 역할을 흡수한다.
    let wbScanResult = null;      // 마지막 /api/compose-scan 결과 { projectName, subrepos:[{subrepo, dockerfiles:[...]}] }
    let wbExistingResult = null;  // 마지막 /api/compose-detect 결과(가벼운 목록 — files/stored)

    function wbMatRoot() { return (document.getElementById('registerPath').value || '').trim(); }

    function wbMatStatus(kind, text) {   // 재료 서랍 안 인라인 진행/에러 — alert 금지(형 규칙)
      const el = document.getElementById('wbMatStatus');
      if (!el) return;
      if (!text) { el.hidden = true; return; }
      el.hidden = false;
      el.className = 'wb-mat-status svc-llm-progress ' + kind;
      el.innerHTML = '<span>' + escapeHtml(text) + '</span>';
    }

    // 문서의 services: 블록 텍스트만 추출(다음 top-level 키 전까지) — 재료 카드 [✓ 추가됨] 판단이 x-marina 등
    // 다른 블록의 동일 이름 키에 오탐하지 않도록.
    function wbServicesBlockText() {
      const yaml = document.getElementById('composeYaml').value || '';
      const lines = yaml.split('\n');
      let out = [], inBlock = false;
      for (const ln of lines) {
        if (/^services:\s*$/.test(ln)) { inBlock = true; continue; }
        if (!inBlock) continue;
        if (/^\S/.test(ln)) break;   // 다음 top-level 키 — services 블록 끝
        out.push(ln);
      }
      return out.join('\n');
    }
    function wbUsedServiceNames() {   // 간단 정규식(스펙 R2) — services 블록 안 2-space 키만
      return new Set([...wbServicesBlockText().matchAll(/^ {2}([\w.-]+):/gm)].map(m => m[1]));
    }
    function wbUsedIncludes() {
      const yaml = document.getElementById('composeYaml').value || '';
      return new Set([...yaml.matchAll(/^\s*-\s*(\S+\.ya?ml)\s*$/gm)].map(m => m[1]));
    }

    // openWorkbench 진입 시 재료 서랍 초기화 — 스캔 결과는 항상 비움(자동 재스캔 금지), 기존 compose 만 가볍게 재조회.
    function wbResetMaterials(root) {
      wbScanResult = null;
      wbMatStatus('', '');
      const scanBtn = document.getElementById('wbScanBtn');
      if (scanBtn) { scanBtn.disabled = false; scanBtn.textContent = '🔍 레포 스캔'; }
      wbRenderScan();
      wbLoadExisting(root);
    }
    // 경로 입력이 바뀌면(직접 타이핑/찾아보기) 이전 스캔은 무효 — 기존 compose 목록만 재조회.
    function wbOnPathChanged() { wbResetMaterials(wbMatRoot()); }

    // ── 기존 compose (스펙 R2 좌상단 두 번째 카드 유형) — /api/compose-detect, 가벼운 파일 glob 뿐이라 자동 로드 ──
    async function wbLoadExisting(root) {
      const box = document.getElementById('wbMatExisting');
      if (!box) return;
      wbExistingResult = null;
      if (!root) { box.innerHTML = ''; return; }
      box.innerHTML = '<div class="wb-mat-loading">기존 compose 확인 중…</div>';
      try {
        const r = await api('/api/compose-detect?path=' + enc(root));
        wbExistingResult = r;
      } catch (e) {
        box.innerHTML = '';
        wbMatStatus('err', String((e && e.message) || e));
        return;
      }
      wbRenderExisting();
    }
    function wbRenderExisting() {
      const box = document.getElementById('wbMatExisting');
      if (!box) return;
      box.innerHTML = '';
      const r = wbExistingResult;
      if (!r) return;
      const files = (r.files || []).slice();
      if (r.stored && r.stored.yaml) {
        files.unshift({ rel: '💾 marina 저장본 (' + (r.stored.composeFile || 'docker-compose.yml') + ')', content: r.stored.yaml, __stored: true });
      }
      if (!files.length) return;   // 없으면 조용히 숨김 — 재등록/편집이 아니면 흔한 경우
      const head = document.createElement('div'); head.className = 'wb-mat-group-head'; head.textContent = '📄 기존 compose';
      box.appendChild(head);
      for (const f of files) {
        const card = document.createElement('div'); card.className = 'wb-mat'; card.dataset.wbMat = 'existing';
        const label = f.__stored ? f.rel : ('📄 ' + f.rel);
        const evi = f.__stored ? 'marina 에 저장된 compose (등록하면 이걸로 교체)' : ('프로젝트 안 ' + f.rel);
        card.innerHTML = `<div class="wb-mat-row"><span class="wb-mat-name">${escapeHtml(label)}</span>
          <button type="button" class="wb-mat-btn" data-act="load">불러오기</button></div>
          <div class="wb-mat-evi">근거: ${escapeHtml(evi)}</div>`;
        card.querySelector('[data-act="load"]').onclick = () => {
          if (!okToReplaceYaml()) return;   // 덮어쓰기 확인 — 기존 위저드 로직 재사용
          setComposeYaml(f.content || '');
          if (f.__stored) composeStoredEnv = { envVar: r.stored.envVar || '', envDefault: r.stored.envDefault || '' };
          if (typeof wbFormSyncFromEditor === 'function') wbFormSyncFromEditor();   // M4 훅 — 불러온 compose 로 폼 갱신(app-2c)
          if (typeof wbScheduleLint === 'function') wbScheduleLint();   // M5 — 불러온 내용으로 마커/검증 갱신
          wbMatStatus('ok', (f.__stored ? 'marina 저장본' : f.rel) + ' 을 불러왔어요 — 검토 후 등록');
          wbRenderScan();   // [✓ 추가됨] 배지 갱신
        };
        box.appendChild(card);
      }
    }

    // ── 스캔 (스펙 R2 좌상단 첫 카드 유형) — /api/compose-scan, 버튼 클릭에서만 실행(자동 결정 0) ──────────
    async function wbScan() {
      const root = wbMatRoot();
      if (!root) { wbMatStatus('err', '프로젝트 경로를 먼저 입력하세요'); return; }
      const btn = document.getElementById('wbScanBtn');
      if (btn) { btn.disabled = true; btn.textContent = '스캔 중…'; }
      wbMatStatus('run', '스캔 중…');
      try {
        const r = await api('/api/compose-scan', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ root }) });
        wbScanResult = r;
        wbRenderScan();
        wbMatStatus('', '');
      } catch (e) {
        wbMatStatus('err', String((e && e.message) || e));
      }
      if (btn) { btn.disabled = false; btn.textContent = '🔍 레포 스캔'; }
    }

    function wbRenderScan() {
      const box = document.getElementById('wbMatScan');
      if (!box) return;
      box.innerHTML = '';
      const r = wbScanResult;
      if (!r) return;
      const used = wbUsedServiceNames(), usedInc = wbUsedIncludes();
      let any = false;
      for (const sub of (r.subrepos || [])) {
        const dfs = sub.dockerfiles || [];
        if (!dfs.length) {   // Dockerfile 없음 — 자체 compose 후보(🧩 include). 루트 자신('.')은 include 후보 아님(위저드와 동일 관례).
          if (sub.subrepo === '.' || sub.subrepo === '') continue;
          any = true;
          box.appendChild(wbMatIncludeCard(sub.subrepo, usedInc));
          continue;
        }
        for (const df of dfs) { any = true; box.appendChild(wbMatServiceCard(sub.subrepo, df, used)); }
      }
      if (!any) {
        const e = document.createElement('div'); e.className = 'wb-mat-empty';
        e.textContent = 'Dockerfile·자체 compose 를 못 찾았어요 — 오른쪽 에디터에 직접 작성하세요.';
        box.appendChild(e);
      }
    }

    function wbMatIncludeCard(subrepo, usedInc) {
      const already = [...usedInc].some(p => p.replace(/^\.\//, '').startsWith(subrepo + '/'));
      const card = document.createElement('div'); card.className = 'wb-mat'; card.dataset.wbMat = 'include'; card.dataset.subrepo = subrepo;
      card.innerHTML = `<div class="wb-mat-row"><span class="wb-mat-name">🧩 ${escapeHtml(subrepo)}</span>
        ${already ? '<span class="wb-mat-added">✓ 추가됨</span>' : '<button type="button" class="wb-mat-btn" data-act="inc">+ include로</button>'}</div>
        <div class="wb-mat-evi">근거: ${escapeHtml(subrepo)} 자체 compose 보유(Dockerfile 없음) — 통째로 include</div>`;
      const btn = card.querySelector('[data-act="inc"]');
      if (btn) btn.onclick = () => wbInsertInclude(subrepo, btn);
      return card;
    }

    function wbMatServiceCard(subrepo, df, used) {
      const card = document.createElement('div'); card.className = 'wb-mat'; card.dataset.wbMat = 'service'; card.dataset.subrepo = subrepo; card.dataset.dockerfile = df.dockerfile;
      const argStr = (df.args || []).map(a => (df.requiredArgs || []).includes(a) ? a + '*' : a).join(', ') || '없음';
      const guessName = df.dockerfile.includes('/') ? df.dockerfile.split('/').slice(-2, -1)[0] : subrepo;   // 스캐폴드 이름 규칙 근사(간단 정규식 배지 판단용)
      const already = used.has(guessName);
      card.innerHTML = `<div class="wb-mat-row"><span class="wb-mat-name">🐳 ${escapeHtml(subrepo)}</span>
        ${already ? '<span class="wb-mat-added">✓ 추가됨</span>' : '<button type="button" class="wb-mat-btn" data-act="svc">+ 서비스로</button>'}</div>
        <div class="wb-mat-evi">근거: ${escapeHtml(subrepo)}/${escapeHtml(df.dockerfile)} · EXPOSE ${df.expose ? escapeHtml(df.expose) : '—'} · ARG ${escapeHtml(argStr)}</div>`;
      const btn = card.querySelector('[data-act="svc"]');
      if (btn) btn.onclick = () => wbInsertService(subrepo, df, btn);
      return card;
    }

    async function wbInsertService(subrepo, df, btn) {
      const root = wbMatRoot();
      if (!root) { wbMatStatus('err', '프로젝트 경로가 없어요'); return; }
      if (btn) btn.disabled = true;
      try {
        const rr = await api('/api/compose-scaffold?path=' + enc(root) + '&subrepo=' + enc(subrepo) + '&dockerfile=' + enc(df.dockerfile));
        if (rr && rr.include) { wbInsertIncludeFromScaffold(subrepo, rr.include, btn); return; }   // 서버가 뒤늦게 자체 compose 발견 — 정직하게 include 로 전환
        if (!(rr && rr.yaml)) { wbMatStatus('err', (rr && rr.error) || '스캐폴드 실패'); if (btn) btn.disabled = false; return; }
        const lines = rr.yaml.replace(/\s+$/, '').split('\n');
        lines.unshift('  # ← 재료에서 추가: ' + subrepo + '/' + df.dockerfile);   // 삽입 블록 첫 줄 = 출처 주석(스펙)
        // 필수 ARG 마커는 스캐폴드(백엔드)가 build.args 에 심는다 — environment 는 런타임 전용이라 빌드에 전달 안 됨(코덱스 P2)
        const hasMarker = /"\?\?\?"/.test(rr.yaml);
        appendComposeService(lines.join('\n'));   // app-1-core.js 재사용
        wbMatStatus('ok', subrepo + ' 서비스 추가' + (hasMarker ? ' — 필수 빌드 값(???) 채우고' : '') + ' 검증 후 등록');
        wbRenderScan();   // [✓ 추가됨] 배지 갱신
        if (typeof wbFormSyncFromEditor === 'function') wbFormSyncFromEditor();   // M4 훅 — 게이트웨이 체크박스 서비스 목록 갱신(app-2c)
        if (typeof wbScheduleLint === 'function') wbScheduleLint();   // M5 — 삽입된 ???/문법을 즉시 반영
      } catch (e) {
        wbMatStatus('err', String((e && e.message) || e));
        if (btn) btn.disabled = false;
      }
    }
    function wbInsertIncludeFromScaffold(subrepo, includePath, btn) {
      const comment = '# ← 재료에서 추가: ' + subrepo + '/' + includePath.split('/').pop();
      const inserted = appendComposeInclude(includePath, comment);   // app-1-core.js 재사용
      wbMatStatus('ok', inserted ? (subrepo + ' 을 include 로 추가했어요') : (subrepo + ' 은 이미 include 되어 있어요'));
      wbRenderScan();
      if (typeof wbFormSyncFromEditor === 'function') wbFormSyncFromEditor();   // M4 훅 — 게이트웨이 체크박스 서비스 목록 갱신(app-2c)
      if (typeof wbScheduleLint === 'function') wbScheduleLint();   // M5 — include 삽입 반영
    }
    async function wbInsertInclude(subrepo, btn) {
      const root = wbMatRoot();
      if (!root) { wbMatStatus('err', '프로젝트 경로가 없어요'); return; }
      if (btn) btn.disabled = true;
      try {
        const rr = await api('/api/compose-scaffold?path=' + enc(root) + '&subrepo=' + enc(subrepo));
        if (!(rr && rr.include)) { wbMatStatus('err', (rr && rr.error) || 'include 대상을 못 찾았어요'); if (btn) btn.disabled = false; return; }
        wbInsertIncludeFromScaffold(subrepo, rr.include, btn);
      } catch (e) {
        wbMatStatus('err', String((e && e.message) || e));
        if (btn) btn.disabled = false;
      }
    }

    // 스캔 버튼은 클릭에서만 wbScan 을 호출 — 자동 실행 금지(원칙: 자동 결정 0).
    (function wireMaterials() {
      const btn = document.getElementById('wbScanBtn');
      if (btn) btn.onclick = wbScan;
    })();
