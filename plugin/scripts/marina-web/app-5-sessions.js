    // app-5-sessions.js — 세션 카드 골격(P4 분할 1/3): 상태 모델·render()·updateServiceStates()·서비스 트리.
    // 액션(hover 버튼·⋯메뉴·정지/삭제 플로우)은 app-5b-actions.js, 구성 모달은 app-5c-config.js(둘 다 이 파일 다음 로드).
    // 전역 스코프 — 함수 선언이라 로드 순서 무관(호출은 전부 이벤트 시점). 함수 이동만, 로직 변경 없음.

    function isInternalService(svc) {   // 엮기 forward 사이드카(<svc>-bind)·내부 표식 — 사용자 대상 서비스가 아니므로 카드에서 숨김
      return svc.internal === true || /-bind$/.test(svc.service || '');
    }
    function visibleServices(session) { return (session.services || []).filter(svc => !isInternalService(svc)); }

    // ── AGENTS 섹션 (A1) — 이 워크트리에서 도는 Claude/Codex 세션 가시화. SERVICES 와 완전 동일 문법(형 통일 지시):
    // 접힘도 카드 펼침(expandedRoots)을 그대로 따르고, 행 클릭 = 대화 내용 뷰어(openAgentTranscript).
    function agentActive(ts) {   // 최근 2분 이내 활동 — ⟳ boot 아크(서비스 '기동중' 재사용)
      return !!ts && (Date.now() / 1000 - ts) < 120;
    }
    function agentsSummary(agents) {   // 접힘 요약 — 활성 개수만(0 이면 빈칸, SERVICES stateCounts 와 같은 톤)
      const active = (agents || []).filter(a => agentActive(a.ts)).length;
      return active ? `<span class="c-boot">⟳ ${active}</span>` : '';
    }
    function renderAgentRow(agent) {   // 상태점 + source 텍스트칩(CC/CX, 이모지 금지) + title + 우측 relTime, 아래 preview(.svc-tail 재사용)
      const active = agentActive(agent.ts);
      const isCodex = agent.source === 'codex';
      const openable = !!agent.sid;   // transcript 식별자 있어야 열람 가능(만료·구버전 rollout 은 표시만)
      return `
        <div class="svc nested agent-row${openable ? '' : ' disabled'}" data-agent-row data-agent-ts="${agent.ts}"${openable ? ` data-agent-sid="${escapeHtml(agent.sid)}" data-agent-source="${escapeHtml(agent.source)}"` : ''}
          title="${openable ? '클릭하면 이 세션의 대화 내용(끝부분)을 열어요' : '대화 원본을 못 찾음 — 표시만'}">
          <span class="wt-dot ${active ? 'boot' : 'stop'}" title="${active ? '최근 2분 내 활동' : '비활성'}"></span>
          <span class="agent-src ${isCodex ? 'codex' : 'claude'}">${isCodex ? 'Codex' : 'Claude'}</span>
          <span class="svc-name"><span title="${escapeHtml(agent.title)}">${escapeHtml(agent.title)}</span></span>
          <span class="svc-right">
            <span class="mono-port svc-uptime" data-agent-relts>${escapeHtml(relTime(agent.ts))}</span>
          </span>
          ${agent.preview ? `<span class="svc-tail" title="${escapeHtml(agent.preview)}">${escapeHtml(agent.preview)}</span>` : ''}
        </div>`;
    }

    // ── 상태 모델 (콘솔 스펙 D5) — 백엔드 정규화 svc.state 소비. 구 payload(state 없음) 폴백 파생 포함. ──
    const STATE_META = {
      running:  { dot: 'run',  icon: '▶', label: '실행',   title: 'HTTP 응답 확인됨 — 사용 가능' },
      starting: { dot: 'boot', icon: '⟳', label: '기동중', title: 'prebuild·이미지 빌드 포함 — 첫 시작은 몇 분 걸릴 수 있어요. 끝나면 자동 갱신됩니다.' },
      partial: { dot: 'part', icon: '◐', label: '일부 실행', title: '일부 서비스만 실행 중 — ▶ 로 나머지 시작' },   // 카드 전용(개별 서비스엔 없음)
      error:    { dot: 'bad',  icon: '✕', label: '오류',   title: '실패 — 원인 줄과 로그를 확인하세요' },
      stopped:  { dot: 'stop', icon: '■', label: '꺼짐',   title: '정지됨' },
      external: { dot: 'ext',  icon: '⇄', label: '외부',   title: 'marina 컨테이너가 아닌 외부 프로세스(IDE·터미널 직접 실행)가 포트를 점유 중' },
      degraded: { dot: 'boot', icon: '⚠', label: '비활성', title: 'Dockerfile 없음 — 이 서비스만 기동에서 건너뜁니다(나머지는 정상)' },
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
    // 상태 집계 분모 — x-marina.startGroup 선언 시, 옵션(시작 그룹 밖) 서비스는 꺼져 있는 동안 계산에서 제외.
    // 손으로 켰거나(running) 켰다 죽은(error) 옵션은 포함 — 산 것/죽은 것은 언제나 진실을 말한다.
    function countedServices(services) {
      return services.filter(s => s.inStartGroup !== false || svcState(s) !== 'stopped');
    }
    function cardState(services) {           // worktree 종합 점 — 에러>기동중(스핀)>일부실행(정적 ◐)>전부실행>정지
      const st = countedServices(services).map(svcState);
      if (!st.length) return 'stopped';
      if (st.includes('error')) return 'error';
      if (st.includes('starting')) return 'starting';
      const live = st.filter(s => s === 'running' || s === 'external').length;
      if (live === 0) return 'stopped';
      return live === st.length ? 'running' : 'partial';   // 일부 실행 — 진행중(스핀)과 구분되는 안정 상태
    }
    function stateCounts(services) {         // 접힘 요약 (콘솔 스펙 D4) — 상태별 카운트, 0 은 생략 (옵션 정지분 제외)
      const c = {};
      for (const s of countedServices(services).map(svcState)) c[s] = (c[s] || 0) + 1;
      const order = [['running', 'c-run'], ['starting', 'c-boot'], ['error', 'c-err'], ['external', 'c-ext'], ['degraded', 'c-boot'], ['stopped', 'c-stop']];
      return order.filter(([k]) => c[k]).map(([k, cls]) => `<span class="${cls}">${STATE_META[k].icon} ${c[k]}</span>`).join(' · ');
    }
    // 액션 문법 (콘솔 스펙 D7) — 토글 1개(▶/⏹) + ↻ 는 실행중만. 불가능한 액션은 항목 자체가 없음.
    function svcActions(svc) {
      const st = svcState(svc);
      if (st === 'starting') return [{ act: 'stop', icon: '⟳', title: '기동 중 — 클릭하면 정지(취소)' }];
      if (st === 'external') return [{ act: 'stop-external', icon: '⏹', title: '외부 프로세스 정지 (SIGTERM) — marina 로 관리하려면 종료 후 ▶' }];
      if (st === 'running') return [{ act: 'stop', icon: '⏹', title: '정지' }, { act: 'restart', icon: '↻', title: '재시작 — 변경분(빌드/설정) 반영해 재기동' }];
      if (st === 'degraded') return [];
      return [{ act: 'start', icon: '▶', title: st === 'error' ? '재시도(시작)' : '시작 — 호스트 포트는 자동 격리' }];
    }
    function cardActions(services) {         // 카드 토글 — 전부실행=⏹, 전부정지=▶, 섞임(일부 정지/실패)=▶(나머지)+⏹
      const st = countedServices(services).map(svcState);   // 옵션 정지분은 '나머지'로 안 침
      const hasGroup = services.some(s => s.inStartGroup === false);   // startGroup 선언된 프로젝트
      const startTitle = hasGroup ? '시작 그룹 시작 — x-marina.startGroup 선언분만 (옵션은 행에서 개별 ▶)'
                                 : '전체 시작 — compose 서비스 전부 시작(필요 시 attach·pre-build·재빌드)';
      const anyLive = st.some(s => ['running', 'starting', 'external'].includes(s));
      const anyDown = st.some(s => s === 'stopped' || s === 'error');
      if (anyLive && anyDown) return [
        { act: 'start-all', icon: '▶', title: '나머지 시작 — 정지/실패 서비스만 기동(실행 중은 그대로)' },
        { act: 'stop-all', icon: '⏹', title: '전체 정지 — 이 세션의 서비스 전부 정지' },
      ];
      return anyLive ? [{ act: 'stop-all', icon: '⏹', title: '전체 정지 — 이 세션의 서비스 전부 정지' }]
                     : [{ act: 'start-all', icon: '▶', title: startTitle }];
    }
    function portText(svc) {                 // 내부→호스트 표기 (콘솔 스펙 D6) — 상태별 대체 텍스트
      const st = svcState(svc);
      if (st === 'starting') return svc.busy === 'restart' ? 'restarting…' : 'starting…';
      if (st === 'error') return svc.busyError ? 'failed' : (svc.exitCode ? `exit ${svc.exitCode}` : 'unhealthy');
      if (st === 'degraded') return '';
      if ((svc.port ?? '') === '') return '';
      return svc.targetPort ? `${svc.targetPort}→${svc.port}` : `:${svc.port}`;
    }
    function portTitle(svc) {
      if (!svc.port) return '';
      return svc.targetPort
        ? `컨테이너 ${svc.targetPort} → 호스트 ${svc.port} (자동할당·재시작마다 변동) — 클릭=복사`
        : `호스트 포트 ${svc.port} — 클릭=복사`;
    }
    function relTime(ts) {                   // 로그 mtime → '지금/3분/2시간/5일' (행 우측 상대시간)
      if (!ts) return '';
      const s = Math.max(0, Date.now() / 1000 - ts);
      if (s < 90) return '지금';
      if (s < 3600) return `${Math.round(s / 60)}분`;
      if (s < 86400) return `${Math.round(s / 3600)}시간`;
      return `${Math.round(s / 86400)}일`;
    }
    function tailVisible(svc) {              // 미리보기 1줄 — 살아있는(또는 죽어가는) 서비스만, 정지 상태의 옛 로그는 노이즈
      return !!svc.logTail && ['running', 'starting', 'error', 'external'].includes(svcState(svc));
    }

    function shortPath(path) {
      return path.replace(/^\/(?:Users|home)\/[^/]+/, '~');  // macOS·Linux 홈 단축
    }
    function tailPath(path) {   // 카드 root 줄 — 끝 2세그먼트만(정보값은 꼬리에), 전체는 툴팁
      const parts = shortPath(path).split('/');
      return parts.length <= 3 ? parts.join('/') : '…/' + parts.slice(-2).join('/');
    }
    function dominantBranch(wt) {   // 레포들 중 최다 브랜치 — 카드 대표(미러 관례상 보통 전부 동일)
      const vals = Object.values(wt?.branches || {});
      if (!vals.length) return '';
      const freq = {};
      for (const b of vals) freq[b] = (freq[b] || 0) + 1;
      return Object.entries(freq).sort((a, b) => b[1] - a[1])[0][0];
    }

    // ── 카드 수동 순서 (D&D) — 프로젝트별 localStorage. 자동 정렬 없음: 새 카드는 그룹 뒤에 붙고, 위치는 내가 정함. ──
    let cardDragRoot = null;
    function cardOrderKey() { return 'marinaCardOrder:' + (selectedProjectId || ''); }
    function cardOrderLoad() {
      try { const v = JSON.parse(localStorage.getItem(cardOrderKey()) || '[]'); return Array.isArray(v) ? v : []; } catch { return []; }
    }
    function cardOrderSaveFromDom() {   // 현재 렌더 순서(비-main 카드의 root 나열)를 그대로 저장 — 미배치 카드도 이때 자리 확정
      const roots = [...document.querySelectorAll('.sessions .session:not(.is-main)')].map(c => c.dataset.root);
      localStorage.setItem(cardOrderKey(), JSON.stringify(roots));
    }
    function cardDropClear() {
      document.querySelectorAll('.session.drop-above, .session.drop-below').forEach(c => c.classList.remove('drop-above', 'drop-below'));
    }
    function wireCardDrag(card, session) {   // main 제외 카드 D&D — 같은 소스 그룹 안 재배열(렌더가 그룹핑을 다시 적용)
      card.draggable = true;
      card.addEventListener('dragstart', (e) => {
        if (e.target.closest('input, button, textarea, a, select')) { e.preventDefault(); return; }   // 위젯 드래그 오발 방지
        cardDragRoot = session.root;
        e.dataTransfer.effectAllowed = 'move';
        card.classList.add('dragging');
      });
      card.addEventListener('dragend', () => { cardDragRoot = null; card.classList.remove('dragging'); cardDropClear(); });
      card.addEventListener('dragover', (e) => {
        if (!cardDragRoot || cardDragRoot === session.root) return;
        e.preventDefault();
        e.dataTransfer.dropEffect = 'move';
        const r = card.getBoundingClientRect();
        const before = e.clientY < r.top + r.height / 2;
        card.classList.toggle('drop-above', before);
        card.classList.toggle('drop-below', !before);
      });
      card.addEventListener('dragleave', () => card.classList.remove('drop-above', 'drop-below'));
      card.addEventListener('drop', (e) => {
        if (!cardDragRoot || cardDragRoot === session.root) return;
        e.preventDefault();
        const r = card.getBoundingClientRect();
        const before = e.clientY < r.top + r.height / 2;
        const src = document.querySelector(`.sessions .session[data-root="${CSS.escape(cardDragRoot)}"]`);
        if (src) { card.parentNode.insertBefore(src, before ? card : card.nextSibling); cardOrderSaveFromDom(); }
        cardDropClear();
        render();   // 그룹 경계 넘긴 드롭은 렌더가 소스 그룹핑으로 되돌림(순서만 반영)
      });
    }

    // ── CC/CX 소스 필터 세그먼트 (형 피드백 2026-07-13 — 클로드/코덱스 나눠 보기, 기본은 묶음) ──
    let wtSourceFilter = localStorage.getItem('marinaWtSource') || 'all';
    function renderSourceTabs(counts) {
      const el = document.getElementById('wtSourceTabs');
      if (!el) return;
      const both = counts.claude > 0 && counts.codex > 0;
      el.hidden = !both;   // 한 종류뿐이면 세그먼트가 노이즈 — 숨기고 전체 표시
      if (!both) { wtSourceFilter = 'all'; return; }
      const defs = [['all', `전체 ${counts.claude + counts.codex}`], ['claude', `Claude ${counts.claude}`], ['codex', `Codex ${counts.codex}`]];
      el.innerHTML = defs.map(([k, label]) =>
        `<button data-src="${k}" class="${wtSourceFilter === k ? 'on' : ''}">${label}</button>`).join('');
      el.querySelectorAll('button').forEach(b => b.onclick = () => {
        wtSourceFilter = b.dataset.src;
        localStorage.setItem('marinaWtSource', wtSourceFilter);
        render();
      });
    }

    function attachSummary(session, wt) {      // attach n/m (worktree 카드만 — main 은 생략)
      if (!wt || wt.isMain || !(wt.subrepos || []).length) return '';
      return `attach ${(wt.attachedSubrepos || []).length}/${wt.subrepos.length}`;
    }
    function metaTime(wt) {                    // 우측 시간 메타 — idleDays 기반
      if (!wt || wt.idleDays == null) return '';
      return wt.idleDays < 1 ? '오늘' : `${Math.round(wt.idleDays)}d`;
    }
    function gatewayLine(session) {            // 카드 하단 대표 URL (콘솔 스펙 D3 고정 슬롯) — primary(web) 우선
      const svcs = visibleServices(session);
      const prim = svcs.find(s => /^(web|fe|front)/.test(s.service)) || svcs[0];
      const url = prim && gatewayUrlFor(session, prim);
      return url ? `<a href="${url}" target="_blank" rel="noopener" title="게이트웨이 — 호스트 브라우저로 열기">${escapeHtml(url.replace(/^https?:\/\//, '').replace(/\/$/, ''))} ↗</a>` : '';
    }

    function updateServiceStates() {   // 부분 패치 경로 — render() 와 같은 DOM 계약(wt-dot·sect-counts·mono-port·hov-acts)
      for (const session of sessions) {
        const card = document.querySelector(`[data-root="${CSS.escape(session.root)}"]`);
        if (!card) continue;
        const services = visibleServices(session);
        const headDot = card.querySelector('.session-head .wt-dot');
        if (headDot) headDot.className = `wt-dot ${STATE_META[cardState(services)].dot}`;
        const counts = card.querySelector('.sect-counts');
        if (counts) counts.innerHTML = card.classList.contains('collapsed') ? stateCounts(services) : '';
        const whySlot = card.querySelector('[data-why-slot]');
        if (whySlot) { whySlot.innerHTML = whyLines(session); wireWhyLinks(whySlot, session); }
        const cardActs = card.querySelector('[data-card-acts]');
        if (cardActs && !cardActs.querySelector('button:disabled')) fillCardActs(cardActs, session, services);
        for (const svc of session.services) {
          const row = card.querySelector(`[data-service-key="${CSS.escape(`${session.root}::${svc.service}`)}"]`);
          if (!row) continue;
          if (row.classList.contains('disabled')) continue;   // 미attach subrepo 의 서비스 — 라이브 상태로 덮지 않음
          const st = svcState(svc);
          const dot = row.querySelector('.wt-dot');
          if (dot) { dot.className = `wt-dot ${STATE_META[st].dot}`; dot.title = STATE_META[st].title; }
          const port = row.querySelector('[data-port]');
          if (port) { port.textContent = portText(svc); port.title = portTitle(svc); }
          const rss = row.querySelector('[data-rss]');
          if (rss) rss.textContent = svc.running && svc.rssMb ? `${svc.rssMb}MB` : '';
          const up = row.querySelector('[data-uptime]');
          if (up) up.textContent = svc.running ? relTime(svc.logTs) : '';
          const tail = row.querySelector('[data-tail]');
          if (tail) tail.textContent = tailVisible(svc) ? svc.logTail : '';
          const acts = row.querySelector('[data-svc-acts]');
          if (acts && !acts.querySelector('button:disabled')) fillSvcActs(acts, session, svc);
        }
        // A1 — AGENTS 행은 preview 를 다시 쓰지 않는다(정적, 60s worktrees 폴링에서만 갱신) — ts/뱃지/접힘요약만 이 5s 틱에서 신선하게.
        const wt = worktreeData.find(w => w.root === session.root);
        const agents = wt?.agents || [];
        if (agents.length) {
          const agentsCounts = card.querySelector('[data-agents-counts]');
          if (agentsCounts) agentsCounts.innerHTML = expandedRoots.has(session.root) ? '' : agentsSummary(agents);
          card.querySelectorAll('[data-agent-row]').forEach(row => {
            const ts = Number(row.dataset.agentTs) || 0;
            const active = agentActive(ts);
            const dot = row.querySelector('.wt-dot');
            if (dot) dot.className = `wt-dot ${active ? 'boot' : 'stop'}`;
            const relEl = row.querySelector('[data-agent-relts]');
            if (relEl) relEl.textContent = relTime(ts);
          });
        }
      }
      renderSelection();
    }

    // R5 — compose-register/import 성공 직후 app-2 가 세팅 → 여기서 소비해 해당 main 카드를 2s 하이라이트.
    let pendingFlashProjectId = null;
    // A4 — 워크트리 생성 성공 직후 app-5d 가 세팅 → root 로 새 카드(main 아님)를 2s 하이라이트.
    let pendingFlashRoot = null;

    function render() {
      const sessionsEl = document.getElementById('sessions');
      sessionsEl.innerHTML = '';

      const wtByRoot = new Map(worktreeData.map(w => [w.root, w]));
      // 등록 프로젝트 목록 — 선택 보정(선택이 사라졌으면 첫 프로젝트로 폴백)
      const projectIds = [...new Set(worktreeData.map(w => w.projectId))];
      if (selectedProjectId && !projectIds.includes(selectedProjectId)) selectedProjectId = null;
      if (!selectedProjectId && projectIds.length) selectedProjectId = projectIds[0];
      renderSwitcher();
      // 빈 레지스트리(R1) — 모달을 강제로 열지 않고 #sessions 안에 대문 CTA 카드로 안내. 첫 worktree 로드 완료 후에만(로딩 중 스퓨리어스 방지)
      if (worktreesLoaded && !projectIds.length) {
        sessionsEl.innerHTML = `
          <div class="empty-cta">
            <div class="empty-cta-title">프로젝트를 등록하고 시작하세요</div>
            <div class="empty-cta-sub">compose 표준 문서 하나로 워크트리를 관리해요.</div>
            <div class="empty-cta-actions">
              <button id="emptyCtaPaste" class="register-entry-card" title="팀원이 공유한 compose+x-marina 블록을 붙여넣어 한 번에 재현">
                <span class="register-entry-ic">📋</span>
                <span class="register-entry-text"><b>팀원 설정 받았어요</b><em>공유 블록을 붙여넣어 한 번에 재현</em></span>
              </button>
              <button id="emptyCtaNew" class="register-entry-card" title="처음 만드는 사람 — 레포 후보를 고르고 워크벤치에서 compose 를 직접 완성합니다">
                <span class="register-entry-ic">🆕</span>
                <span class="register-entry-text"><b>처음 설정해요</b><em>레포를 고르고 워크벤치에서 직접 만들어요</em></span>
              </button>
            </div>
          </div>`;
        document.getElementById('emptyCtaPaste').onclick = () => { openRegisterPanel(); openPasteImport(); };
        document.getElementById('emptyCtaNew').onclick = () => { openRegisterPanel(); openCandidates(); };
        return;
      }
      // 선택 프로젝트로 스코프 — project-group 스태킹 대체 (세로 카드 목록 그대로)
      const scopedSessions = sessions.filter(s => wtByRoot.get(s.root)?.projectId === selectedProjectId);
      const isMainOf = (s) => (s.source === 'main' || wtByRoot.get(s.root)?.isMain) ? 1 : 0;
      // Claude/Codex 소스 필터+그룹 — 두 종류가 섞여 있을 때만 세그먼트·그룹 라벨 노출. main 카드는 항상 표시.
      const srcCounts = { claude: 0, codex: 0 };
      for (const s of scopedSessions) if (!isMainOf(s) && srcCounts[s.source] != null) srcCounts[s.source] += 1;
      renderSourceTabs(srcCounts);
      const bothSources = srcCounts.claude > 0 && srcCounts.codex > 0;
      // 정렬: main 고정 상단 → 소스 그룹(Claude→Codex) → 그룹 안은 "내가 정한 순서"(D&D, localStorage).
      // 자동(최근순) 정렬은 폐지 — 카드가 스스로 움직이면 위치 기억이 무효(형). 미배치 카드는 뒤에 추가(안정 정렬).
      const srcRank = (s) => isMainOf(s) ? 0 : s.source === 'claude' ? 1 : s.source === 'codex' ? 2 : 3;
      const savedOrder = cardOrderLoad();
      const orderIdx = (s) => { const i = savedOrder.indexOf(s.root); return i === -1 ? Infinity : i; };
      scopedSessions.sort((a, b) => (isMainOf(b) - isMainOf(a)) || (srcRank(a) - srcRank(b)) || (orderIdx(a) - orderIdx(b)));
      const visibleScoped = scopedSessions.filter(s =>
        wtSourceFilter === 'all' || isMainOf(s) || s.source === wtSourceFilter);
      const SRC_LABEL = { claude: 'Claude', codex: 'Codex' };
      let prevSrcGroup = null;
      for (const session of visibleScoped) {
        // 전체 뷰 그룹 라벨 — main 이후 소스가 바뀌는 지점마다 (Claude (7) / Codex (2))
        if (bothSources && wtSourceFilter === 'all' && !isMainOf(session)) {
          const g = SRC_LABEL[session.source] ? session.source : 'etc';
          if (g !== prevSrcGroup) {
            prevSrcGroup = g;
            const label = document.createElement('div');
            label.className = 'src-group-label';
            label.innerHTML = `<span class="src-chip ${g}">${SRC_LABEL[g] || '기타'}</span><span class="src-cnt">${srcCounts[g] ?? ''}</span>`;
            sessionsEl.appendChild(label);
          }
        }
        const card = document.createElement('div');
        const isExpanded = expandedRoots.has(session.root);
        const wt = wtByRoot.get(session.root);
        // 위험 신호만 칩으로 — 정보성 깃 지표(✎·+·↑)와 캐시는 깃/변경 탭·⋯ 메뉴로 이동(카드 다이어트, 형 피드백 2026-07-13)
        const riskPills = [];
        // 카드 제목 = alias → Claude 세션 타이틀 → 최신 커밋 제목 → 해시. 해시는 제목과 다를 때만 보조줄로.
        // main 체크아웃은 "작업 세션"이 아니라 통합본 → 커밋제목 폴백 없이 'main'(id) 유지.
        const isMainCard = session.source === 'main' || wt?.isMain;
        const displayTitle = session.alias || (isMainCard ? '' : (wt?.sessionTitle || wt?.headSubject)) || session.id;
        const showSub = displayTitle !== session.id;
        if (wt && !wt.isMain && wt.verdict === 'stale') {
          riskPills.push('<span class="pill-stat danger" title="clean · 미머지 0 · 7일↑ 미활동 — 지워도 안전">삭제 권장</span>');
        }
        // 브랜치는 카드에서 뺀다(형 확정 2026-07-13) — 깃 탭이 담당(레인 칩·필터). 카드엔 "불일치 경고"만 칩으로,
        // 클릭하면 깃 탭을 그 워크트리 브랜치로 필터해 연다. (미러 관례상 브랜치명은 id 파생 = 중복 소음이었음)
        const domBranch = dominantBranch(wt);
        const offMain = (session.source === 'main') && Object.values(wt?.branches || {}).some(branch => branch !== 'main');
        // 대표와 다른 레포 목록 — "루트만 다름"(root=claude/<id>, 서브레포=feature/x 관례)은 정상이라 경고 제외
        const offRepos = Object.entries(wt?.branches || {}).filter(([, b]) => b !== domBranch).map(([r]) => r);
        const mixed = offRepos.length > 0 && !(offRepos.length === 1 && offRepos[0] === wt?.projectLabel);
        const fullMap = Object.entries(wt?.branches || {}).map(([repo, branch]) => `${repo}=${branch}`).join(' · ');
        if (mixed || offMain) {
          riskPills.push(`<button class="pill-stat danger" data-branch-git title="체크아웃 브랜치 — ${escapeHtml(fullMap)} · 커밋이 의도와 다른 곳으로 갈 수 있음. 클릭=깃 탭">⚠ 브랜치 불일치 ⎇</button>`);
        }
        const subBits = showSub ? [escapeHtml(session.id)] : [];
        if (session.webPortConflictWith?.length) {
          const conflictText = `⚠ 포트 충돌: ${session.webPortConflictWith.map(escapeHtml).join(', ')}`;
          riskPills.push(`<span class="pill-stat danger" title="다른 세션과 포트가 겹칩니다">${conflictText}</span>`);
        }
        // Orca 문법 카드 (콘솔 스펙 D3) — 상태점+제목+우측메타+hover 클러스터 / SERVICES 접힘 섹션 / 원인줄·URL 상시
        const services = visibleServices(session);
        const cst = cardState(services);
        const agents = wt?.agents || [];   // A1 — 이 워크트리의 Claude/Codex 세션 (백엔드가 최대 3개, ts 내림차순으로 이미 자름)
        const rightMeta = [attachSummary(session, wt), metaTime(wt)].filter(Boolean).join(' · ');
        const gwLine = gatewayLine(session);
        card.className = `session ${isExpanded ? '' : 'collapsed'}${isMainCard ? ' is-main' : ''}`;
        card.dataset.root = session.root;
        if (wt) card.dataset.projectId = wt.projectId;
        card.innerHTML = `
          <div class="session-head">
            <div class="session-title">
              <div class="session-main">
                <div class="alias-row">
                  <span class="wt-dot ${STATE_META[cst].dot}"></span>
                  <span class="alias-display" data-alias-display title="클릭해서 별칭 수정 (세션 타이틀 위에 덮어씀)">${escapeHtml(displayTitle)}</span>
                  <input class="alias-input" data-alias value="${escapeHtml(session.alias || '')}" placeholder="별칭" aria-label="session alias" title="별칭 — Enter 로 저장" hidden />
                </div>
                ${subBits.length ? `<div class="sid-sub">${subBits.join(' <span class="sub-sep">·</span> ')}</div>` : ''}
              </div>
              <span class="wt-right">${escapeHtml(rightMeta)}</span>
              <span class="hov-acts" data-card-acts></span>
            </div>
            ${riskPills.length ? `<div class="risk-row">${riskPills.join('')}</div>` : ''}
          </div>
          ${services.length ? `<div class="sect-label" data-sect-toggle>${isExpanded ? '▾' : '▸'} SERVICES (${services.length})
            <span class="sect-counts">${isExpanded ? '' : stateCounts(services)}</span></div>` : ''}
          <div class="svc-list"></div>
          ${agents.length ? `<div class="sect-label" data-agents-toggle title="이 워크트리에서 작업한 Claude/Codex 세션(최근 7일) — 라벨 클릭=펼치기(SERVICES 와 동일), 행 클릭=대화 열기">${isExpanded ? '▾' : '▸'} AGENTS (${agents.length})
            <span class="sect-counts" data-agents-counts>${isExpanded ? '' : agentsSummary(agents)}</span></div>
          <div class="svc-list agents-list"${isExpanded ? '' : ' hidden'}>${agents.map(renderAgentRow).join('')}</div>` : ''}
          <div data-why-slot>${whyLines(session)}</div>
          ${gwLine ? `<div class="card-url">${gwLine}</div>` : ''}
          <div class="root" title="${escapeHtml(session.root)}">${escapeHtml(tailPath(session.root))}</div>
        `;
        card.querySelector('.session-head').onclick = (event) => {
          if (event.target.closest('button,input,select,summary,details,[data-alias-display]')) return;
          if (expandedRoots.has(session.root)) expandedRoots.delete(session.root);
          else expandedRoots.add(session.root);
          render();
        };
        const aliasInput = card.querySelector('[data-alias]');
        aliasInput.onkeydown = (event) => {
          if (event.key === 'Enter') {
            event.preventDefault();
            aliasInput.blur();
          }
        };
        const aliasDisplay = card.querySelector('[data-alias-display]');
        aliasDisplay.onclick = () => {
          aliasDisplay.hidden = true;
          aliasInput.hidden = false;
          aliasInput.focus();
          aliasInput.select();
        };
        aliasInput.onblur = () => {
          if ((session.alias || '') !== aliasInput.value.trim()) {
            saveAlias(session, aliasInput).catch(alert);
          } else {
            aliasInput.hidden = true;
            aliasDisplay.hidden = false;
          }
        };
        const branchGitBtn = card.querySelector('[data-branch-git]');   // 불일치 칩 → 깃 탭(그 워크트리 브랜치 필터)
        if (branchGitBtn) branchGitBtn.onclick = (e) => { e.stopPropagation(); openGitTab(session.root, wt?.branches?.[wt?.projectLabel] || domBranch); };   // 깃 탭 기본 레포탭=root — root 레포 브랜치로 필터
        if (!isMainCard) wireCardDrag(card, session);   // 카드 순서는 D&D 로 내가 정함(main 은 고정)
        // hover 클러스터(토글+⋯) — 구 상시 스트립/툴바 대체 (콘솔 스펙 D7). link 진입은 ⋯ 메뉴로 이동(카드 다이어트)
        fillCardActs(card.querySelector('[data-card-acts]'), session, services);
        wireWhyLinks(card.querySelector('[data-why-slot]'), session);
        const sectToggle = card.querySelector('[data-sect-toggle]');
        if (sectToggle) sectToggle.onclick = (e) => {
          e.stopPropagation();
          if (expandedRoots.has(session.root)) expandedRoots.delete(session.root);
          else expandedRoots.add(session.root);
          render();
        };
        const agentsToggle = card.querySelector('[data-agents-toggle]');   // SERVICES 라벨과 동일 — 카드 펼침 토글(형 통일)
        if (agentsToggle) agentsToggle.onclick = (e) => {
          e.stopPropagation();
          if (expandedRoots.has(session.root)) expandedRoots.delete(session.root);
          else expandedRoots.add(session.root);
          render();
        };
        card.querySelectorAll('[data-agent-row][data-agent-sid]').forEach((row, i) => {   // 행 클릭 = 대화 뷰어(서비스 행=로그와 같은 문법)
          const agent = agents.filter(a => a.sid)[i];
          row.onclick = (e) => { e.stopPropagation(); if (typeof openAgentTranscript === 'function') openAgentTranscript(session, agent); };
        });
        renderServiceTree(card.querySelector('.svc-list'), session, wt);
        sessionsEl.appendChild(card);
      }
      const collapseBtn = document.getElementById('collapseAll');
      collapseBtn.textContent = expandedRoots.size ? '⇈' : '⇊';
      collapseBtn.dataset.tip = expandedRoots.size ? '세션 카드 모두 접기' : '세션 카드 모두 펼치기';
      if (pendingFlashProjectId) {   // R5 — 등록 직후 해당 main 카드 2s 하이라이트(1회성 — 소비 후 즉시 비움)
        const flashId = pendingFlashProjectId;
        pendingFlashProjectId = null;
        const target = sessionsEl.querySelector(`.session.is-main[data-project-id="${CSS.escape(flashId)}"]`);
        if (target) {
          target.classList.add('flash');
          setTimeout(() => target.classList.remove('flash'), 2000);
        }
      }
      if (pendingFlashRoot) {   // A4 — 워크트리 생성 직후 해당 카드(main 아님) 2s 하이라이트(1회성)
        const flashRoot = pendingFlashRoot;
        pendingFlashRoot = null;
        const target = sessionsEl.querySelector(`.session[data-root="${CSS.escape(flashRoot)}"]`);
        if (target) {
          target.classList.add('flash');
          setTimeout(() => target.classList.remove('flash'), 2000);
        }
      }
      renderSelection();
    }


    function renderSubrepoHead(name, o) {
      const chev = o.count ? `<span class="chev">${o.open ? '▾' : '▸'}</span>` : '<span class="chev"></span>';
      // 아이콘 토글 — attached→unlink(=detach 동작), detached→link(=attach 동작). Tabler link/unlink (MIT). 상태는 행 흐림(.detached)+아이콘으로 구분, 별도 칩 없음
      const UNLINK_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 14a3.5 3.5 0 0 0 5 0l4 -4a3.5 3.5 0 0 0 -5 -5l-.5 .5"/><path d="M14 10a3.5 3.5 0 0 0 -5 0l-4 4a3.5 3.5 0 0 0 5 5l.5 -.5"/><path d="M16 21v-2"/><path d="M19 16h2"/><path d="M3 8h2"/><path d="M8 3v2"/></svg>';
      const LINK_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 15l6 -6"/><path d="M11 6l.463 -.536a5 5 0 0 1 7.071 7.072l-.534 .464"/><path d="M13 18l-.397 .534a5.068 5.068 0 0 1 -7.127 0a4.972 4.972 0 0 1 0 -7.071l.524 -.463"/></svg>';
      // 핀 토글 — main 카드의 "기본"(새 worktree 자동 attach 대상) 체크박스 대체. on 이면 채워진 파란 핀
      const PIN_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 4v6l-2 4v2h10v-2l-2 -4v-6"/><path d="M12 16l0 5"/><path d="M8 4l8 0"/></svg>';
      let control = '';
      if (!o.inUniverse) {
        control = '<span class="subrepo-chip warn" title="서비스 cwd 가 가리키는 subrepo 가 레지스트리에 없음 — ⚙ 에서 등록하면 attach 가능">미등록</span>';
      } else if (o.isMain) {
        control = `<button class="subrepo-act icon default-toggle ${o.isDefault ? 'on' : ''}" data-default-toggle aria-label="기본 attach 대상" title="기본 — 새 worktree 자동 attach 대상(전체 기본). 끄면 새 worktree 부터 제외 (main 의 클론은 보존)">${PIN_ICON}</button>`;
      } else if (o.isAttached) {
        control = `<button class="subrepo-act icon" data-detach aria-label="detach" title="이 worktree 에서 detach (git worktree remove) — 브랜치·미머지 커밋은 보존">${UNLINK_ICON}</button>`;
      } else {
        control = `<button class="subrepo-act icon primary" data-attach aria-label="attach" title="이 worktree 에 attach (git worktree add) — 같은 이름 브랜치 있으면 재사용">${LINK_ICON}</button>`;
      }
      return `
        <div class="subrepo-main">
          ${chev}
          <span class="subrepo-name">${escapeHtml(name)}</span>
          ${o.count ? `<span class="subrepo-count">${o.count} svc</span>` : '<span class="subrepo-count muted">no svc</span>'}
        </div>
        <div class="subrepo-ctl">${control}</div>
      `;
    }

    function renderServiceTree(list, session, wt) {
      list.innerHTML = '';
      const universe = wt?.subrepos ?? [];
      const isMain = !!wt?.isMain;
      const attached = new Set(wt?.attachedSubrepos ?? universe);
      const defaults = new Set(wt?.defaultAttach ?? universe);

      // 서비스 → subrepo 그룹핑 (svc.subrepo 태그). 빈 태그 = root cwd → ungrouped.
      const byGroup = new Map();
      const rootSvcs = [];
      for (const svc of session.services) {
        if (isInternalService(svc)) continue;   // 엮기 사이드카(-bind) 등 내부서비스는 트리에서 숨김
        const g = (svc.subrepo && svc.subrepo !== '.') ? svc.subrepo : '';   // '.'(루트/단일레포)는 그룹 없이 상단
        if (!g) { rootSvcs.push(svc); continue; }
        if (!byGroup.has(g)) byGroup.set(g, []);
        byGroup.get(g).push(svc);
      }
      // 그룹 순서: universe 순서 + 서비스만 참조하는 미등록 그룹은 뒤에.
      const groups = [...universe];
      for (const g of byGroup.keys()) if (!groups.includes(g)) groups.push(g);

      // 1) 루트(cwd '.') 서비스 — 카드 상단 ungrouped.
      for (const svc of rootSvcs) list.appendChild(makeSvcRow(session, svc, false));

      // 2) subrepo ⊃ service.
      if (session.kind === 'compose') {   // compose: 읽기전용 서브레포 그룹(빌드 컨텍스트 출처 — attach/추가 컨트롤 없음)
        for (const name of groups) {
          const svcs = byGroup.get(name) ?? [];
          if (!svcs.length) continue;
          const key = `${session.root}::${name}`;
          const open = subrepoOpen.has(key) ? subrepoOpen.get(key) : true;
          const head = document.createElement('div');
          head.className = 'subrepo-row';
          head.innerHTML = `<div class="subrepo-main"><span class="subrepo-toggle">${open ? '▾' : '▸'}</span><span class="subrepo-name" title="서브레포 — 빌드 컨텍스트 출처">📦 ${escapeHtml(name)}</span></div><span class="subrepo-count">${svcs.length} svc</span>`;
          list.appendChild(head);
          const body = document.createElement('div');
          body.className = 'subrepo-body';
          body.hidden = !open;
          for (const svc of svcs) body.appendChild(makeSvcRow(session, svc, false));
          list.appendChild(body);
          head.querySelector('.subrepo-main').onclick = () => { subrepoOpen.set(key, !open); render(); };
        }
      } else for (const name of groups) {
        const inUniverse = universe.includes(name);
        const isAttached = isMain || attached.has(name);
        const isDefault = defaults.has(name);
        const svcs = byGroup.get(name) ?? [];
        const key = `${session.root}::${name}`;
        const open = subrepoOpen.has(key) ? subrepoOpen.get(key) : isAttached;

        const head = document.createElement('div');
        head.className = 'subrepo-row' + (isAttached ? '' : ' detached');
        head.innerHTML = renderSubrepoHead(name, {isMain, isAttached, isDefault, inUniverse, open, count: svcs.length});
        list.appendChild(head);

        const body = document.createElement('div');
        body.className = 'subrepo-body';
        body.hidden = !open;
        for (const svc of svcs) body.appendChild(makeSvcRow(session, svc, !isAttached));
        list.appendChild(body);

        head.querySelector('.subrepo-main').onclick = () => {
          subrepoOpen.set(key, !open);
          render();
        };
        wireSubrepoToggle(head, session, wt, name, {isMain, isAttached, isDefault, inUniverse});
      }
      if (!list.children.length) {   // 빈 서비스 영역 — 빈칸 대신 '뭘 해야 하나' 안내(코덱스 UX #10)
        const empty = document.createElement('div');
        empty.className = 'empty';
        empty.style.cssText = 'padding:8px 10px;font-size:12px;color:var(--sys-cont-neutral-light);line-height:1.5';
        empty.innerHTML = session.kind === 'compose'
          ? '서비스가 아직 없습니다 — <b>▶ 전체</b>로 시작하면 compose·include 가 해석돼 나타납니다. (Docker 가 꺼져 있으면 켜고, 정의를 바꾸려면 카드의 <b>✎ compose 편집</b>)'
          : '서비스가 없습니다.';
        list.appendChild(empty);
      }
    }

    function wireSubrepoToggle(head, session, wt, name, o) {
      if (o.isMain && o.inUniverse) {
        const cb = head.querySelector('[data-default-toggle]');
        if (cb) cb.onclick = (e) => { e.stopPropagation(); withBusy(cb, '…', () => setDefaultAttach(session, wt, name, !o.isDefault)); };
      }
      const attachBtn = head.querySelector('[data-attach]');
      if (attachBtn) attachBtn.onclick = (e) => { e.stopPropagation(); withBusy(attachBtn, '…', () => attachSubrepo(session, name)); };
      const detachBtn = head.querySelector('[data-detach]');
      if (detachBtn) detachBtn.onclick = (e) => { e.stopPropagation(); withBusy(detachBtn, '…', () => detachSubrepo(session, name)); };
    }
