    // app-10-term.js — 터미널 탭: xterm.js(vendor-xterm*) + PTY SSE(/api/term-*).
    // 세션은 워크트리당 1개를 백엔드가 재사용 — 탭을 떠났다 와도, 새로고침해도 셸·스크롤백이 살아있다.
    // 헤더 스트립: 워크트리 선택(세션 전환) · ↻ 새 셸 · ⏹ 종료. 테마 전환은 실시간 반영.
    // 전역 공유(classic script): api/enc/escapeHtml(app-3), WS_VIEWS(app-6), worktreeData/selectedProjectId(app-1), gitMainRoot(app-8)
    let termInst = null, termFit = null, termRoot = null, termTid = null, termSse = null, termRO = null;
    let termAgent = null;      // 붙어 있는 에이전트 {source, sid, title} — null 이면 일반 셸
    let termPending = null;    // openAgentTerminal 이 심는 1회성 컨텍스트 (AGENTS 행 → 터미널 탭 라우팅)

    function termB64Bytes(b64) {   // SSE 는 텍스트만 — base64 청크를 바이트로(UTF-8 경계 안전, xterm 이 디코드)
      const s = atob(b64 || '');
      const u = new Uint8Array(s.length);
      for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i);
      return u;
    }
    function termTheme() {
      const cs = getComputedStyle(document.documentElement);
      const v = (name, fb) => (cs.getPropertyValue(name) || '').trim() || fb;
      return { background: v('--sys-bg-surface', '#101318'), foreground: v('--sys-cont-neutral-default', '#d8dee6'),
               cursor: v('--sys-cont-primary-default', '#7aa2f7'), selectionBackground: 'rgba(122,162,247,0.3)' };
    }
    // 다크/라이트 전환(documentElement.dark 클래스) 실시간 반영 — 열려 있는 터미널의 색만 바꾼다
    new MutationObserver(() => { if (termInst) termInst.options.theme = termTheme(); })
      .observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });

    function termPost(path, payload) {   // 리사이즈 등 — 응답 안 기다리는 fire-and-forget
      fetch(path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload) }).catch(() => {});
    }
    // 키 입력은 병렬 fetch 금지 — HTTP 요청이 추월/유실되면 글자가 사라진다. 직렬 큐 + 대기분 코얼레싱.
    let termSendChain = Promise.resolve(), termSendBuf = '';
    function termSendInput(data) {
      termSendBuf += data;
      termSendChain = termSendChain.then(async () => {
        if (!termSendBuf || !termTid) return;
        const chunk = termSendBuf; termSendBuf = '';
        try {
          await fetch('/api/term-input', { method: 'POST', headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ tid: termTid, data: chunk }) });
        } catch { termSendBuf = chunk + termSendBuf; }   // 실패분 복원 — 다음 입력에 실려 재전송
      });
    }
    function termDispose() {
      try { termSse && termSse.close(); } catch {}
      try { termRO && termRO.disconnect(); } catch {}
      try { termInst && termInst.dispose(); } catch {}
      termSse = termRO = termInst = termFit = null; termTid = null; termRoot = null; termAgent = null;
      termSendBuf = '';
    }
    const termKeyOf = (root, agent) => `${root}::${agent ? agent.source + ':' + agent.sid : ''}`;

    function termWtLabel(w) {
      if (w.source === 'main' || w.isMain) return `${w.projectLabel || 'main'} (main)`;
      return w.alias || (w.root || '').split('/').pop();
    }
    function termEnsureShell(pane, root) {   // 헤더+본문 골격은 1회 — 이후엔 select 옵션만 신선하게
      if (!pane.querySelector('[data-term-wrap]')) {
        pane.innerHTML = `<div class="term-head">
            <select data-term-wt title="터미널을 열 워크트리 — 워크트리당 세션 1개(전환해도 이전 세션 유지)"></select>
            <span class="term-agent-chip" data-term-agent hidden></span>
            <span class="git-head-fill"></span>
            <button data-term-new title="새 셸 — 현재 세션을 종료하고 새로 시작">↻</button>
            <button data-term-kill title="세션 종료 — 프로세스까지 내림">⏹</button></div>
          <div class="term-body"><div class="term-wrap" data-term-wrap></div></div>`;
        pane.querySelector('[data-term-wt]').onchange = (e) => termActivate(pane, e.target.value);   // select = 일반 셸(에이전트 해제)
        pane.querySelector('[data-term-new]').onclick = async () => {
          const r = termRoot || pane.querySelector('[data-term-wt]').value;
          const a = termAgent;   // 에이전트에 붙어 있었으면 같은 세션에 다시 붙는다(resume 재실행)
          if (termTid) { try { await api('/api/term-kill', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ tid: termTid }) }); } catch {} }
          termDispose();
          termActivate(pane, r, a);
        };
        pane.querySelector('[data-term-kill]').onclick = async () => {
          if (termTid) { try { await api('/api/term-kill', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ tid: termTid }) }); } catch {} }
          termDispose();
          const wrap = pane.querySelector('[data-term-wrap]');
          if (wrap) wrap.innerHTML = '<div class="git-sub" style="padding:14px">세션 종료됨 — ↻ 를 누르면 새 셸</div>';
        };
      }
      const sel = pane.querySelector('[data-term-wt]');
      const wts = (typeof worktreeData !== 'undefined' ? worktreeData : [])
        .filter(w => typeof selectedProjectId === 'undefined' || !selectedProjectId || w.projectId === selectedProjectId);
      // 라벨 중복(예: ~/.codex/worktrees/<id>/mdc-main 들) — 부모 디렉토리를 붙여 구분
      const labels = wts.map(termWtLabel);
      const disp = labels.map((l, i) => {
        if (labels.filter(x => x === l).length < 2) return l;
        const seg = (wts[i].root || '').split('/').filter(Boolean);
        return `${seg[seg.length - 2] || ''}/${l}`;
      });
      sel.innerHTML = wts.map((w, i) =>
        `<option value="${escapeHtml(w.root)}"${w.root === root ? ' selected' : ''}>${escapeHtml(disp[i])}</option>`).join('');
      return pane.querySelector('[data-term-wrap]');
    }

    async function termActivate(pane, root, agent) {
      if (!root) { pane.innerHTML = '<div class="git-err" style="padding:14px">워크트리를 먼저 선택하세요</div>'; return; }
      if (typeof Terminal === 'undefined') { pane.innerHTML = '<div class="git-err" style="padding:14px">xterm 로드 실패 — 새로고침 해보세요</div>'; return; }
      const wrap = termEnsureShell(pane, root);
      const chip = pane.querySelector('[data-term-agent]');
      if (chip) {   // 붙은 대상 표시 — 에이전트면 CC/CX 칩 + 세션 제목
        chip.hidden = !agent;
        if (agent) chip.innerHTML = `<span class="agent-src ${agent.source === 'codex' ? 'codex' : 'claude'}">${agent.source === 'codex' ? 'Codex' : 'Claude'}</span> <span class="term-agent-title" title="${escapeHtml(agent.title || '')}">${escapeHtml(agent.title || agent.sid)}</span>`;
      }
      if (termKeyOf(root, agent) === termKeyOf(termRoot, termAgent) && termInst) { if (termFit) termFit.fit(); termInst.focus(); return; }   // 같은 대상 재진입 — 그대로
      termDispose();
      wrap.innerHTML = '';
      termRoot = root;
      termAgent = agent || null;
      termInst = new Terminal({ fontSize: 12.5, fontFamily: 'ui-monospace, Menlo, monospace', cursorBlink: true,
                                scrollback: 5000, theme: termTheme(), allowProposedApi: true });
      termFit = new FitAddon.FitAddon();
      termInst.loadAddon(termFit);
      termInst.open(wrap);
      termFit.fit();
      let opened;
      try {
        opened = await api('/api/term-open', { method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ root, cols: termInst.cols, rows: termInst.rows,
            agent: agent ? { source: agent.source, sid: agent.sid } : undefined }) });
      } catch (e) { wrap.innerHTML = `<div class="git-err" style="padding:14px">${escapeHtml(e.message)}</div>`; termRoot = null; termAgent = null; return; }
      termTid = opened.tid;
      termSse = new EventSource(`/api/term-stream?tid=${enc(opened.tid)}`);
      termSse.addEventListener('snap', ev => termInst && termInst.write(termB64Bytes(ev.data)));   // 스크롤백 재생
      termSse.onmessage = ev => termInst && termInst.write(termB64Bytes(ev.data));
      termSse.addEventListener('exit', () => {
        if (termInst) termInst.write(`\r\n\x1b[2m[${agent ? '에이전트 세션 종료' : '셸 종료'} — ↻ 또는 재진입하면 새 세션]\x1b[0m\r\n`);
        try { termSse.close(); } catch {}
        termRoot = null; termAgent = null;   // 다음 activate 에서 새로 연다
      });
      termInst.onData(data => termSendInput(data));
      termRO = new ResizeObserver(() => {
        if (!termFit || !termInst) return;
        termFit.fit();
        termPost('/api/term-resize', { tid: termTid, cols: termInst.cols, rows: termInst.rows });
      });
      termRO.observe(wrap);
      termInst.focus();
    }

    // 깃 D&D Interactive Rebase → 터미널에서 실행(웹 UI 로는 대화형 편집 불가, PTY 가 에디터를 띄운다).
    // 그 워크트리 셸을 열고 명령을 타이핑까지만(엔터는 사용자 — 안전). openGitTab 패턴과 동일.
    function openTerminalCmd(root, cmd) {
      termPending = { root, agent: null };
      const alreadyOn = typeof wsActive !== 'undefined' && wsActive === 'term';
      if (typeof setWsTab === 'function') setWsTab('term');
      const send = () => setTimeout(() => { if (termTid) termSendInput(cmd); }, alreadyOn ? 300 : 1200);
      if (alreadyOn) { const pane = document.getElementById('tab-term'); const p = termPending; termPending = null; termActivate(pane, p.root, null).then(send); }
      else send();
    }
    // AGENTS 행 → 터미널 attach 진입점 (오르카 문법 — 좌측 패널과 연동). openGitTab 과 같은 pending 패턴.
    function openAgentTerminal(root, agent) {
      termPending = { root, agent };
      const alreadyOn = typeof wsActive !== 'undefined' && wsActive === 'term';
      if (typeof setWsTab === 'function') setWsTab('term');
      if (alreadyOn) { const pane = document.getElementById('tab-term'); const p = termPending; termPending = null; termActivate(pane, p.root, p.agent); }
    }
    // 탭 이탈(deactivate)에도 SSE 는 유지 — 백그라운드 출력이 계속 쌓여 돌아왔을 때 이어 보인다
    WS_VIEWS.term = { activate(pane, ctx) {
      if (termPending) { const p = termPending; termPending = null; termActivate(pane, p.root, p.agent); return; }
      const r = (ctx && ctx.root) || termRoot || (typeof gitMainRoot === 'function' ? gitMainRoot() : null);
      termActivate(pane, r, r === termRoot ? termAgent : null);   // 다른 워크트리로 오면 에이전트 컨텍스트는 버림
    } };
