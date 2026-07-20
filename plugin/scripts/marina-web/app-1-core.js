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
    const EXPANDED_ROOTS_KEY = 'marinaExpandedRoots';
    function loadExpandedRoots() {
      try {
        const roots = JSON.parse(localStorage.getItem(EXPANDED_ROOTS_KEY) || '[]');
        return new Set(Array.isArray(roots) ? roots.filter(root => typeof root === 'string') : []);
      } catch {
        return new Set();
      }
    }
    const expandedRoots = loadExpandedRoots();
    function persistExpandedRoots() {
      localStorage.setItem(EXPANDED_ROOTS_KEY, JSON.stringify([...expandedRoots]));
    }
    function toggleExpandedRoot(root) {
      if (expandedRoots.has(root)) expandedRoots.delete(root);
      else expandedRoots.add(root);
      persistExpandedRoots();
    }
    function expandRoot(root) {
      if (expandedRoots.has(root)) return;
      expandedRoots.add(root);
      persistExpandedRoots();
    }
    const subrepoOpen = new Map();   // `${root}::${subrepo}` → bool (펼침). 미설정이면 attached=펼침 기본.
    let selectedProjectId = localStorage.getItem('marinaSelectedProject') || null;
    let switcherOpen = false;
    const AGENT_INBOX_READ_KEY = 'marinaAgentInboxRead';
    const AGENT_STATUS_META = {
      working:   { dot: 'boot', label: '작업 중', title: '에이전트가 현재 작업 중' },
      waiting:   { dot: 'part', label: '응답 대기', title: '응답을 마치고 다음 입력을 기다리는 중' },
      completed: { dot: 'run',  label: '완료', title: '작업을 마치고 세션이 종료됨' },
      failed:    { dot: 'bad',  label: '실패', title: '작업이 오류 또는 중단으로 끝남' },
      idle:      { dot: 'stop', label: '유휴', title: '현재 상태를 확인할 이벤트가 없음' },
    };
    let agentInboxOpen = false;
    function loadAgentInboxRead() {
      try {
        const ids = JSON.parse(localStorage.getItem(AGENT_INBOX_READ_KEY) || '[]');
        return new Set(Array.isArray(ids) ? ids.filter(id => typeof id === 'string') : []);
      } catch { return new Set(); }
    }
    const agentInboxRead = loadAgentInboxRead();
    function agentInboxEventId(agent) {
      return `${agent.source || ''}:${agent.sid || ''}:${agent.status || 'idle'}:${agent.statusTs || agent.ts || 0}`;
    }
    function agentInboxEntries() {
      const actionable = new Set(['waiting', 'completed', 'failed']);
      const entries = [];
      for (const wt of worktreeData) {
        for (const agent of (wt.agents || [])) {
          if (!agent.sid || !actionable.has(agent.status)) continue;
          entries.push({ ...agent, root: wt.root, projectId: wt.projectId,
            projectLabel: wt.projectLabel || wt.projectId || 'Project', eventId: agentInboxEventId(agent) });
        }
      }
      return entries.sort((a, b) => Number(b.statusTs || b.ts || 0) - Number(a.statusTs || a.ts || 0)).slice(0, 50);
    }
    function persistAgentInboxRead() {
      localStorage.setItem(AGENT_INBOX_READ_KEY, JSON.stringify([...agentInboxRead].slice(-300)));
    }
    function markAgentInboxRead(eventId) {
      agentInboxRead.add(eventId);
      persistAgentInboxRead();
    }
    function openAgentInboxItem(eventId) {
      const entry = agentInboxEntries().find(item => item.eventId === eventId);
      if (!entry) return;
      markAgentInboxRead(eventId);
      agentInboxOpen = false;
      selectedProjectId = entry.projectId || selectedProjectId;
      if (selectedProjectId) localStorage.setItem('marinaSelectedProject', selectedProjectId);
      render();
      if (typeof openAgentTerminal === 'function') openAgentTerminal(entry.root, entry);
    }
    function renderAgentInbox() {
      const button = document.getElementById('agentInboxBtn');
      const count = document.getElementById('agentInboxCount');
      const panel = document.getElementById('agentInboxPanel');
      if (!button || !count || !panel) return;
      const entries = agentInboxEntries();
      const unread = entries.filter(item => !agentInboxRead.has(item.eventId)).length;
      count.hidden = unread === 0;
      count.textContent = unread > 99 ? '99+' : String(unread);
      button.classList.toggle('has-unread', unread > 0);
      button.title = unread ? `에이전트 Inbox · 새 작업 ${unread}개` : '에이전트 Inbox';
      button.setAttribute('aria-expanded', agentInboxOpen ? 'true' : 'false');
      panel.hidden = !agentInboxOpen;
      if (!agentInboxOpen) return;
      let lastProject = null;
      panel.innerHTML = entries.length ? entries.map(item => {
        const project = item.projectLabel || 'Project';
        const group = project !== lastProject ? `<div class="agent-inbox-group">${escapeHtml(project)}</div>` : '';
        lastProject = project;
        const meta = AGENT_STATUS_META[item.status] || AGENT_STATUS_META.idle;
        const read = agentInboxRead.has(item.eventId);
        return `${group}<button class="agent-inbox-item${read ? ' read' : ' unread'}" data-agent-inbox-id="${escapeHtml(item.eventId)}">
          <span class="wt-dot ${meta.dot}" aria-hidden="true"></span>
          <span class="agent-src ${item.source === 'codex' ? 'codex' : 'claude'}">${item.source === 'codex' ? 'CX' : 'CC'}</span>
          <span class="agent-inbox-copy"><b>${escapeHtml(item.title || item.sid)}</b><small>${escapeHtml(meta.label)} · ${escapeHtml(relTime(item.statusTs || item.ts))}</small></span>
        </button>`;
      }).join('') : '<div class="agent-inbox-empty">확인할 에이전트 작업이 없습니다.</div>';
      panel.querySelectorAll('[data-agent-inbox-id]').forEach(item => {
        item.onclick = event => { event.stopPropagation(); openAgentInboxItem(item.dataset.agentInboxId); };
      });
    }

    document.getElementById('agentInboxBtn').onclick = event => {
      event.stopPropagation();
      agentInboxOpen = !agentInboxOpen;
      renderAgentInbox();
    };
    document.addEventListener('click', event => {
      if (agentInboxOpen && !event.target.closest('#agentInboxWrap')) { agentInboxOpen = false; renderAgentInbox(); }
    });

    // 인라인 토스트 — 네이티브 alert 대체(R5, Orca 톤). kind: 'ok' | 'err' | '' (기본=info). 3s 후 자동 소멸.
    function showToast(msg, kind) {
      let box = document.getElementById('marinaToast');
      if (!box) {
        box = document.createElement('div');
        box.id = 'marinaToast';
        box.className = 'marina-toast';
        document.body.appendChild(box);
      }
      const item = document.createElement('div');
      item.className = 'marina-toast-item' + (kind ? ' ' + kind : '');
      item.textContent = msg;
      box.appendChild(item);
      setTimeout(() => {
        item.classList.add('out');
        setTimeout(() => item.remove(), 200);
      }, 3000);
    }

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
      if (typeof connFollowProject === 'function') connFollowProject();   // 연결 탭이 새 프로젝트를 따라가게(app-9)
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

    // 워크벤치 모드(.workbench, 넓은 폭·고정 높이) = compose 에디터가 보일 때만.
    // composeSection 가시성을 바꾸는 모든 경로에서 호출 — subrepos 편집('new' 뷰지만 compose 아님) 등 오적용 방지.
    // composeSection 은 이제 #registerWorkbench2b(app-2b) 안에 이동돼 있어 — 이 함수가 그 래퍼의 hidden 도 같이 맞춘다.
    function syncRegisterWorkspace() {
      const on = !document.getElementById('composeSection').hidden;
      document.getElementById('registerPanel').classList.toggle('workbench', on);
      const wb = document.getElementById('registerWorkbench2b');
      if (wb) wb.hidden = !on;
    }

    // 진입 경로(R1): [팀원 설정 받았어요(붙여넣기)] · [처음 설정해요(레포 후보 → 워크벤치)]
    function setRegisterView(view) {   // 'entry' | 'candidates' | 'new' | 'paste'
      document.getElementById('registerEntry').hidden = view !== 'entry';
      document.getElementById('registerPaste').hidden = view !== 'paste';
      document.getElementById('registerCandidates').hidden = view !== 'candidates';
      const pathOn = view === 'new';
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
    document.getElementById('headerRegister').onclick = () => openRegisterPanel();

    document.getElementById('entryPaste').onclick = () => openPasteImport();
    document.getElementById('entryNew').onclick = () => openCandidates();   // app-2e-entry.js

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

    // 이미 등록된 compose 프로젝트의 보관 docker-compose.yml 편집 (카드 ✎). 저장 = compose-register upsert(덮어쓰기).
    // 실제 화면(2열 워크벤치)·로딩·초안 복원은 app-2b-workbench.js 의 openWorkbench 가 담당.
    async function openComposeEdit(root) {
      openWorkbench({ root, mode: 'edit' });
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
      } else if (browseMode === 'paste') {
        document.getElementById('pastePath').value = browseCurrent;
      } else if (browseMode === 'candidates') {
        document.getElementById('candPath').value = browseCurrent;
      } else {
        document.getElementById('registerPath').value = browseCurrent;
        if (!document.getElementById('composeSection').hidden && typeof wbOnPathChanged === 'function') wbOnPathChanged();
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
      if (compose) document.getElementById('registerPreview').hidden = true;
    }

    // 구 서브레포 스캐폴드 rail(renderComposeSubrepos·makeSubrepoRow·openComposeSubBrowse·externalMount·showDockerfilePicker)은
    // 제거 — 기능은 좌측 재료 서랍(app-2b-workbench.js, data-wb-materials)으로 흡수(스펙 R2 M3). 아래 두 삽입 헬퍼는 재료 서랍이 재사용.
    function appendComposeService(block) {
      const ed = document.getElementById('composeYaml');
      let cur = ed.value.replace(/\s+$/, '');
      if (!/^services:/m.test(cur)) cur = (cur ? cur + '\n' : '') + 'services:';
      setComposeYaml(cur + '\n' + block.replace(/\s+$/, '') + '\n');   // 하이라이트·line# 갱신 경유
    }
    function appendComposeInclude(p, srcComment) {   // 서브레포 자체 compose 를 top-level include: 로 (중복 방지). srcComment(선택) — 재료 서랍 출처 주석 줄, 반환값=실제 삽입 여부
      const ed = document.getElementById('composeYaml');
      let cur = ed.value.replace(/\s+$/, '');
      const esc = p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      if (new RegExp('^\\s*-\\s*' + esc + '\\s*$', 'm').test(cur)) return false;   // 이미 있음
      const line = (srcComment ? '  ' + srcComment + '\n' : '') + '  - ' + p + '\n';
      if (/^include:/m.test(cur)) cur = cur.replace(/^include:[^\n]*\n/m, (m) => m + line);
      else cur = 'include:\n' + line + cur;
      setComposeYaml(cur.replace(/\s+$/, '') + '\n');   // 하이라이트·line# 갱신 경유
      return true;
    }
