    // app-10-term.js — 터미널 탭: xterm.js(vendor-xterm*) + PTY SSE(/api/term-*).
    // 세션은 워크트리당 1개를 백엔드가 재사용 — 탭을 떠났다 와도, 새로고침해도 셸·스크롤백이 살아있다.
    // 전역 공유(classic script): api/enc/escapeHtml(app-3), WS_VIEWS(app-6), gitMainRoot(app-8)
    let termInst = null, termFit = null, termRoot = null, termTid = null, termSse = null, termRO = null;

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
      termSse = termRO = termInst = termFit = null; termTid = null; termRoot = null;
    }

    async function termActivate(pane, root) {
      if (!root) { pane.innerHTML = '<div class="git-err" style="padding:14px">워크트리를 먼저 선택하세요</div>'; return; }
      if (typeof Terminal === 'undefined') { pane.innerHTML = '<div class="git-err" style="padding:14px">xterm 로드 실패 — 새로고침 해보세요</div>'; return; }
      if (!pane.querySelector('[data-term-wrap]')) pane.innerHTML = '<div class="term-wrap" data-term-wrap></div>';
      const wrap = pane.querySelector('[data-term-wrap]');
      if (termRoot === root && termInst) { if (termFit) termFit.fit(); termInst.focus(); return; }   // 같은 워크트리 재진입 — 그대로
      termDispose();
      wrap.innerHTML = '';
      termRoot = root;
      termInst = new Terminal({ fontSize: 12.5, fontFamily: 'ui-monospace, Menlo, monospace', cursorBlink: true,
                                scrollback: 5000, theme: termTheme(), allowProposedApi: true });
      termFit = new FitAddon.FitAddon();
      termInst.loadAddon(termFit);
      termInst.open(wrap);
      termFit.fit();
      let opened;
      try {
        opened = await api('/api/term-open', { method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ root, cols: termInst.cols, rows: termInst.rows }) });
      } catch (e) { wrap.innerHTML = `<div class="git-err" style="padding:14px">${escapeHtml(e.message)}</div>`; termRoot = null; return; }
      termTid = opened.tid;
      termSse = new EventSource(`/api/term-stream?tid=${enc(opened.tid)}`);
      termSse.addEventListener('snap', ev => termInst && termInst.write(termB64Bytes(ev.data)));   // 스크롤백 재생
      termSse.onmessage = ev => termInst && termInst.write(termB64Bytes(ev.data));
      termSse.addEventListener('exit', () => {
        if (termInst) termInst.write('\r\n\x1b[2m[셸 종료 — 탭을 다시 열면 새 세션]\x1b[0m\r\n');
        try { termSse.close(); } catch {}
        termRoot = null;   // 다음 activate 에서 새로 연다
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

    // 탭 이탈(deactivate)에도 SSE 는 유지 — 백그라운드 출력이 계속 쌓여 돌아왔을 때 이어 보인다
    WS_VIEWS.term = { activate(pane, ctx) {
      termActivate(pane, (ctx && ctx.root) || (typeof gitMainRoot === 'function' ? gitMainRoot() : null));
    } };
