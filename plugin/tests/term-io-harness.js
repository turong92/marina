#!/usr/bin/env node
// app-10b-term-io.js 회귀 하네스 — grep 은 "있다"만 보지 구조를 못 본다(백오프 재무장·400 처리·
// 요청 시퀀싱은 전부 grep 을 통과하면서 깨질 수 있다). 의존성 0: fetch/EventSource/api/atob 를
// 스텁으로 심고 TermIO 를 그대로 로드해 돌린다. 실패하면 exit 1 — test-term.sh 가 node 가드에서 태운다.
'use strict';
const fs = require('fs');
const path = require('path');

const SRC = path.join(__dirname, '..', 'scripts', 'marina-web', 'app-10b-term-io.js');
const src = fs.readFileSync(SRC, 'utf8');

// classic script 의 `const TermIO` 를 꺼내온다. 테스트마다 새로 평가해 모듈 상태(sessions/offsets/…)를 격리 —
// 한 테스트의 백오프 타이머가 다음 테스트에 새면 실패가 서로를 오염시킨다.
function loadIO(st) {
  return new Function('enc', 'atob', 'api', 'fetch', 'EventSource', src + '\nreturn TermIO;')(
    st.enc, st.atob, st.api, st.fetch, st.EventSource);
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const tick = () => new Promise(r => setImmediate(r));
// label 은 함수로도 받는다 — 문자열로 넘기면 호출 시점에 굳어서 "list 1회에서 멈춤" 처럼
// 실패 순간이 아닌 시작 시점의 수치를 보고한다(진단이 거짓말을 하면 다음 사람이 헤맨다).
async function waitFor(pred, ms, label) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (pred()) return;
    await sleep(10);
  }
  throw new Error(`시간 초과: ${typeof label === 'function' ? label() : label}`);
}
function assert(cond, msg) { if (!cond) throw new Error(msg); }
const sess = (tid, extra) => Object.assign({ tid, root: '/r', agent: null, created: 1, alive: true }, extra);

function makeEnv() {
  const st = {
    esInstances: [], fetchCalls: [], listCalls: 0, openCalls: [],
    listFail: false, listHook: null, sessions: [], inputStatus: 200, inputThrow: false,
  };
  st.enc = encodeURIComponent;
  st.atob = (s) => Buffer.from(s, 'base64').toString('binary');
  st.api = async (p, options) => {
    if (p === '/api/term-list') {
      st.listCalls++;
      if (st.listFail) throw new Error('term-list 실패(서버 다운)');
      if (st.listHook) return st.listHook();
      return { sessions: st.sessions };
    }
    if (p === '/api/term-open') { st.openCalls.push(JSON.parse(options.body)); return { tid: 'opened', reused: false }; }
    return {};
  };
  st.fetch = (url, opts) => {
    const rec = { url, opts, body: opts && opts.body ? JSON.parse(opts.body) : null, startedAt: Date.now() };
    st.fetchCalls.push(rec);
    if (st.inputThrow && url === '/api/term-input') return Promise.reject(new Error('네트워크 끊김'));
    return new Promise((resolve) => setTimeout(() => {
      rec.resolvedAt = Date.now();
      resolve({ ok: url === '/api/term-input' ? st.inputStatus < 400 : true, status: st.inputStatus });
    }, 20));
  };
  st.EventSource = class {
    constructor(url) { this.url = url; this.listeners = {}; st.esInstances.push(this); }
    addEventListener(name, fn) { this.listeners[name] = fn; }
    close() { this.closed = true; }
    emit(name, obj) { if (this.listeners[name]) this.listeners[name]({ data: JSON.stringify(obj) }); }
  };
  st.lastES = () => st.esInstances[st.esInstances.length - 1];
  return st;
}

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

// ── 구독 URL 조립 — off 는 그대로 재개점(펜스포스트 보정 금지) ──
test('connect(): ?tid=a,b 조립 + offsets 를 from 으로', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  st.sessions = [sess('a'), sess('b')];
  await IO.refresh();
  assert(st.lastES().url === '/api/term-stream?tid=a%2Cb', `URL: ${st.lastES().url}`);
  st.lastES().emit('out', { tid: 'a', b64: Buffer.from('hi').toString('base64'), off: 42 });
  st.sessions = [sess('a'), sess('b'), sess('c')];   // 집합이 바뀌어야 재연결(아래 no-op 계약)
  await IO.refresh();
  const u = st.lastES().url;
  assert(u.includes('from=a%3A42'), `from 오프셋 누락(off 를 그대로 실어야): ${u}`);
  assert(!u.includes('b%3A'), `이벤트 없던 b 에 from 이 붙음: ${u}`);
});

