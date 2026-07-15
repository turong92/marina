    // app-10b-term-io.js — 터미널 io: 세션 스토어(/api/term-list) · 멀티플렉스 SSE · tid별 입력큐.
    // 뷰(app-10-term.js)와의 경계: 여기는 tid 만 알고 DOM 을 모른다. 뷰는 칸만 알고 HTTP 를 모른다.
    // 전역 공유(classic script): api/enc(app-3)
    const TermIO = (() => {
      let sessions = [];              // [{tid, root, agent, created, alive}] — 백엔드가 진실
      let sse = null, backoff = 500, retryTimer = null;
      let subscribed = '';            // 지금 SSE 가 구독 중인 tid 집합 — 같으면 재연결이 필요 없다
      let seq = 0;                    // term-list 요청 순번 — 늦게 온 옛 응답이 최신 목록을 덮는 걸 막는다
      let drainTimer = null;
      const offsets = new Map();      // tid → 마지막으로 받은 절대 오프셋(재연결 시 from)
      const sinks = new Map();        // tid → (bytes, isSnap) => void — 인스턴스 붙은 세션만
      const queues = new Map();       // tid → {chain, buf} — 탭마다 따로여야 글자가 안 샌다
      const pendingResnap = new Set();// attach 폭주(4칸 복원)를 재연결 1번으로 모은다
      const exited = new Set();       // exit 을 통지한 tid — 죽은 칸에 계속 타이핑해도 훅은 한 번만
      const hooks = { sessions: () => {}, activity: () => {}, exit: () => {} };

      function b64Bytes(b64) {        // SSE 는 텍스트만 — base64 청크를 바이트로(UTF-8 경계 안전, xterm 이 디코드)
        const s = atob(b64 || '');
        const u = new Uint8Array(s.length);
        for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i);
        return u;
      }

      // 오타(on('exited', ...))가 조용히 등록돼 영영 안 불리는 걸 막는다 — 뷰가 훅 이름을 틀리면 즉시 터진다
      function on(name, fn) {
        if (!(name in hooks)) throw new Error(`TermIO.on: 알 수 없는 훅 ${name}`);
        hooks[name] = fn;
      }

      function forget(tid) { sinks.delete(tid); queues.delete(tid); offsets.delete(tid); }
      // 세션이 죽었다 — 목록·큐·오프셋·싱크 정리를 한 곳에서. SSE exit 과 term-input 400 둘 다 여기로 온다.
      function markExit(tid) {
        if (exited.has(tid)) return;
        exited.add(tid);
        const s = get(tid);
        if (s) s.alive = false;
        forget(tid);
        hooks.exit(tid);
      }

      async function refresh() {
        const mine = ++seq;
        let d;
        // 실패는 여기서도 재무장한다 — scheduleRetry 를 부르는 게 es.onerror 뿐이면, SSE 가 아직 없는
        // 상태(첫 로드·세션 0개)에서 list 가 실패했을 때 아무도 낫게 하지 않는다. 호출자에겐 그대로 던진다.
        try { d = await api('/api/term-list'); } catch (e) { scheduleRetry(); throw e; }
        if (mine !== seq) return sessions;   // 더 새 요청이 이미 나갔다 — 이 응답으로 덮으면 방금 연 세션이 사라진다
        sessions = (d.sessions || []).filter(s => s.alive);
        hooks.sessions(sessions);
        connect();
        return sessions;
      }
      const list = () => sessions;
      const get = (tid) => sessions.find(s => s.tid === tid) || null;

      // term-list 가 실패하면 SSE 도 타이머도 없는 상태다 — 실패 경로가 스스로 재무장해야 한다.
      // (한 번만 재시도하면 marina-control.py 재시작처럼 list 도 같이 실패하는 순간에 영영 죽는다.)
      function scheduleRetry() {
        clearTimeout(retryTimer);
        retryTimer = setTimeout(() => refresh().catch(() => {}), backoff);   // refresh 가 스스로 재무장한다
        backoff = Math.min(backoff * 2, 5000);
      }

      // 구독 = 살아있는 세션 전부. 커넥션이 1개라 공짜 — 인스턴스 없는 세션은 활동 닷만 켠다.
      function connect() {
        clearTimeout(retryTimer);                  // 성공 경로 — 재시도 체인을 끊는다
        for (const t of pendingResnap) offsets.delete(t);   // 그 tid 만 snap 부터 다시
        const hadResnap = pendingResnap.size > 0;
        pendingResnap.clear();
        const tids = sessions.map(s => s.tid);
        const key = tids.join(',');
        // 같은 tid 를 이미 스트리밍 중이고 resnap 요청도 없으면 no-op — 건강한 스트림을 끊지 않는다.
        // (exit·kill·open·send 400 이 전부 refresh→connect 를 부른다. 가드가 없으면 그때마다 스트림을
        //  끊고 구독 tid 전부의 snap 을 다시 받는다 — tid 당 최대 256KB.)
        if (sse && key === subscribed && !hadResnap) return;
        try { sse && sse.close(); } catch {}
        sse = null;
        subscribed = key;
        if (!tids.length) return;
        const from = tids.filter(t => offsets.has(t)).map(t => `${t}:${offsets.get(t)}`).join(',');
        const es = new EventSource(`/api/term-stream?tid=${enc(tids.join(','))}${from ? `&from=${enc(from)}` : ''}`);
        sse = es;
        const onChunk = (isSnap) => (ev) => {
          let m; try { m = JSON.parse(ev.data); } catch { return; }
          if (typeof m.off === 'number') offsets.set(m.tid, m.off);
          const sink = sinks.get(m.tid);
          if (sink) sink(b64Bytes(m.b64), isSnap);
          // 칸에 떠 있는지는 뷰가 판단 — io 는 "출력 왔다"만 알린다.
          // snap 은 재생된 과거지 새 출력이 아니다 — 뷰가 구분하도록 isSnap 을 같이 넘긴다.
          hooks.activity(m.tid, isSnap);
        };
        es.addEventListener('snap', onChunk(true));
        es.addEventListener('out', onChunk(false));
        es.addEventListener('exit', (ev) => {
          let m; try { m = JSON.parse(ev.data); } catch { return; }
          markExit(m.tid);
        });
        es.onerror = () => {                     // 끊김 → 지수 백오프, from 으로 이어받아 무중복
          if (sse !== es) return;                // 이미 교체된 옛 커넥션 — 건강한 새 스트림을 끊으면 안 된다
          try { es.close(); } catch {}
          sse = null;
          // connect 가 아니라 refresh — 캐시된 목록으로 재시도하면 썩은 tid 하나에 영구히 물린다
          scheduleRetry();
        };
        es.onopen = () => { if (sse === es) backoff = 500; };
      }

      // 인스턴스가 생겼다 — 그 tid 만 snap 부터 다시 받는다(과거 스크롤백을 xterm 에 채우려고).
      // 재연결은 짧은 타이머로 미룬다 — 4칸 복원이 attach 를 연달아 불러도 실제 재연결은 1번.
      // 요청을 Set 에 적어두는 게 핵심 — connect(resnap) 스칼라 인자였다면 드레인 전에 증발한다.
      // (connect 는 맨 위에서 무조건 적용하므로 구독 대상이 0이어도 요청이 사라지지 않는다.)
      function attach(tid, sink) {
        sinks.set(tid, sink);
        pendingResnap.add(tid);
        if (!drainTimer) drainTimer = setTimeout(() => { drainTimer = null; connect(); }, 0);
      }
      function detach(tid) { sinks.delete(tid); }   // 인스턴스는 살려두므로 구독은 유지

      // cols/rows 는 뷰가 실측해 넘긴다 — 80x24 로 열면 에이전트 TUI(claude --resume)가 즉시 그 폭으로
      // 하드랩한 바이트가 history 에 영구히 굽힌다. SIGWINCH 는 라이브 화면만 고치지 스크롤백은 못 고친다.
      async function open(root, agent, cols = 80, rows = 24) {
        const d = await api('/api/term-open', { method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ root, cols, rows, agent: agent ? { source: agent.source, sid: agent.sid } : undefined }) });
        await refresh();
        return d.tid;
      }
      async function kill(tid) {
        try { await api('/api/term-kill', { method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ tid }) }); } catch {}
        forget(tid);
        await refresh();
      }
      function resize(tid, cols, rows) {   // fire-and-forget — 응답을 기다릴 이유가 없다
        fetch('/api/term-resize', { method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ tid, cols, rows }) }).catch(() => {});
      }

      // 키 입력은 병렬 fetch 금지 — 요청이 추월/유실되면 글자가 사라진다. tid별 직렬 큐 + 대기분 코얼레싱.
      function send(tid, data) {
        if (exited.has(tid)) return;    // 죽은 세션 — 400 을 받아 exit 을 또 통지할 이유가 없다
        let q = queues.get(tid);
        if (!q) { q = { chain: Promise.resolve(), buf: '' }; queues.set(tid, q); }
        q.buf += data;
        q.chain = q.chain.then(async () => {
          if (!q.buf) return;
          const chunk = q.buf; q.buf = '';
          let res;
          try {
            res = await fetch('/api/term-input', { method: 'POST', headers: { 'content-type': 'application/json' },
              body: JSON.stringify({ tid, data: chunk }) });
          } catch {
            q.buf = chunk + q.buf;      // 네트워크 실패만 여기 온다 — 되돌려 다음 타이핑에 실어 보낸다
            return;                     // (스스로 재전송하진 않는다: 사용자가 또 쳐야 나간다)
          }
          // fetch 는 400 도 resolve 한다 — term_input 의 "세션이 이미 종료됐어요"(ValueError→400)를
          // 안 보면 키 입력이 조용히 사라진다. 되돌리지 않는다: 죽은 세션엔 재전송해도 영원히 400.
          if (!res.ok) {
            markExit(tid);
            refresh().catch(() => {});  // 백엔드가 진실 — 목록을 다시 읽어 뷰를 맞춘다
          }
        });
      }

      return { on, refresh, list, get, attach, detach, open, kill, resize, send };
    })();
