// term-run.js — 터미널 넘기기 페이지(/term-run?t=<token>). 세션이 부탁한 명령을 새 PTY 셸에 **입력만** 해 둔다(Enter 는 사람이).
// 기존 터미널 API 그대로: term-open → term-stream(SSE snap/out/exit, b64) → term-input(직렬 큐). 설계: docs/superpowers/specs/2026-10-05-terminal-handoff-design.md
(() => {
  const $ = (id) => document.getElementById(id);
  const enc = encodeURIComponent;
  const state = $('state');
  const json = { 'content-type': 'application/json' };
  const fail = (msg) => { state.textContent = msg; state.className = 'err'; state.hidden = false; };

  function b64Bytes(b64) {
    const s = atob(b64 || '');
    const u = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i);
    return u;
  }

  // 새로고침 대비 — 토큰은 1회용이라 claim 뒤엔 서버가 요청을 잊는다. term-open 이 성공한 tid·요청 내용을 sessionStorage 에 두고
  // (키에 토큰), 다시 열렸을 때 그 tid 가 term-list 에서 살아 있으면 claim 없이 다시 붙는다(명령은 다시 입력하지 않는다).
  const storeKey = (token) => `termrun:${token}`;
  const saved = (token) => { try { return JSON.parse(sessionStorage.getItem(storeKey(token)) || 'null'); } catch { return null; } };
  const save = (token, v) => { try { sessionStorage.setItem(storeKey(token), JSON.stringify(v)); } catch {} };
  async function alive(tid) {
    try {
      const r = await fetch('/api/term-list', { cache: 'no-store' });
      return r.ok && ((await r.json()).sessions || []).some((s) => s.tid === tid && s.alive);
    } catch { return false; }
  }

  async function main() {
    const token = new URLSearchParams(location.search).get('t') || '';
    let req = null, tid = '', reattach = false;
    const prev = saved(token);
    if (prev && prev.tid && await alive(prev.tid)) { req = prev.req; tid = prev.tid; reattach = true; }
    if (!req) {
      const res = await fetch(`/api/term-request?t=${enc(token)}`, { cache: 'no-store' });
      if (res.status === 403) return fail('이 워크트리를 열 권한이 없는 계정이야.');
      if (!res.ok) return fail('링크가 만료됐거나 이미 썼어. 세션에게 다시 부탁해 줘.');
      req = await res.json();
    }
    $('why').textContent = req.why || '터미널에서 직접 실행해야 하는 명령이야';
    $('cmd').textContent = req.command;
    for (const id of ['head', 'term', 'foot']) $(id).hidden = false;
    state.hidden = true;

    const term = new Terminal({ fontSize: 13, fontFamily: 'ui-monospace, Menlo, monospace', cursorBlink: true,
                                scrollback: 5000, allowProposedApi: true, theme: { background: '#0f1115' } });
    const fit = new FitAddon.FitAddon();
    term.loadAddon(fit);
    term.open($('term'));
    fit.fit();

    if (!reattach) {                       // 토큰은 이미 소모됐다 — 실패하면 이유를 보여 준다(다시 부탁해야 하니까)
      const opened = await fetch('/api/term-open', { method: 'POST', headers: json,
        body: JSON.stringify({ root: req.root, cols: term.cols || 80, rows: term.rows || 24 }) });
      if (!opened.ok) {
        let why = '';
        try { const e = await opened.json(); why = e.message || e.error || ''; } catch {}
        for (const id of ['head', 'term', 'foot']) $(id).hidden = true;
        return fail(`터미널을 열지 못했어(${opened.status})${why ? ': ' + why : ''}. 링크는 이미 써서, 세션에게 다시 부탁해 줘.`);
      }
      tid = (await opened.json()).tid;
      save(token, { tid, req });
    }

    // 입력은 직렬 — 병렬 fetch 는 추월·유실로 글자가 사라진다.
    let chain = Promise.resolve();
    const send = (data) => {
      chain = chain.then(() => fetch('/api/term-input', { method: 'POST', headers: json, body: JSON.stringify({ tid, data }) })
        .catch(() => {}));
      return chain;
    };
    term.onData(send);
    $('enter').onclick = () => { send('\r'); term.focus(); };

    let typed = reattach;                  // 다시 붙은 경우엔 명령을 또 입력하지 않는다(이미 입력됐거나 실행됐다)
    if (reattach) $('enter').disabled = false;
    const typeCommand = () => {            // 첫 출력(프롬프트) 뒤에 한 번 — 개행 없이 입력만
      if (typed) return;
      typed = true;
      send(req.command).then(() => { $('enter').disabled = false; term.focus(); });
    };
    const es = new EventSource(`/api/term-stream?tid=${enc(tid)}`);
    es.addEventListener('snap', (ev) => { const m = JSON.parse(ev.data); term.reset(); term.write(b64Bytes(m.b64)); setTimeout(typeCommand, 400); });
    es.addEventListener('out', (ev) => { const m = JSON.parse(ev.data); term.write(b64Bytes(m.b64)); setTimeout(typeCommand, 400); });
    es.addEventListener('exit', () => { $('enter').disabled = true; $('hint').textContent = '터미널이 끝났어.'; es.close(); });

    let rz = 0;
    window.addEventListener('resize', () => {
      clearTimeout(rz);
      rz = setTimeout(() => {
        fit.fit();
        fetch('/api/term-resize', { method: 'POST', headers: json, body: JSON.stringify({ tid, cols: term.cols, rows: term.rows }) }).catch(() => {});
      }, 150);
    });
  }

  main().catch((e) => fail(`열지 못했어: ${e && e.message ? e.message : e}`));
})();