// ── #4 — 같은 tid 집합이면 재연결하지 않는다 ──
test('#4 connect(): tid 집합이 같으면 no-op(뷰의 term-list 폴링이 SSE 를 죽이면 안 된다)', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  st.sessions = [sess('a'), sess('b')];
  await IO.refresh();
  const first = st.lastES();
  await IO.refresh(); await IO.refresh(); await IO.refresh();   // 폴링 흉내
  assert(st.esInstances.length === 1, `폴링이 SSE 를 끊었다 — ES ${st.esInstances.length}개`);
  assert(!first.closed, '건강한 스트림이 닫혔다');
});

test('#4 attach(): 연속 attach 는 재연결 1번으로 모인다(4칸 복원 thundering herd)', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  st.sessions = [sess('a'), sess('b')];
  await IO.refresh();
  assert(st.esInstances.length === 1, 'setup');
  IO.attach('a', () => {}); IO.attach('b', () => {});   // 4칸 복원처럼 연달아
  await sleep(20);
  assert(st.esInstances.length === 2, `attach 2번에 재연결 ${st.esInstances.length - 1}번(1번이어야)`);
});

// ── 옛 커넥션의 onerror 가 새 스트림을 끊으면 안 된다 ──
// close() 뒤엔 이벤트가 안 온다는 게 스펙이지만, 핸들러가 인스턴스가 아니라 바깥 sse 를 닫으면
// 한 번만 새도 건강한 스트림이 죽고 영문 모를 재연결이 돈다. 인스턴스에 묶였는지 확인한다.
test('onerror: 교체된 옛 커넥션의 에러가 새 스트림을 건드리지 않는다', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  st.sessions = [sess('a')];
  await IO.refresh();
  const oldES = st.esInstances[0];
  st.sessions = [sess('a'), sess('b')];
  await IO.refresh();                // 집합이 바뀌어 재연결 — oldES 는 닫힌 옛 커넥션
  const newES = st.lastES();
  assert(newES !== oldES, 'setup: 재연결이 안 됨');
  oldES.onerror();                   // 좀비 에러
  assert(!newES.closed, '옛 커넥션의 onerror 가 새 스트림을 닫았다');
  // 백오프(500ms)가 도는 시간까지 봐야 가드가 관측된다 — 30ms 만 보면 es.close() 캡처에 가려
  // 가드를 지워도 녹색이다(sse=null + scheduleRetry 억제가 가드의 고유 기여).
  await sleep(700);
  assert(st.esInstances.length === 2, `좀비 에러가 재연결을 유발: ES ${st.esInstances.length}개`);
});

// ── #7 — 구독 대상이 없을 때 요청된 resnap 이 조용히 버려지면 안 된다 ──
// 먼저 오프셋을 만들어 둔 뒤 목록이 빈 순간에 attach 를 건다 — offsets 가 비어 있으면 delete 가
// 어차피 no-op 이라 아무 순서든 우연히 통과하기 때문.
// 이 계약을 지탱하는 건 pendingResnap 이 Set 이라는 점이다: 지금 못 적용하면 다음 connect 로 이월된다.
// (connect(resnap) 스칼라 인자로 되돌리면 인자가 early return 과 함께 증발해 여기서 잡힌다.)
test('#7 attach(): 목록이 빈 순간의 resnap 도 보존(요청이 증발하면 스크롤백을 영영 못 받는다)', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  st.sessions = [sess('a')];
  await IO.refresh();
  st.lastES().emit('out', { tid: 'a', b64: '', off: 10 });   // offsets{a:10}
  st.sessions = [];
  await IO.refresh();                // 구독 대상 0 — connect 가 early return 하는 그 순간
  IO.attach('a', () => {});          // 인스턴스가 붙었다: a 는 snap 부터 다시 받아야 한다
  await sleep(20);
  st.sessions = [sess('a')];
  await IO.refresh();
  const u = st.lastES().url;
  assert(!u.includes('from='), `resnap 이 버려져 from 이 살아남음 — xterm 이 과거 스크롤백을 영영 못 받는다: ${u}`);
});

