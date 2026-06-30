    let sessions = [];
    let selected = null;
    let source = null;
    let followLog = true;
    // 표시 창 — 로그 파일에서 DOM 에 올라와 있는 바이트 구간 [top, bottom). live = SSE tail 수신 중
    let logWindow = {top: 0, bottom: 0, live: false};
    let logPaging = {loadingUp: false, loadingDown: false, atStart: true};
    let logFileSize = 0;  // 게이지 분모 — meta/chunk/matches 응답으로 갱신
    let logMatches = {offsets: [], total: 0, truncated: false, active: false};
    let matchScanTimer = null;
    // 매치 전용 뷰 — 필터/에러만 ON 이면 파일 전체의 매치를 한 번에 목록으로 (스크롤 페이징 대신)
    let matchView = false;
    let sessionSignature = '';
    const openLinksRoots = new Set();
    const expandedRoots = new Set();
    const subrepoOpen = new Map();   // `${root}::${subrepo}` → bool (펼침). 미설정이면 attached=펼침 기본.
    let selectedProjectId = localStorage.getItem('marinaSelectedProject') || null;
    let switcherOpen = false;

    function projectSummaries() {
      // worktreeData 가 모든 등록 프로젝트의 main 엔트리를 포함 → projectId 로 그룹.
      const byId = new Map();
      for (const wt of worktreeData) {
        if (!byId.has(wt.projectId)) {
          byId.set(wt.projectId, { id: wt.projectId, label: wt.projectLabel || wt.projectId, root: wt.projectRoot, on: 0, conflict: 0 });
        }
      }
      for (const s of sessions) {
        const wt = worktreeData.find(w => w.root === s.root);
        if (!wt) continue;
        const sum = byId.get(wt.projectId);
        if (!sum) continue;
        if ((s.services || []).some(svc => svc.running)) sum.on += 1;
        if ((s.webPortConflictWith || []).length) sum.conflict += 1;
      }
      return [...byId.values()];
    }

    function setSelectedProject(id) {
      selectedProjectId = id;
      if (id) localStorage.setItem('marinaSelectedProject', id);
      else localStorage.removeItem('marinaSelectedProject');
      switcherOpen = false;
      render();
    }

    function chipHtml(sum) {
      if (sum.conflict) return `<span class="switcher-chip conflict">${sum.conflict} 충돌</span>`;
      if (sum.on) return `<span class="switcher-chip on">${sum.on} ON</span>`;
      return '<span class="switcher-chip idle">idle</span>';
    }

    function renderSwitcher() {
      const summaries = projectSummaries();
      const current = summaries.find(s => s.id === selectedProjectId);
      document.getElementById('switcherCurrent').textContent = current ? current.label : (summaries.length ? '프로젝트 선택' : '등록된 프로젝트 없음');
      const menu = document.getElementById('switcherMenu');
      menu.hidden = !switcherOpen;
      if (!switcherOpen) return;
      menu.innerHTML = '';
      for (const sum of summaries) {
        const row = document.createElement('div');
        row.className = `switcher-row${sum.id === selectedProjectId ? ' active' : ''}`;
        row.innerHTML = `
          <span class="switcher-row-name" title="${escapeHtml(sum.root)}">${escapeHtml(sum.label)}</span>
          ${chipHtml(sum)}
          <span class="switcher-row-actions">
            <button data-share-project title="공유용 복사 — compose+x-marina 한 블록을 클립보드로 (팀원이 붙여넣기로 재현)">📋</button>
            <button data-edit-subrepos title="subrepos 편집">⚙</button>
            <button data-remove-project class="danger" title="프로젝트 등록 해제">✕</button>
          </span>`;
        row.querySelector('.switcher-row-name').onclick = () => setSelectedProject(sum.id);
        row.querySelector('[data-share-project]').onclick = (e) => { e.stopPropagation(); shareProject(sum); };
        row.querySelector('[data-edit-subrepos]').onclick = (e) => { e.stopPropagation(); openSubrepoEdit(sum); };
        row.querySelector('[data-remove-project]').onclick = (e) => { e.stopPropagation(); removeProject(sum); };
        menu.appendChild(row);
      }
      const reg = document.createElement('button');
      reg.className = 'switcher-register';
      reg.textContent = '+ 프로젝트 등록';
      reg.onclick = () => openRegisterPanel();
      menu.appendChild(reg);
    }

    document.getElementById('switcherToggle').onclick = () => { switcherOpen = !switcherOpen; renderSwitcher(); };
    document.addEventListener('click', (e) => {
      if (switcherOpen && !e.target.closest('#switcher')) { switcherOpen = false; renderSwitcher(); }
    });

    function showRegisterPanel(show) {
      document.getElementById('registerBackdrop').hidden = !show;
    }

    // 작업공간 모드(.workspace, 넓은 폭·고정 높이·sticky footer) = compose 에디터가 보일 때만.
    // composeSection 가시성을 바꾸는 모든 경로에서 호출 — subrepos 편집('new' 뷰지만 compose 아님) 등 오적용 방지.
    function syncRegisterWorkspace() {
      const on = !document.getElementById('composeSection').hidden;
      document.getElementById('registerPanel').classList.toggle('workspace', on);
    }

    // 진입 2경로(spec §4): [새로 설정(위저드)] · [팀원 설정 붙여넣기]
    function setRegisterView(view) {   // 'entry' | 'new' | 'paste' | 'wizard'
      document.getElementById('registerEntry').hidden = view !== 'entry';
      document.getElementById('registerPaste').hidden = view !== 'paste';
      document.getElementById('registerWizard').hidden = view !== 'wizard';
      const pathOn = view === 'new' || view === 'wizard';
      document.getElementById('registerPathLabel').hidden = !pathOn;
      document.getElementById('registerPathRow').hidden = !pathOn;
      if (view !== 'new') {   // raw(new) 뷰 아니면 compose/preview/browse 숨김
        document.getElementById('composeSection').hidden = true;
        document.getElementById('registerPreview').hidden = true;
        document.getElementById('browsePanel').hidden = true;
        document.getElementById('registerError').hidden = true;
      }
      syncRegisterWorkspace();
    }

    function openRegisterPanel() {
      switcherOpen = false;
      document.getElementById('registerTitle').textContent = '프로젝트 등록';
      document.getElementById('registerError').hidden = true;
      setRegisterView('entry');
      showRegisterPanel(true);
      renderSwitcher();
    }

    document.getElementById('entryWizard').onclick = () => openWizard();
    document.getElementById('entryPaste').onclick = () => openPasteImport();

    function openPasteImport() {
      document.getElementById('registerTitle').textContent = '팀원 설정 붙여넣기';
      document.getElementById('pastePath').value = '';
      document.getElementById('pasteBlob').value = '';
      document.getElementById('pasteApply').checked = true;
      document.getElementById('pasteError').hidden = true;
      setRegisterView('paste');
    }

    // compose 의 ${VAR} 보간 기본값 — 단일입력 UI 는 제거(P1 ${VAR} 테이블이 대체). 저장된 값은 편집·등록 왕복에서 보존.
    let composeStoredEnv = { envVar: '', envDefault: '' };
    function openComposeRegister() {
      document.getElementById('registerTitle').textContent = '프로젝트 등록';
      document.getElementById('registerPath').value = '';
      document.getElementById('registerPath').disabled = false;
      document.getElementById('registerBrowse').hidden = false;  // 등록: 경로 탐색·분석 노출
      document.getElementById('registerInfer').hidden = false;
      document.getElementById('registerPreview').hidden = true;
      document.getElementById('registerError').hidden = true;
      document.getElementById('browsePanel').hidden = true;
      // 이전 infer 잔재 제거 — 새 등록은 빈 상태에서 시작
      document.getElementById('registerChecklist').innerHTML = '';
      document.getElementById('registerMeta').textContent = '';
      // compose 에디터도 초기화 — 직전 편집(✎)/등록 내용이 새 등록에 남지 않게
      setComposeYaml('');
      composeStoredEnv = { envVar: '', envDefault: '' };   // 신규 등록 — env 보간값 초기화
      document.getElementById('composeProgress').hidden = true;
      document.getElementById('composeDetectList').hidden = true;
      document.getElementById('composeSubrepos').hidden = true;
      document.getElementById('composeSubrepos').innerHTML = '';
      setRegisterView('new');       // 위저드/직접 작성 뷰 노출
      setRegisterKind('compose');   // compose-only — 등록은 compose만
      showRegisterPanel(true);
      renderSwitcher();
    }

    // 이미 등록된 compose 프로젝트의 보관 docker-compose.yml 편집 (카드 ✎). 저장 = compose-register upsert(덮어쓰기).
    async function openComposeEdit(root) {
      switcherOpen = false;
      setRegisterView('new');   // 진입 선택/붙여넣기 뷰 숨기고 경로행 노출
      document.getElementById('registerTitle').textContent = 'compose 편집';
      document.getElementById('registerPath').value = root;
      document.getElementById('registerPath').disabled = true;     // 편집: 경로 고정
      document.getElementById('registerBrowse').hidden = true;
      document.getElementById('registerInfer').hidden = true;
      document.getElementById('registerPreview').hidden = true;
      document.getElementById('browsePanel').hidden = true;
      document.getElementById('registerError').hidden = true;
      document.getElementById('composeProgress').hidden = true;
      document.getElementById('composeDetectList').hidden = true;
      setComposeYaml('불러오는 중…');
      document.getElementById('composeSection').hidden = false;
      syncRegisterWorkspace();   // compose 편집 = 작업공간 모드
      renderComposeSubrepos(root);
      showRegisterPanel(true);
      renderSwitcher();
      const err = document.getElementById('registerError');
      try {
        const r = await api('/api/compose-detect?path=' + enc(root));
        if (r && r.stored) {
          setComposeYaml(r.stored.yaml || '');
          composeStoredEnv = { envVar: r.stored.envVar || '', envDefault: r.stored.envDefault || '' };   // 저장된 env 보간값 보존(등록 시 재전송)
        } else {
          setComposeYaml('');
          err.textContent = '보관된 compose 를 찾지 못했습니다'; err.hidden = false;
        }
      } catch (e) {
        setComposeYaml('');
        err.textContent = String(e.message || e); err.hidden = false;
      }
    }

    function addChecklistRow(name, checked, removable) {
      const box = document.getElementById('registerChecklist');
      if ([...box.querySelectorAll('input')].some(c => c.value === name)) return; // 중복 방지
      const empty = box.querySelector('.register-empty'); if (empty) empty.remove();
      const row = document.createElement('label');
      row.className = 'register-check';
      const cb = document.createElement('input');
      cb.type = 'checkbox'; cb.value = name; cb.checked = checked;
      row.appendChild(cb);
      row.appendChild(document.createTextNode(name));
      if (removable) {
        // 수동 추가분만 ✕ 로 목록에서 제거 가능. infer 가 잡은 기본 subrepo 는 디스크에 실재 → 체크해제만(재분석 시 부활)
        const rm = document.createElement('button');
        rm.type = 'button'; rm.className = 'check-remove'; rm.textContent = '✕'; rm.title = '목록에서 제거';
        rm.onclick = (e) => { e.preventDefault(); e.stopPropagation(); row.remove(); };
        row.appendChild(rm);
      }
      box.appendChild(row);
    }
    function renderChecklist(universe, checked, inferred) {
      const box = document.getElementById('registerChecklist');
      box.innerHTML = '';
      if (!universe.length && !checked.length) {
        box.innerHTML = '<div class="register-empty">monorepo (subrepos 없음) — 필요하면 아래에 직접 추가</div>';
        return;
      }
      // inferred(코드로 잡힌 기본)는 ✕ 없음, universe 중 inferred 아닌 것(수동/깊은)만 removable
      for (const name of universe) addChecklistRow(name, checked.includes(name), !inferred.includes(name));
    }
    document.getElementById('registerManualAdd').onclick = () => {
      const input = document.getElementById('registerManualPath');
      const name = input.value.trim().replace(/^\/+|\/+$/g, '');
      const err = document.getElementById('registerError');
      if (!name) return;
      if (name.startsWith('/') || name.split('/').includes('..')) {
        err.textContent = '프로젝트 root 상대경로만 (선행 / 또는 .. 불가)'; err.hidden = false; return;
      }
      err.hidden = true;
      addChecklistRow(name, true, true);
      input.value = '';
    };

    async function inferAndPreview(path, checkedDefault) {
      const err = document.getElementById('registerError');
      err.hidden = true;
      try {
        const info = await api('/api/infer-project', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({ path }),
        });
        document.getElementById('registerMeta').textContent =
          `id: ${info.id} · ${info.worktreeGlobs.join(', ')}`;
        const inferred = info.subrepos || [];
        const checked = checkedDefault === null ? inferred : checkedDefault;
        // edit: 등록돼 있지만 infer 가 못 잡은(깊은/수동) subrepo 도 universe 에 포함 → 체크된 채 보이게
        const universe = [...inferred, ...checked.filter(n => !inferred.includes(n))];
        renderChecklist(universe, checked, inferred);
        document.getElementById('registerPreview').hidden = false;
        return info;
      } catch (e) {
        err.textContent = String(e.message || e); err.hidden = false;
        document.getElementById('registerPreview').hidden = true;
        return null;
      }
    }

    document.getElementById('registerClose').onclick = () => showRegisterPanel(false);
    // 모달: 배경(바깥) 클릭으로는 *안* 닫음(실수로 입력 날리는 것 방지) — 닫기는 ✕ 또는 Esc 로만.
    document.getElementById('registerBackdrop').onclick = (e) => { if (e.target.id === 'registerBackdrop') e.stopPropagation(); };
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && !document.getElementById('registerBackdrop').hidden) showRegisterPanel(false);
    });

    let browseCurrent = '';
    let browseMode = 'project';  // 'project' = registerPath 채움 / 'subrepo' = 상대경로로 체크리스트 추가
    let browseRoot = '';         // subrepo 모드의 resolved 프로젝트 root (상대경로 계산 기준)
    function relPath(root, target) {
      // root 기준 target 의 상대경로 — root 밖이면 ../ 포함 (자유 등록 허용)
      const r = root.replace(/\/+$/, '').split('/');
      const t = target.replace(/\/+$/, '').split('/');
      let i = 0; while (i < r.length && i < t.length && r[i] === t[i]) i++;
      return [...r.slice(i).map(() => '..'), ...t.slice(i)].join('/') || '.';
    }
    // 공용 파일탐색기 — /api/browse 디렉토리 entries 를 클릭 가능한 행으로 렌더. 등록 패널·링크 모달이 공유.
    // opts: { onEnter(childPath), onPick(name, childPath, row)?, multiPick?, pickedPaths?(Set), pickLabel?, selectedPath?, addedPaths?, showGit?, showUpRow?, emptyText? }
    // multiPick: 행마다 버튼 대신 우측 체크 토글 — 이름 클릭=진입, 체크 클릭=선택 유지(다중). 이미 추가된 건 ✓ 잠금.
    function renderBrowseEntries(listEl, data, opts) {
      const o = opts || {};
      listEl.innerHTML = '';
      if (o.showUpRow && data.parent) {
        const up = document.createElement('div');
        up.className = 'browse-row'; up.innerHTML = '<span>📁 ..</span>';
        up.onclick = () => o.onEnter(data.parent);
        listEl.appendChild(up);
      }
      for (const e of (data.entries || [])) {
        const child = data.path.replace(/\/$/, '') + '/' + e.name;
        const row = document.createElement('div');
        row.className = 'browse-row';
        const added = !!(o.addedPaths && o.addedPaths.has && o.addedPaths.has(child));
        const picked = !!(o.pickedPaths && o.pickedPaths.has && o.pickedPaths.has(child));
        const selected = o.multiPick ? picked : (o.selectedPath === child);
        row.classList.toggle('selected', selected);
        row.classList.toggle('added', added);
        const git = (o.showGit && e.isGitRepo) ? '<span class="repo-badge">git</span>' : '';
        if (o.multiPick && o.onPick) {
          const mark = added ? '✓' : (picked ? '✓' : '+');
          const aria = added ? '이미 추가됨' : (picked ? '선택 해제' : '선택');
          row.innerHTML = `<span class="fb-enter">📁 ${escapeHtml(e.name)}</span>${git}`
            + `<button class="fb-check${picked ? ' on' : ''}${added ? ' added' : ''}" type="button" title="${aria}" aria-pressed="${picked || added}"${added ? ' disabled' : ''}>${mark}</button>`;
          row.querySelector('.fb-enter').onclick = () => o.onEnter(child);
          const chk = row.querySelector('.fb-check');
          if (!added) chk.onclick = (ev) => { ev.stopPropagation(); o.onPick(e.name, child, row); };
        } else if (o.onPick) {
          const label = added ? '추가됨' : (selected ? '선택됨' : (o.pickLabel || '선택'));
          row.innerHTML = `<span class="fb-enter">📁 ${escapeHtml(e.name)}</span>${git}<button class="fb-pick" type="button">${escapeHtml(label)}</button>`;
          row.querySelector('.fb-enter').onclick = () => o.onEnter(child);
          row.querySelector('.fb-pick').onclick = () => o.onPick(e.name, child, row);
        } else {
          row.innerHTML = `<span class="fb-enter">📁 ${escapeHtml(e.name)}</span>${git}`;
          row.onclick = () => o.onEnter(child);
        }
        listEl.appendChild(row);
      }
      if (!listEl.children.length && o.emptyText) {
        listEl.innerHTML = `<span class="config-label">${escapeHtml(o.emptyText)}</span>`;
      }
    }
    async function openBrowse(path) {
      try {
        const data = await api('/api/browse' + (path ? ('?path=' + enc(path)) : ''));
        browseCurrent = data.path;
        document.getElementById('browsePath').textContent = data.path;
        renderBrowseEntries(document.getElementById('browseList'), data, {
          onEnter: openBrowse, showGit: true, showUpRow: true,
        });
        document.getElementById('browsePanel').hidden = false;
      } catch (err) {
        const el = document.getElementById('registerError');
        el.textContent = String(err.message || err); el.hidden = false;
      }
    }
    document.getElementById('registerBrowse').onclick = () => {
      browseMode = 'project';
      document.getElementById('registerError').after(document.getElementById('browsePanel')); // 경로줄 아래로
      const cur = document.getElementById('registerPath').value.trim();
      openBrowse(cur || '');
    };
    document.getElementById('registerManualBrowse').onclick = async () => {
      const root = document.getElementById('registerPath').value.trim();
      const err = document.getElementById('registerError');
      if (!root) { err.textContent = '프로젝트 경로 먼저 입력'; err.hidden = false; return; }
      err.hidden = true;
      browseMode = 'subrepo';
      document.querySelector('.register-manual').after(document.getElementById('browsePanel')); // 수동 입력줄 바로 아래로
      try {
        const data = await api('/api/browse?path=' + enc(root));
        browseRoot = data.path;                 // resolved 프로젝트 root — 이 위로는 못 올라감
        openBrowse(data.path);
      } catch (e) { err.textContent = String(e.message || e); err.hidden = false; }
    };
    document.getElementById('browseSelect').onclick = () => {
      if (browseMode === 'subrepo') {
        const rel = relPath(browseRoot, browseCurrent);
        if (rel !== '.') addChecklistRow(rel, true, true);  // root 자신만 제외, 그 외(../ 상위 포함)는 자유 등록
      } else if (browseMode === 'composeSub') {
        const rel = relPath(browseRoot, browseCurrent);
        const box = document.getElementById('composeSubrepos');
        if (rel !== '.' && box.lastElementChild) box.insertBefore(makeSubrepoRow(composeSubBrowsePath, rel, externalMount(rel)), box.lastElementChild);
      } else if (browseMode === 'paste') {
        document.getElementById('pastePath').value = browseCurrent;
      } else {
        document.getElementById('registerPath').value = browseCurrent;
        if (!document.getElementById('composeSection').hidden) renderComposeSubrepos(browseCurrent);
      }
      document.getElementById('browsePanel').hidden = true;
    };
    document.getElementById('registerInfer').onclick = () => {
      const path = document.getElementById('registerPath').value.trim();
      if (path) inferAndPreview(path, null); // 신규 = 전체 체크 기본
    };
    document.getElementById('registerConfirm').onclick = async () => {
      const path = document.getElementById('registerPath').value.trim();
      const subrepos = [...document.querySelectorAll('#registerChecklist input:checked')].map(c => c.value);
      const err = document.getElementById('registerError');
      const btn = document.getElementById('registerConfirm');
      const label = btn.textContent;
      err.hidden = true;
      btn.disabled = true; btn.innerHTML = BUSY_DOTS;
      let res;
      try {
        res = await api('/api/add-project', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({ path, subrepos }),
        });
      } catch (e) {
        err.textContent = String(e.message || e); err.hidden = false;
        btn.disabled = false; btn.textContent = label;
        return; // 패널 유지 — 사용자가 경로 고쳐 재시도
      }
      showRegisterPanel(false);
      await loadWorktrees(true);
      await load({ force: true });
      btn.disabled = false; btn.textContent = label;
      // 서버가 돌려준 resolved id 로 선택 (타이핑 경로 문자열 매칭의 basename 충돌·trailing slash 함정 회피)
      if (res && res.id && [...new Set(worktreeData.map(w => w.projectId))].includes(res.id)) setSelectedProject(res.id);
      else render();
    };

    // ── compose 프로젝트 등록 (kind=compose) ───────────────────────────────────
    let composeBusy = false;
    function setRegisterKind(kind) {
      const compose = kind === 'compose';
      document.getElementById('composeSection').hidden = !compose;
      syncRegisterWorkspace();   // compose 에디터 가시성에 작업공간 모드 동기화

      document.getElementById('registerInfer').hidden = compose;       // compose 면 기존 분석 흐름 숨김
      if (compose) {
        document.getElementById('registerPreview').hidden = true;
        document.getElementById('composeProgress').hidden = true;
        document.getElementById('composeDetectList').hidden = true;
      }
    }

    // 서브레포 감지 + 수동추가 → 각 서브레포를 "+ 서비스" 스캐폴드로 에디터에 추가.
    async function renderComposeSubrepos(path) {
      const box = document.getElementById('composeSubrepos');
      box.innerHTML = '';
      if (!path) { box.hidden = true; return; }
      let subs = [], ext = [];
      try { const r = await api('/api/compose-detect?path=' + enc(path)); subs = (r && r.subrepos) || []; ext = (r && r.externalRepos) || []; } catch {}
      box.hidden = false;
      const head = document.createElement('div');
      head.style = 'font-size:12px;color:var(--muted)';
      head.textContent = '서브레포 — 서비스로 추가';
      box.appendChild(head);
      for (const s of subs) box.appendChild(makeSubrepoRow(path, s));
      for (const e of ext) box.appendChild(makeSubrepoRow(path, e.sub, e.mount));   // 등록된 외부 레포 복원(재등록 시 드롭 방지)
      const man = document.createElement('div');
      man.style = 'display:flex;align-items:center;gap:8px';
      const browseBtn = document.createElement('button');
      browseBtn.type = 'button'; browseBtn.className = 'svc-llm-go'; browseBtn.textContent = '📁 찾아보기';
      browseBtn.title = '폴더를 골라 서브레포로 추가';
      browseBtn.onclick = () => openComposeSubBrowse(path);
      const inp = document.createElement('input');
      inp.placeholder = '또는 상대경로 직접 (예: services/api)';
      inp.style = 'flex:1;font-size:13px;height:30px';
      const addBtn = document.createElement('button');
      addBtn.type = 'button'; addBtn.className = 'svc-llm-go'; addBtn.textContent = '+ 추가';
      const doAdd = () => { const v = inp.value.trim(); if (!v) return; if (v.startsWith('/')) { setComposeProgress('err', '절대경로는 📁 찾아보기로 추가하세요'); return; } box.insertBefore(makeSubrepoRow(path, v, externalMount(v)), man); inp.value = ''; };
      addBtn.onclick = doAdd;
      inp.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); doAdd(); } });
      man.appendChild(browseBtn); man.appendChild(inp); man.appendChild(addBtn);
      box.appendChild(man);
    }
    let composeSubBrowsePath = '';
    async function openComposeSubBrowse(path) {
      if (!path) return;
      browseMode = 'composeSub';
      composeSubBrowsePath = path;
      document.getElementById('composeSubrepos').after(document.getElementById('browsePanel'));
      try {
        const data = await api('/api/browse?path=' + enc(path));
        browseRoot = data.path;                 // 프로젝트 root — 이 위로는 못 올라감(상대경로 기준)
        openBrowse(data.path);
      } catch (e) { setComposeProgress('err', String((e && e.message) || e)); }
    }
    function makeSubrepoRow(path, s, mount) {
      const row = document.createElement('div');
      row.dataset.subrepo = s;
      if (mount) row.dataset.mount = mount;
      row.style = 'display:flex;align-items:center;gap:8px;font-size:13px';
      const nm = document.createElement('span'); nm.textContent = '📁 ' + s;
      nm.style = 'flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap';
      const ctxQ = mount ? ('&context=' + enc(mount)) : '';
      const scaffold = async (chosen) => {
        try {
          const rr = await api('/api/compose-scaffold?path=' + enc(path) + '&subrepo=' + enc(s) + ctxQ
            + (chosen ? '&dockerfile=' + enc(chosen) : ''));
          if (rr && rr.include) { appendComposeInclude(rr.include); setComposeProgress('ok', s + ' 자체 compose 가져옴 (include) — 포트는 marina 가 격리'); }
          else if (rr && rr.needPick) showDockerfilePicker(row, s, rr.dockerfiles || [], scaffold);
          else if (rr && rr.yaml) { appendComposeService(rr.yaml); setComposeProgress('ok', s + ' 서비스 추가 — 포트·명령 다듬고 등록'); }
          else setComposeProgress('err', (rr && rr.error) || '스캐폴드 실패');
        } catch (e) { setComposeProgress('err', String((e && e.message) || e)); }
      };
      const add = document.createElement('button');
      add.type = 'button'; add.textContent = '＋ 서비스';
      // prominent accent pill 대신 컴팩트·subtle — 서브레포 행이 깔끔한 리스트로 보이게(버튼 벽 방지)
      add.style = 'height:24px;padding:0 10px;border-radius:6px;border:1px solid var(--sys-style-neutral-default);background:transparent;color:var(--sys-cont-neutral-default);font-size:12px;font-weight:600;cursor:pointer;white-space:nowrap';
      add.title = s + ' → 서비스 추가: 자체 docker-compose.yml 있으면 통째로 가져오고(include), 없으면 Dockerfile 기반(자체 서브레포 N개면 각각)';
      add.onclick = async () => { add.disabled = true; await scaffold(''); add.disabled = false; };
      const del = document.createElement('button');
      del.type = 'button'; del.className = 'check-remove'; del.textContent = '✕';
      del.title = '이 서브레포를 목록에서 제거';
      del.onclick = () => { const p = row.nextElementSibling; if (p && p.dataset.picker === '1') p.remove(); row.remove(); };
      row.appendChild(nm);
      if (mount) {   // 외부 레포 — 워크트리마다 격리(.workspace/external) 표시
        const bdg = document.createElement('span'); bdg.textContent = '외부';
        bdg.title = '프로젝트 밖 레포 — 워크트리마다 git worktree 로 격리';
        bdg.style = 'font-size:11px;color:var(--muted);border:1px solid var(--muted);border-radius:8px;padding:0 5px;opacity:.85';
        row.appendChild(bdg);
      }
      row.appendChild(add); row.appendChild(del);
      return row;
    }
    function externalMount(rel) {   // 프로젝트 밖(../)이면 .workspace/external/<name> 마운트, 내부면 ''
      if (!rel || !rel.split('/').includes('..')) return '';
      const base = (rel.split('/').filter(p => p && p !== '..').pop() || 'ext');
      const name = base.toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^[-_]+|[-_]+$/g, '') || 'ext';
      return './.workspace/external/' + name;
    }
    function showDockerfilePicker(row, s, dockerfiles, scaffold) {
      let pick = row.nextElementSibling;
      if (!pick || pick.dataset.picker !== '1') {
        pick = document.createElement('div'); pick.dataset.picker = '1';
        pick.style = 'display:flex;flex-wrap:wrap;align-items:center;gap:6px;font-size:12px;color:var(--muted);margin:-2px 0 4px 18px';
        row.after(pick);
      }
      pick.innerHTML = '';
      const lab = document.createElement('span');
      lab.textContent = 'Dockerfile마다 서비스 — 각각/전체 추가:';
      lab.title = s + ' 안의 자체 서브레포들 (Dockerfile 하나당 서비스 하나, 디렉터리=이름·컨텍스트)';
      pick.appendChild(lab);
      const addOne = async (df, b) => { b.disabled = true; await scaffold(df); b.textContent = '✓ ' + df; };
      for (const df of dockerfiles) {
        const b = document.createElement('button'); b.type = 'button'; b.className = 'svc-llm-go'; b.textContent = df;
        b.onclick = () => addOne(df, b);   // 각각 추가 — 누르면 그 Dockerfile 서비스 추가(피커 유지)
        pick.appendChild(b);
      }
      if (dockerfiles.length > 1) {        // 여러 개면 한 번에
        const all = document.createElement('button'); all.type = 'button'; all.className = 'svc-llm-go';
        all.textContent = '전체 추가';
        all.onclick = async () => { all.disabled = true; for (const df of dockerfiles) await scaffold(df); pick.remove(); };
        pick.appendChild(all);
      }
    }
    function appendComposeService(block) {
      const ed = document.getElementById('composeYaml');
      let cur = ed.value.replace(/\s+$/, '');
      if (!/^services:/m.test(cur)) cur = (cur ? cur + '\n' : '') + 'services:';
      setComposeYaml(cur + '\n' + block.replace(/\s+$/, '') + '\n');   // 하이라이트·line# 갱신 경유
    }
    function appendComposeInclude(p) {   // 서브레포 자체 compose 를 top-level include: 로 (중복 방지)
      const ed = document.getElementById('composeYaml');
      let cur = ed.value.replace(/\s+$/, '');
      const esc = p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      if (new RegExp('^\\s*-\\s*' + esc + '\\s*$', 'm').test(cur)) return;   // 이미 있음
      if (/^include:/m.test(cur)) cur = cur.replace(/^include:[^\n]*\n/m, (m) => m + '  - ' + p + '\n');
      else cur = 'include:\n  - ' + p + '\n' + cur;
      setComposeYaml(cur.replace(/\s+$/, '') + '\n');   // 하이라이트·line# 갱신 경유
    }