// ── snap/out 구분 + tid 격리 ──
test('#8 snap/out: sink 와 activity 훅이 isSnap 을 구분해 받는다', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  st.sessions = [sess('a')];
  await IO.refresh();
  const acts = []; IO.on('activity', (tid, isSnap) => acts.push([tid, isSnap]));
  let got = null;
  IO.attach('a', (bytes, isSnap) => { got = [Buffer.from(bytes).toString('utf8'), isSnap]; });
  await sleep(20);
  st.lastES().emit('snap', { tid: 'a', b64: Buffer.from('SNAP').toString('base64'), off: 4 });
  assert(got[0] === 'SNAP' && got[1] === true, `snap sink: ${JSON.stringify(got)}`);
  st.lastES().emit('out', { tid: 'a', b64: Buffer.from('OUT').toString('base64'), off: 7 });
  assert(got[0] === 'OUT' && got[1] === false, `out sink: ${JSON.stringify(got)}`);
  assert(JSON.stringify(acts) === JSON.stringify([['a', true], ['a', false]]),
    `activity 가 isSnap 을 안 넘김(snap 은 재생된 과거지 새 출력이 아니다): ${JSON.stringify(acts)}`);
});

test('sink 격리: 남의 tid 출력이 내 sink 로 새지 않는다', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  st.sessions = [sess('a'), sess('b')];
  await IO.refresh();
  const seen = [];
  IO.attach('a', (bytes) => seen.push(Buffer.from(bytes).toString('utf8')));
  await sleep(20);
  st.lastES().emit('out', { tid: 'b', b64: Buffer.from('BDATA').toString('base64'), off: 5 });
  assert(seen.length === 0, `a 의 sink 가 b 의 출력을 받음: ${seen}`);
});

// ── 입력 큐 — 직렬·코얼레싱·tid 격리 ──
test('send(): tid별 직렬 + 대기분 코얼레싱(병렬 fetch 는 글자 유실)', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  IO.send('x', '1'); IO.send('x', '2');
  await sleep(5);
  IO.send('x', '3');
  await sleep(80);
  const calls = st.fetchCalls.filter(c => c.url === '/api/term-input');
  for (let i = 1; i < calls.length; i++) {
    assert(calls[i].startedAt >= calls[i - 1].resolvedAt, '직렬이 아니다 — fetch 가 겹쳤다');
  }
  assert(calls[0].body.data === '12', `코얼레싱 실패: ${calls[0].body.data}`);
  assert(calls.map(c => c.body.data).join('') === '123', '입력 유실');
});

test('send(): 탭이 다르면 글자가 안 섞인다', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  IO.send('tabA', 'AAA'); IO.send('tabB', 'BBB');
  await sleep(80);
  const a = st.fetchCalls.filter(c => c.body && c.body.tid === 'tabA');
  const b = st.fetchCalls.filter(c => c.body && c.body.tid === 'tabB');
  assert(a.length === 1 && a[0].body.data === 'AAA', `tabA: ${JSON.stringify(a.map(c => c.body))}`);
  assert(b.length === 1 && b[0].body.data === 'BBB', `tabB: ${JSON.stringify(b.map(c => c.body))}`);
});

test('send(): 네트워크 실패분은 되돌려 다음 타이핑에 실어 보낸다', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  st.inputThrow = true;
  IO.send('x', 'ls');
  await sleep(30);
  st.inputThrow = false;
  IO.send('x', '\n');
  await sleep(60);
  const ok = st.fetchCalls.filter(c => c.url === '/api/term-input' && c.resolvedAt);
  assert(ok.length === 1 && ok[0].body.data === 'ls\n', `복원 실패: ${JSON.stringify(ok.map(c => c.body))}`);
});

// ── #2 (회귀) — fetch 는 400 도 resolve 한다 ──
test('#2 send(): term-input 400 → exit 통지 + 무한 재전송 없음', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  st.sessions = [sess('x')];
  await IO.refresh();
  const exits = []; IO.on('exit', (tid) => exits.push(tid));
  const listBefore = st.listCalls;
  st.inputStatus = 400;                       // term_input 의 ValueError("세션이 이미 종료됐어요")
  IO.send('x', 'ls\n');
  await waitFor(() => exits.length > 0, 500, '400 인데 exit 통지가 없다(키 입력이 조용히 사라짐)');
  assert(exits[0] === 'x', `exit tid: ${exits[0]}`);
  await waitFor(() => st.listCalls > listBefore, 500, '400 인데 스토어를 갱신 안 함');
  const sent = st.fetchCalls.filter(c => c.url === '/api/term-input').length;
  IO.send('x', 'more'); IO.send('x', 'keys');
  await sleep(60);
  assert(st.fetchCalls.filter(c => c.url === '/api/term-input').length === sent,
    '죽은 세션에 계속 재전송 — 400 청크를 되돌리면 이후 모든 키마다 영원히 다시 나간다');
  assert(exits.length === 1, `exit 훅이 ${exits.length}번(키마다 반복 통지)`);
});

// ── markExit 멱등 — 400 과 SSE exit 은 실제로 겹친다 ──
// send() 의 exited 체크는 재타이핑 경로만 끊는다. 이 경로는 다르다: 400 으로 죽은 걸 안 직후,
// 아직 붙어 있는 SSE 가 같은 tid 로 exit 을 배달한다(백엔드는 프론트가 아는지 모른다).
// 가드가 없으면 뷰가 '[셸 종료]' 를 두 번 찍는다.
test('markExit(): 400 과 SSE exit 이 겹쳐도 exit 훅은 한 번', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  st.sessions = [sess('x')];
  await IO.refresh();
  const exits = []; IO.on('exit', (tid) => exits.push(tid));
  st.inputStatus = 400;
  IO.send('x', 'ls\n');                            // 400 → markExit
  await waitFor(() => exits.length > 0, 500, '400 에 exit 통지가 없다');
  st.esInstances[0].emit('exit', { tid: 'x' });    // 백엔드 SSE 도 뒤늦게 같은 tid 로 exit
  await sleep(20);
  assert(exits.length === 1, `exit 훅이 ${exits.length}번 — 400 과 SSE exit 이 겹쳐 중복 통지`);
});

// ── #1 (회귀, Critical) — term-list 가 실패해도 백오프가 스스로 재무장해야 ──
test('#1 재연결: term-list 가 실패해도 백오프 체인이 살아있다(marina-control 재시작)', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  st.sessions = [sess('a')];
  await IO.refresh();
  assert(st.esInstances.length === 1, 'setup');
  st.listFail = true;                 // 서버 다운 — SSE 도 term-list 도 같이 죽는 그 순간
  st.lastES().onerror();
  // 버그판: 재시도 1번(list 2회) 후 영영 조용. 고친판: 500 → 1000 → … 로 계속 재무장.
  await waitFor(() => st.listCalls >= 3, 2500,
    () => `백오프가 재무장을 안 함 — list ${st.listCalls}회에서 멈춤(refresh 의 reject 를 .catch 가 삼켰다)`);
  st.listFail = false;                // 서버 복귀
  await waitFor(() => st.esInstances.length >= 2, 6000,
    () => `서버가 돌아왔는데 재연결 안 됨 — ES ${st.esInstances.length}개(새로고침 전까지 터미널 死)`);
});

// ── SSE 가 없는 상태의 refresh 실패 — es.onerror 만이 재무장하면 여기가 구멍이다 ──
// 위 #1 은 스트림이 이미 있어서 onerror 가 재무장을 심는 경로다. 첫 로드·세션 0개면 EventSource 자체가
// 없어서 onerror 가 영영 안 온다 — 그때 term-list 가 실패하면 아무도 낫게 하지 않는다.
test('refresh(): SSE 가 없는 첫 로드에서 실패해도 스스로 재무장한다', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  st.sessions = [sess('a')];
  st.listFail = true;                    // 첫 refresh 부터 실패 — 아직 EventSource 가 하나도 없다
  let threw = false;
  await IO.refresh().catch(() => { threw = true; });
  assert(threw, 'refresh 는 호출자에게 실패를 그대로 던져야(뷰가 빈 상태를 그릴 수 있게)');
  assert(st.esInstances.length === 0, 'setup: 이 경로엔 SSE 가 없어야 onerror 재무장이 배제된다');
  await waitFor(() => st.listCalls >= 3, 2500,
    () => `SSE 없는 실패가 재무장을 안 함 — list ${st.listCalls}회(onerror 만 재무장하면 영영 죽는다)`);
  st.listFail = false;                   // 서버 복귀
  await waitFor(() => st.esInstances.length >= 1, 6000,
    () => `서버가 돌아왔는데 구독 안 됨 — ES ${st.esInstances.length}개`);
});

// ── #5 (회귀) — 동시 refresh 의 역순 resolve ──
test('#5 refresh(): 늦게 온 옛 응답이 최신 목록을 덮지 않는다', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  const resolvers = [];
  st.listHook = () => new Promise(r => resolvers.push(r));
  const p1 = IO.refresh();            // 옛 요청
  const p2 = IO.refresh();            // 새 요청
  await waitFor(() => resolvers.length === 2, 500, 'listHook 미호출');
  resolvers[1]({ sessions: [sess('new')] });   // 새 응답이 먼저
  await tick();
  resolvers[0]({ sessions: [sess('old')] });   // 옛 응답이 나중에 — 여기서 덮이면 방금 연 세션이 사라진다
  await p1; await p2;
  const tids = IO.list().map(s => s.tid);
  assert(tids.join(',') === 'new', `stale 응답이 목록을 덮음: ${tids}`);
});

// ── #3 — cols/rows 를 뷰가 실측해 넘긴다 ──
test('#3 open(): cols/rows 를 넘긴다(80x24 하드코딩이면 스크롤백에 하드랩이 구워진다)', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  await IO.open('/r', null, 130, 40);
  assert(st.openCalls[0].cols === 130 && st.openCalls[0].rows === 40,
    `open 이 실측 크기를 무시: ${JSON.stringify(st.openCalls[0])}`);
  await IO.open('/r', { source: 'claude', sid: 'abcd1234' });
  assert(st.openCalls[1].cols === 80 && st.openCalls[1].rows === 24, '기본값 80x24');
  assert(st.openCalls[1].agent.source === 'claude', 'agent 전달');
});

// ── #6 — exit 이 정리까지 ──
test('#6 exit: 큐·오프셋·sink 를 정리한다(sink 클로저가 xterm 스크롤백을 붙든다)', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  st.sessions = [sess('a')];
  await IO.refresh();
  let got = 0;
  IO.attach('a', () => { got++; });
  await sleep(20);
  const es = st.lastES();
  es.emit('exit', { tid: 'a' });
  assert(IO.get('a') === null || IO.get('a').alive === false, 'exit 인데 alive');
  es.emit('out', { tid: 'a', b64: Buffer.from('zombie').toString('base64'), off: 9 });
  assert(got === 0, 'exit 후에도 sink 가 살아있다(인스턴스를 영원히 붙듦)');
});

// ── #9 — 훅 이름 오타를 조용히 먹지 않는다 ──
test('#9 on(): 모르는 훅 이름은 즉시 터진다', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  let threw = false;
  try { IO.on('exited', () => {}); } catch { threw = true; }
  assert(threw, "on('exited') 가 조용히 등록됨 — 영영 안 불린다");
  IO.on('exit', () => {});
});

// ── 유휴 tid — 이벤트가 하나도 안 와도 정상 ──
test('유휴 tid: 이벤트가 없어도 멈추지 않는다(무이벤트 = 정상 유휴)', async () => {
  const st = makeEnv(); const IO = loadIO(st);
  st.sessions = [sess('idle')];
  await IO.refresh();
  let called = false;
  IO.attach('idle', () => { called = true; });
  await sleep(30);
  assert(!called, '유휴 tid 에 sink 가 불림');
  assert(st.lastES().url.includes('idle'), '유휴 tid 가 구독에서 빠짐');
});

(async () => {
  let failed = 0;
  for (const t of tests) {
    try {
      await t.fn();
    } catch (e) {
      console.error(`FAIL: ${t.name}\n      ${e.message}`);
      failed++;
    }
  }
  if (failed) { console.error(`\nFAIL: term-io 하네스 ${failed}/${tests.length} 실패`); process.exit(1); }
  console.log(`ok term-io 하네스 ${tests.length}건(백오프 재무장·400=exit·요청 시퀀싱·재연결 no-op·직렬 큐)`);
})();
