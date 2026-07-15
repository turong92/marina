# 터미널 멀티세션 + 분할 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** marina 대시보드 터미널 탭을 cmux 처럼 — 세션 N개를 동시에 열어두고 최대 4칸으로 분할해 본다.

**Architecture:** 개념을 셋으로 가른다. **세션**(백엔드 PTY, tid 로 식별, `/api/term-list` 가 진실) / **인스턴스**(세션당 xterm 하나, 칸에서 빠져도 살아있음) / **칸**(그리드 1~4, 어느 세션을 그릴지만 지정). 백엔드는 셸 재사용 계약을 버리고(에이전트 attach 만 재사용) 세션 목록 API 와 멀티플렉스 SSE 를 연다. 프론트는 io(tid·스트림·입력큐)와 뷰(사이드바·그리드·D&D)로 파일을 가른다.

**Tech Stack:** Python 3 stdlib(pty·threading·http.server), xterm.js + FitAddon(vendor), classic script 전역 공유, bash 테스트(`plugin/tests/test-term.sh`).

**설계 스펙:** `docs/superpowers/specs/2026-07-15-terminal-multitab-design.md`

---

## File Structure

| 파일 | 책임 | 변경 |
|---|---|---|
| `plugin/scripts/marina_term.py` | PTY 세션 수명·링버퍼·멀티플렉스 SSE | 수정 |
| `plugin/scripts/marina_handler.py` | 라우팅(term-list 신설, term-stream 다중 tid 파싱) | 수정 |
| `plugin/scripts/marina-web/app-10b-term-io.js` | 세션 스토어·멀티플렉스 SSE·tid별 입력큐 (**DOM 모름**) | **신규** |
| `plugin/scripts/marina-web/app-10-term.js` | 사이드바·그리드/분할·D&D·인스턴스 수명 (**HTTP 모름**) | 전면 재작성 |
| `plugin/scripts/marina-web/styles.css` | 사이드바·그리드·칸 헤더 스타일 | 수정 |
| `plugin/scripts/marina-web/index.html` | app-10b 로드 추가 | 수정 |
| `plugin/tests/test-term.sh` | 계약 갱신 + 신규 계약 | 수정 |

**경계:** io 는 tid 만 알고 DOM 을 모른다. 뷰는 칸만 알고 HTTP 를 모른다. 둘은 `TermIO` 객체와 콜백 3개(`onSessions`/`onData`/`onExit`)로만 만난다.

---

## Task 1: 백엔드 — 공유 Condition + 셸 재사용 계약 폐지

**배경:** 지금 `_by_root[cwd]` 가 셸을 워크트리당 1개로 묶는다(`term_open` 이 무조건 재사용). 이걸 떼야 같은 워크트리에 셸 N개가 열린다. 단 **에이전트 attach 는 재사용을 유지**한다 — CC/CX 세션에 `--resume` 을 두 번 붙이면 안 되기 때문이다. 동시에 `_Term.cond` 를 전 세션 공유 Condition 하나로 바꾼다(Task 3 멀티플렉스가 아무 세션 출력에나 깨어나야 함).

**Files:**
- Modify: `plugin/scripts/marina_term.py:32-59` (`_Term`, 전역 맵), `plugin/scripts/marina_term.py:113-156` (`term_open`), `plugin/scripts/marina_term.py:181-192` (`term_kill`)
- Test: `plugin/tests/test-term.sh`

- [ ] **Step 1: 기존 재사용 단언을 새 계약으로 교체(실패하는 테스트)**

`plugin/tests/test-term.sh` 에서 아래 두 줄을 찾아

```python
d2 = mt.term_open(Path(tmp), 100, 30)
assert d2["reused"] and d2["tid"] == d["tid"], "워크트리당 세션 1개 재사용 계약"
```

다음으로 **교체**한다:

```python
d2 = mt.term_open(Path(tmp), 100, 30)
assert not d2["reused"] and d2["tid"] != d["tid"], "셸은 매번 새 세션(같은 워크트리 N개)"
assert mt._by_tid[d2["tid"]].cond is mt._by_tid[d["tid"]].cond, "전 세션 공유 Condition"
mt.term_kill(d2["tid"])
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `bash plugin/tests/test-term.sh`
Expected: FAIL — `AssertionError: 셸은 매번 새 세션(같은 워크트리 N개)`

- [ ] **Step 3: 공유 Condition + key 분리 구현**

`marina_term.py` 에서 `_Term` 클래스와 전역 맵을 아래로 교체한다:

```python
# 전 세션이 한 Condition 을 공유한다 — 멀티플렉스 스트림이 아무 세션 출력에나 깨어나야 하기 때문.
# 조건변수가 하나뿐이라 중첩 획득이 없어 락 순서 문제도 생기지 않는다.
_COND = threading.Condition()


class _Term:
    def __init__(self, tid: str, root: str, fd: int, pid: int,
                 key: str = "", agent: dict[str, str] | None = None) -> None:
        self.tid, self.root, self.fd, self.pid = tid, root, fd, pid
        self.key = key            # 재사용 키 — 에이전트 세션만 가짐(셸은 "")
        self.agent = agent        # {"source","sid"} | None
        self.cond = _COND         # 공유 — `with term.cond:` 사용부는 그대로 동작
        self.history = bytearray()
        self.base = 0             # history[0] 의 절대 오프셋 — 캡 절단만큼 증가
        self.alive = True
        self.created = time.time()
        self.last = time.time()

    def append(self, data: bytes) -> None:
        with self.cond:
            self.history += data
            overflow = len(self.history) - TERM_SCROLLBACK_BYTES
            if overflow > 0:
                del self.history[:overflow]
                self.base += overflow
            self.last = time.time()
            self.cond.notify_all()

    def mark_dead(self) -> None:
        with self.cond:
            self.alive = False
            self.cond.notify_all()


_lock = threading.Lock()
_by_tid: dict[str, _Term] = {}
_by_key: dict[str, _Term] = {}    # 에이전트 세션만 — 셸은 매번 새로 연다
```

`term_open` 의 `with _lock:` 블록을 아래로 교체한다(그 위 검증부는 그대로 두고, `key = cwd` 였던 줄만 `key = ""` 로 바꾼다):

```python
    cmd = ""
    key = ""
    agent = None
    if agent_source:
        if agent_source not in _AGENT_CLIS:
            raise ValueError("unknown agent source")
        if not _SID_RE.fullmatch(agent_sid or ""):
            raise ValueError("invalid session id")
        cmd = _AGENT_CLIS[agent_source](agent_sid)
        key = f"{cwd}::agent:{agent_source}:{agent_sid}"
        agent = {"source": agent_source, "sid": agent_sid}
    with _lock:
        if key:                                  # 에이전트만 재사용 — resume 이중 실행 방지
            existing = _by_key.get(key)
            if existing and existing.alive:
                _set_winsize(existing.fd, cols, rows)
                return {"tid": existing.tid, "reused": True}
        pid, fd = pty.fork()
        if pid == 0:  # 자식 — 즉시 exec (스레드 안전을 위해 그 사이 파이썬 코드 최소화)
            try:
                os.chdir(cwd)
            except OSError:
                pass
            shell = os.environ.get("SHELL") or "/bin/zsh"
            env = dict(os.environ, TERM="xterm-256color", MARINA_TERM="1")
            argv = [shell, "-il", "-c", 'exec "$@"', shell, *cmd] if cmd else [shell, "-il"]
            try:
                os.execvpe(shell, argv, env)
            except OSError:
                os._exit(127)
        _set_winsize(fd, cols, rows)
        term = _Term(uuid.uuid4().hex[:16], cwd, fd, pid, key, agent)
        _by_tid[term.tid] = term
        if key:
            _by_key[key] = term
        threading.Thread(target=_reader, args=(term,), daemon=True, name=f"term-{term.tid}").start()
        return {"tid": term.tid, "reused": False}
```

`term_kill` 의 정리부를 교체한다(`term.root` 가 이제 실제 경로라 키로 쓸 수 없다):

```python
    with _lock:
        _by_tid.pop(term.tid, None)
        if term.key and _by_key.get(term.key) is term:
            _by_key.pop(term.key, None)
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `bash plugin/tests/test-term.sh`
Expected: PASS — `ok term open/reuse/io/resize/kill + agent attach(...)` 및 `PASS test-term`
(기존 에이전트 재사용 단언 `d7["reused"] and d7["tid"] == d6["tid"]` 이 여전히 통과해야 한다.)

- [ ] **Step 5: 커밋**

```bash
git add plugin/scripts/marina_term.py plugin/tests/test-term.sh
git commit -m "feat(term): 셸은 매번 새 세션 — 워크트리당 1개 재사용 계약 폐지(에이전트만 유지)"
```

---

## Task 2: 백엔드 — `/api/term-list` 세션 목록

**배경:** 슬롯 도입으로 "경로=키" 자동 복구가 깨진다. 프론트가 tid 를 잊으면 살아있는 PTY 에 다시 붙을 길이 없어 6시간 TTL 까지 좀비로 남는다. 목록 API 가 새로고침 복원의 근거이자 고아 방지책이다.

**Files:**
- Modify: `plugin/scripts/marina_term.py` (`term_list` 추가 — `term_kill` 위)
- Test: `plugin/tests/test-term.sh`

- [ ] **Step 1: 실패하는 테스트 작성**

`plugin/tests/test-term.sh` 의 `PY` 히어독 안, `mt.term_kill(d3["tid"])` **바로 앞**에 넣는다:

```python
# ── term_list — 새로고침 복원의 근거(고아 PTY 방지) ──
la = mt.term_open(Path(tmp), 80, 24)
lb = mt.term_open(Path(tmp), 80, 24)
lst = mt.term_list()["sessions"]
by = {s["tid"]: s for s in lst}
assert la["tid"] in by and lb["tid"] in by, "열린 세션이 목록에 없음"
assert by[la["tid"]]["root"] == str(Path(tmp).resolve()), "root 가 실제 경로여야"
assert by[la["tid"]]["agent"] is None and by[la["tid"]]["alive"] is True
assert by[la["tid"]]["created"] <= by[lb["tid"]]["created"], "created 오름차순이 라벨(셸 N)의 근거"
mt.term_kill(la["tid"])
assert la["tid"] not in {s["tid"] for s in mt.term_list()["sessions"]}, "kill 후 목록에서 빠져야"
mt.term_kill(lb["tid"])
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `bash plugin/tests/test-term.sh`
Expected: FAIL — `AttributeError: module 'marina_term' has no attribute 'term_list'`

- [ ] **Step 3: 구현**

`marina_term.py` 의 `def term_kill(` 바로 위에 추가한다:

```python
def term_list() -> dict[str, Any]:
    """살아있는 세션 목록 — 프론트가 새로고침 후 tid 를 되찾는 유일한 길(고아 PTY 방지).
    오프셋은 싣지 않는다: 재개(from)의 기준값은 SSE 이벤트의 off 로 프론트가 누적한다."""
    _reap_idle()
    with _lock:
        terms = sorted(_by_tid.values(), key=lambda t: t.created)
    return {"sessions": [{"tid": t.tid, "root": t.root, "agent": t.agent,
                          "created": t.created, "alive": t.alive} for t in terms]}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `bash plugin/tests/test-term.sh`
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add plugin/scripts/marina_term.py plugin/tests/test-term.sh
git commit -m "feat(term): /api/term-list 용 세션 목록 — 새로고침 복원·고아 PTY 방지"
```

---

## Task 3: 백엔드 — 멀티플렉스 SSE

**배경:** 브라우저는 HTTP/1.x 에서 오리진당 커넥션 6개. 서버가 `protocol_version` 미설정이라 HTTP/1.0 이고 SSE 는 슬롯을 계속 점유한다. 탭마다 SSE 를 붙이면 **터미널 5개 + 로그 SSE 1개 = 6** 에서 이후 `fetch` 가 전부 대기 → 키 입력(`/api/term-input`)도 fetch 라 **타이핑이 먹통**이 된다. 한 스트림에 여러 tid 를 실으면 탭 수와 무관하게 커넥션 1개.

**Files:**
- Modify: `plugin/scripts/marina_term.py:195-239` (`term_stream` 전면 교체), 상단 `import json` 추가
- Test: `plugin/tests/test-term.sh`

- [ ] **Step 1: 실패하는 테스트 작성**

`plugin/tests/test-term.sh` 의 `PY` 히어독 안, Task 2 에서 넣은 블록 **바로 뒤**에 넣는다:

```python
# ── 멀티플렉스 SSE — 두 tid 를 한 스트림에(브라우저 6커넥션 한도 회피) ──
import json as _json, threading as _th

class _FakeHandler:                 # BaseHTTPRequestHandler 대역 — wfile 만 있으면 된다
    def __init__(self):
        self.buf = bytearray()
        self.wfile = self
    def send_response(self, code): pass
    def send_header(self, k, v): pass
    def end_headers(self): pass
    def write(self, b): self.buf += b
    def flush(self): pass

def _events(h):                     # SSE 텍스트 → [(event, obj)]
    out = []
    for block in h.buf.decode().split("\n\n"):
        if not block.strip():
            continue
        ev, data = None, None
        for line in block.split("\n"):
            if line.startswith("event: "): ev = line[7:]
            elif line.startswith("data: "): data = _json.loads(line[6:])
        out.append((ev, data))
    return out

def _b64s(o): return base64.b64decode(o["b64"]).decode(errors="replace")

ma = mt.term_open(Path(tmp), 80, 24)
mb = mt.term_open(Path(tmp), 80, 24)
h1 = _FakeHandler()
t1 = _th.Thread(target=mt.term_stream, args=(h1, [ma["tid"], mb["tid"]], {}), daemon=True)
t1.start()
mt.term_input(ma["tid"], "echo MUX_A\n")
mt.term_input(mb["tid"], "echo MUX_B\n")
deadline = time.time() + 20
while time.time() < deadline:
    evs = _events(h1)
    a = "".join(_b64s(o) for e, o in evs if o and o.get("tid") == ma["tid"] and e in ("snap", "out"))
    b = "".join(_b64s(o) for e, o in evs if o and o.get("tid") == mb["tid"] and e in ("snap", "out"))
    if "MUX_A" in a and "MUX_B" in b:
        break
    time.sleep(0.2)
else:
    raise AssertionError(f"멀티플렉스 출력 미도착: {bytes(h1.buf)[-300:]!r}")
# 태그가 섞이지 않아야 — A 스트림에 B 출력이 실리면 탭끼리 글자가 샌다
assert "MUX_B" not in a and "MUX_A" not in b, "tid 태그가 섞임"
assert all(e in ("snap", "out", "exit", "ping") for e, _ in _events(h1)), "알 수 없는 이벤트"

# from 재개 — 오프셋 이후만, 중복 없이
off_a = max(o["off"] for e, o in _events(h1) if o and o.get("tid") == ma["tid"] and "off" in o)
h2 = _FakeHandler()
t2 = _th.Thread(target=mt.term_stream, args=(h2, [ma["tid"]], {ma["tid"]: off_a}), daemon=True)
t2.start()
mt.term_input(ma["tid"], "echo RESUMED\n")
deadline = time.time() + 20
while time.time() < deadline:
    txt = "".join(_b64s(o) for e, o in _events(h2) if o and e in ("snap", "out"))
    if "RESUMED" in txt:
        break
    time.sleep(0.2)
else:
    raise AssertionError(f"from 재개 실패: {bytes(h2.buf)[-300:]!r}")
assert "MUX_A" not in txt, "from 재개인데 과거 출력이 다시 옴(중복)"

# from 이 링버퍼 base 보다 오래되면 snap 폴백
term_a = mt._by_tid[ma["tid"]]
with term_a.cond:
    term_a.base = 10 ** 9                       # 이미 잘려나간 상황을 흉내
h3 = _FakeHandler()
t3 = _th.Thread(target=mt.term_stream, args=(h3, [ma["tid"]], {ma["tid"]: 0}), daemon=True)
t3.start()
deadline = time.time() + 10
while time.time() < deadline:
    if any(e == "snap" for e, _ in _events(h3)):
        break
    time.sleep(0.2)
else:
    raise AssertionError("갭인데 snap 폴백이 없음")

mt.term_kill(ma["tid"]); mt.term_kill(mb["tid"])
t1.join(timeout=5); t2.join(timeout=5); t3.join(timeout=5)
assert not t1.is_alive(), "모든 세션이 죽으면 스트림이 끝나야"
assert any(e == "exit" for e, _ in _events(h1)), "exit 이벤트 없음"

# 썩은 tid 는 raise 가 아니라 exit — 하나 때문에 살아있는 터미널 전부의 스트림이 죽으면 안 된다
mc = mt.term_open(Path(tmp), 80, 24)
h4 = _FakeHandler()
t4 = _th.Thread(target=mt.term_stream, args=(h4, ["deadbeef", mc["tid"]], {}), daemon=True)
t4.start()
deadline = time.time() + 10
while time.time() < deadline:
    if any(e == "exit" and o.get("tid") == "deadbeef" for e, o in _events(h4)):
        break
    time.sleep(0.2)
else:
    raise AssertionError("썩은 tid 에 exit 통지가 없음(살아있는 tid 까지 죽었을 가능성)")
assert any(e == "snap" and o.get("tid") == mc["tid"] for e, o in _events(h4)), "썩은 tid 가 살아있는 tid 의 스트림을 죽임"
mt.term_kill(mc["tid"]); t4.join(timeout=5)
try:
    mt.term_stream(_FakeHandler(), [], {})
    raise AssertionError("tid 가 아예 없으면 raise 해야")
except ValueError:
    pass
print("ok term-list + 멀티플렉스 SSE(tid 태그·from 재개·snap 폴백·썩은 tid 격리)")
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `bash plugin/tests/test-term.sh`
Expected: FAIL — `term_stream() takes 2 positional arguments but 3 were given`

- [ ] **Step 3: 구현**

`marina_term.py` 상단 import 에 `json` 을 추가한다(`import base64` 아래):

```python
import json
```

`term_stream` 전체를 아래로 교체한다:

```python
def term_stream(handler: Any, tids: list[str], froms: dict[str, int] | None = None) -> None:
    """멀티플렉스 SSE — 한 커넥션에 여러 세션을 싣는다(브라우저 오리진당 6커넥션 한도 회피).

    event: snap → {"tid","b64","off"}   스크롤백 스냅샷(최초 구독, 또는 from 이 잘려나간 갭)
    event: out  → {"tid","b64","off"}   신규 청크
    event: exit → {"tid"}               그 세션 종료
    handler 는 BaseHTTPRequestHandler.
    """
    froms = froms or {}
    # 모르는 tid 는 건너뛰고 exit 으로 통지한다 — raise 하면 썩은 tid 하나가 살아있는 터미널 전부의
    # 스트림을 400 으로 죽이고, 프론트는 캐시된 목록으로 재연결을 되풀이해 영구히 물린다
    # (SSE 끊긴 사이 세션이 죽고 다른 요청의 _reap_idle 이 수거하면 발생 — 노트북 sleep/wake 조합).
    terms = [t for t in (_by_tid.get(x) for x in (tids or [])) if t]
    gone = [x for x in (tids or []) if x not in _by_tid]
    if not terms and not gone:
        raise ValueError("tid 가 없어요")
    handler.send_response(200)
    handler.send_header("content-type", "text/event-stream")
    handler.send_header("cache-control", "no-cache")
    handler.end_headers()

    def send(event: str, obj: dict[str, Any]) -> bool:
        try:
            handler.wfile.write(f"event: {event}\ndata: {json.dumps(obj)}\n\n".encode())
            handler.wfile.flush()
            return True
        except (BrokenPipeError, ConnectionResetError, OSError):
            return False

    def chunk_ev(tid: str, event: str, payload: bytes, off: int) -> bool:
        return send(event, {"tid": tid, "b64": base64.b64encode(payload).decode(), "off": off})

    offsets: dict[str, int] = {}
    initial: list[tuple[str, str, bytes, int]] = []
    for t in terms:
        with _COND:            # tid 마다 잡았다 놓는다 — 스트림끼리 독립이라 전역 원자 스냅샷이 필요 없고,
            end = t.base + len(t.history)      # 8세션×256KB 를 한 번에 들고 복사하면 그동안 모든 PTY reader 가 멈춘다
            frm = froms.get(t.tid)
            if frm is None or frm < t.base or frm > end:      # 최초 구독이거나 링버퍼에서 잘려나간 갭
                initial.append((t.tid, "snap", bytes(t.history), end))
            elif end > frm:
                initial.append((t.tid, "out", bytes(t.history[frm - t.base:]), end))
            offsets[t.tid] = end
    for tid, event, payload, off in initial:
        if not chunk_ev(tid, event, payload, off):
            return
    for tid in gone:                    # 이미 사라진 tid — 프론트가 목록에서 쳐내도록
        if not send("exit", {"tid": tid}):
            return
    if not terms:
        return

    exited: set[str] = set()
    last_beat = time.time()
    while True:
        with _COND:
            _COND.wait(timeout=1.0)
            pending: list[tuple[str, str, bytes, int]] = []
            for t in terms:
                end = t.base + len(t.history)
                off = offsets[t.tid]
                if end > off:
                    start = max(off, t.base)
                    pending.append((t.tid, "out", bytes(t.history[start - t.base:end - t.base]), end))
                    offsets[t.tid] = end
            dead = [t.tid for t in terms if not t.alive and t.tid not in exited]
        for tid, event, payload, off in pending:               # 출력 먼저, exit 나중 — 마지막 줄이 잘리지 않게
            if not chunk_ev(tid, event, payload, off):
                return
            last_beat = time.time()
        for tid in dead:
            exited.add(tid)
            if not send("exit", {"tid": tid}):
                return
        if len(exited) == len(terms):
            return
        if time.time() - last_beat > TERM_HEARTBEAT_S:
            if not send("ping", {}):
                return
            last_beat = time.time()
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `bash plugin/tests/test-term.sh`
Expected: PASS — `ok term-list + 멀티플렉스 SSE(tid 태그·from 재개·snap 폴백)`

- [ ] **Step 5: 커밋**

```bash
git add plugin/scripts/marina_term.py plugin/tests/test-term.sh
git commit -m "feat(term): 멀티플렉스 SSE — 한 커넥션에 여러 세션(브라우저 6커넥션 한도 회피)"
```

---

## Task 4: 핸들러 — term-list 라우트 + term-stream 다중 tid/from 파싱

**Files:**
- Modify: `plugin/scripts/marina_handler.py:40` (import), `plugin/scripts/marina_handler.py:396-404` (term-stream), 같은 GET 블록에 term-list 추가
- Test: `plugin/tests/test-term.sh`

- [ ] **Step 1: 실패하는 테스트 작성**

`plugin/tests/test-term.sh` 의 핸들러 계약 grep 묶음(`grep -q '"/api/term-open"' ...` 줄 아래)에 추가한다:

```bash
grep -q '"/api/term-list"' "$SCR/marina_handler.py" || { echo "FAIL: term-list 엔드포인트 없음"; exit 1; }
grep -q 'term_list' "$SCR/marina_handler.py" || { echo "FAIL: term_list 미배선"; exit 1; }
grep -q 'froms' "$SCR/marina_handler.py" || { echo "FAIL: term-stream from 오프셋 파싱 없음"; exit 1; }
```

기존 가드 검사(`grep -q 'x-forwarded-for'`)는 **파일 어딘가에 문자열이 있는지만** 본다 — term-list 라우트를
가드 밖에 달아도 아무 테스트가 못 잡는다. `term_list` 가 전 워크트리 PTY 인벤토리를 반환하니, term-list 가
**이미 가드가 걸린 term-stream 과 같은 분기에 묶였는지**를 단언한다. 이건 처방이다 — 아래 Step 3 이
`marina_handler.py:396` 의 `parsed.path == "/api/term-stream"` 을 `parsed.path in (...)` 튜플로 바꿔 term-list 를
같은 **GET** 가드 분기에 넣는다(`:533` 의 POST 튜플이 아니다 — term-list 는 GET):

```bash
grep -q '"/api/term-stream", "/api/term-list"' "$SCR/marina_handler.py" \
  || { echo "FAIL: term-list 가 게이트웨이 가드 분기 밖(term-stream 과 같은 튜플이어야)"; exit 1; }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `bash plugin/tests/test-term.sh`
Expected: FAIL — `FAIL: term-list 엔드포인트 없음`

- [ ] **Step 3: 구현**

`marina_handler.py:40` 의 import 를 교체한다:

```python
from marina_term import term_input, term_kill, term_list, term_open, term_resize, term_stream
```

`marina_handler.py` 의 `if parsed.path == "/api/term-stream":` 블록 전체를 아래로 교체한다:

```python
        if parsed.path in ("/api/term-stream", "/api/term-list"):   # 터미널 — POST 쪽과 같은 로컬 전용 가드
            if self.headers.get("x-forwarded-for") or self.headers.get("x-forwarded-host"):
                self.send_json({"error": "터미널은 로컬 대시보드에서만 쓸 수 있어요"}, 403)
                return
            if parsed.path == "/api/term-list":
                self.send_json(term_list())
                return
            query = urllib.parse.parse_qs(parsed.query)
            tids = [t for t in query.get("tid", [""])[0].split(",") if t]
            froms: dict[str, int] = {}
            for pair in query.get("from", [""])[0].split(","):       # from=tid:off,tid:off
                key, sep, value = pair.partition(":")
                if sep and key:
                    try:
                        froms[key] = int(value)
                    except ValueError:
                        pass
            try:
                term_stream(self, tids, froms)
            except ValueError as exc:
                self.send_json({"error": str(exc)}, 400)
            return
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `bash plugin/tests/test-term.sh`
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add plugin/scripts/marina_handler.py plugin/tests/test-term.sh
git commit -m "feat(term): term-list 라우트 + term-stream 다중 tid/from 파싱"
```

---

## Task 5: 프론트 io — `app-10b-term-io.js` (세션 스토어·SSE·입력큐)

**배경:** 지금 전역 `termSendChain`/`termSendBuf` 가 **한 벌**이라, 탭이 여럿이면 탭 A 의 글자가 탭 B 로 샌다. tid 별 큐로 가른다. 직렬 큐 + 코얼레싱 성질은 그대로 유지해야 한다 — 병렬 fetch 는 HTTP 요청이 추월/유실돼 글자가 사라진다.

**Task 3 이 확정한 스트림 계약 — 밟기 쉬운 함정 둘(Task 3 코드리뷰가 짚음):**
- **구독한 tid 가 이벤트를 하나도 안 낼 수 있다.** `from == end`(조용한 터미널)면 백엔드는 그 tid 에
  `snap` 도 `out` 도 안 보낸다. "tid 별 첫 이벤트가 와야 준비됨"으로 기다리면 **유휴 터미널에서 영원히 멈춘다.**
  무이벤트를 정상 유휴로 취급해라.
- **`off` 는 청크를 **포함한 뒤**의 끝 오프셋이다.** 그래서 `from=off` 로 재개하면 정확히 이어진다 —
  펜스포스트 보정이 **필요 없다.** 누가 off-by-one 이라 착각하고 `off+1`/`off-1` 로 "고치지" 않게 주의.
- `tids` 는 반드시 `list[str]` — 문자열을 넘기면 백엔드가 `TypeError` 로 시끄럽게 거부한다(글자 단위 순회 방지).
- **`exit` 이 목록보다 권위 있다.** `alive` tid 만 구독하되, **살아있다고 믿은 tid 에 `exit` 이 오는 걸 정상으로 받아라** —
  term-list 를 받은 뒤 구독 전에 그 세션이 죽고 `_reap_idle` 이 수거하면 백엔드가 raise 대신 `exit` 을 보낸다.

**Files:**
- Create: `plugin/scripts/marina-web/app-10b-term-io.js`
- Test: `plugin/tests/test-term.sh`

- [ ] **Step 1: 실패하는 테스트 작성**

`plugin/tests/test-term.sh` 의 프론트 계약 묶음에서 아래 줄을 찾아

```bash
grep -q "termSendChain" "$J" || { echo "FAIL: 입력 직렬 큐 없음(병렬 fetch 는 글자 유실)"; exit 1; }
```

다음으로 **교체**한다:

```bash
IO="$SCR/marina-web/app-10b-term-io.js"
grep -q "queues" "$IO" || { echo "FAIL: tid별 입력큐 없음(전역 큐 한 벌이면 탭끼리 글자가 샌다)"; exit 1; }
grep -q "chain" "$IO" || { echo "FAIL: 입력 직렬 큐 없음(병렬 fetch 는 글자 유실)"; exit 1; }
grep -q "term-stream?tid=" "$IO" || { echo "FAIL: 멀티플렉스 구독 없음"; exit 1; }
grep -q "app-10b-term-io.js" "$SCR/marina-web/index.html" || { echo "FAIL: io 스크립트 미로드"; exit 1; }
if command -v node >/dev/null 2>&1; then node --check "$IO" || { echo "FAIL: 문법 오류 $IO"; exit 1; }; fi
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `bash plugin/tests/test-term.sh`
Expected: FAIL — `FAIL: tid별 입력큐 없음(...)`

- [ ] **Step 3: 구현**

`plugin/scripts/marina-web/app-10b-term-io.js` 를 만든다:

```js
    // app-10b-term-io.js — 터미널 io: 세션 스토어(/api/term-list) · 멀티플렉스 SSE · tid별 입력큐.
    // 뷰(app-10-term.js)와의 경계: 여기는 tid 만 알고 DOM 을 모른다. 뷰는 칸만 알고 HTTP 를 모른다.
    // 전역 공유(classic script): api/enc(app-3)
    const TermIO = (() => {
      let sessions = [];              // [{tid, root, agent, created, alive}] — 백엔드가 진실
      let sse = null, backoff = 500, retryTimer = null;
      const offsets = new Map();      // tid → 마지막으로 받은 절대 오프셋(재연결 시 from)
      const sinks = new Map();        // tid → (bytes, isSnap) => void — 인스턴스 붙은 세션만
      const queues = new Map();       // tid → {chain, buf} — 탭마다 따로여야 글자가 안 샌다
      const hooks = { sessions: () => {}, activity: () => {}, exit: () => {} };

      function b64Bytes(b64) {        // SSE 는 텍스트만 — base64 청크를 바이트로(UTF-8 경계 안전, xterm 이 디코드)
        const s = atob(b64 || '');
        const u = new Uint8Array(s.length);
        for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i);
        return u;
      }

      function on(name, fn) { hooks[name] = fn; }

      async function refresh() {
        const d = await api('/api/term-list');
        sessions = (d.sessions || []).filter(s => s.alive);
        hooks.sessions(sessions);
        connect();
        return sessions;
      }
      const list = () => sessions;
      const get = (tid) => sessions.find(s => s.tid === tid) || null;

      // 구독 = 살아있는 세션 전부. 커넥션이 1개라 공짜 — 인스턴스 없는 세션은 활동 닷만 켠다.
      function connect(resnap) {
        clearTimeout(retryTimer);
        try { sse && sse.close(); } catch {}
        sse = null;
        const tids = sessions.map(s => s.tid);
        if (!tids.length) return;
        if (resnap) offsets.delete(resnap);      // 그 tid 만 snap 부터 다시 — 인스턴스가 새로 생겼을 때
        const from = tids.filter(t => offsets.has(t)).map(t => `${t}:${offsets.get(t)}`).join(',');
        sse = new EventSource(`/api/term-stream?tid=${enc(tids.join(','))}${from ? `&from=${enc(from)}` : ''}`);
        const onChunk = (isSnap) => (ev) => {
          let m; try { m = JSON.parse(ev.data); } catch { return; }
          if (typeof m.off === 'number') offsets.set(m.tid, m.off);
          const sink = sinks.get(m.tid);
          if (sink) sink(b64Bytes(m.b64), isSnap);
          hooks.activity(m.tid);                 // 칸에 떠 있는지는 뷰가 판단 — io 는 "출력 왔다"만 알린다
        };
        sse.addEventListener('snap', onChunk(true));
        sse.addEventListener('out', onChunk(false));
        sse.addEventListener('exit', (ev) => {
          let m; try { m = JSON.parse(ev.data); } catch { return; }
          const s = get(m.tid);
          if (s) s.alive = false;
          hooks.exit(m.tid);
        });
        sse.onerror = () => {                    // 끊김 → 지수 백오프, from 으로 이어받아 무중복
          try { sse.close(); } catch {}
          sse = null;
          // connect 가 아니라 refresh — 캐시된 목록으로 재시도하면 썩은 tid 하나에 영구히 물린다
          retryTimer = setTimeout(() => refresh().catch(() => {}), backoff);
          backoff = Math.min(backoff * 2, 5000);
        };
        sse.onopen = () => { backoff = 500; };
      }

      // 인스턴스가 생겼다 — 그 tid 만 snap 부터 다시 받는다(과거 스크롤백을 xterm 에 채우려고).
      function attach(tid, sink) { sinks.set(tid, sink); connect(tid); }
      function detach(tid) { sinks.delete(tid); }   // 인스턴스는 살려두므로 구독은 유지

      async function open(root, agent) {
        const d = await api('/api/term-open', { method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ root, cols: 80, rows: 24, agent: agent ? { source: agent.source, sid: agent.sid } : undefined }) });
        await refresh();
        return d.tid;
      }
      async function kill(tid) {
        try { await api('/api/term-kill', { method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ tid }) }); } catch {}
        sinks.delete(tid); queues.delete(tid); offsets.delete(tid);
        await refresh();
      }
      function resize(tid, cols, rows) {   // fire-and-forget — 응답을 기다릴 이유가 없다
        fetch('/api/term-resize', { method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ tid, cols, rows }) }).catch(() => {});
      }

      // 키 입력은 병렬 fetch 금지 — 요청이 추월/유실되면 글자가 사라진다. tid별 직렬 큐 + 대기분 코얼레싱.
      function send(tid, data) {
        let q = queues.get(tid);
        if (!q) { q = { chain: Promise.resolve(), buf: '' }; queues.set(tid, q); }
        q.buf += data;
        q.chain = q.chain.then(async () => {
          if (!q.buf) return;
          const chunk = q.buf; q.buf = '';
          try {
            await fetch('/api/term-input', { method: 'POST', headers: { 'content-type': 'application/json' },
              body: JSON.stringify({ tid, data: chunk }) });
          } catch { q.buf = chunk + q.buf; }   // 실패분 복원 — 다음 입력에 실려 재전송
        });
      }

      return { on, refresh, list, get, attach, detach, open, kill, resize, send };
    })();
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `bash plugin/tests/test-term.sh`
Expected: FAIL — `FAIL: io 스크립트 미로드` (index.html 은 Task 8). 그 앞의 `queues`/`chain`/`term-stream?tid=`/`node --check` 는 통과해야 한다.

- [ ] **Step 5: index.html 로드 추가 후 통과 확인**

`plugin/scripts/marina-web/index.html:250-251` 사이에 한 줄 넣는다:

```html
  <script src="/web/vendor-xterm-fit.js"></script>
  <script src="/web/app-10b-term-io.js"></script>
  <script src="/web/app-10-term.js"></script>
```

Run: `bash plugin/tests/test-term.sh`
Expected: FAIL — 이제 `termSendChain` 를 잃은 구 `app-10-term.js` 쪽 계약(`WS_VIEWS.term` 등)은 아직 통과, io 계약 전부 통과. Task 6 전까지 남는 실패는 없어야 하므로 **PASS** 여야 한다.

- [ ] **Step 6: 커밋**

```bash
git add plugin/scripts/marina-web/app-10b-term-io.js plugin/scripts/marina-web/index.html plugin/tests/test-term.sh
git commit -m "feat(term): io 레이어 분리 — 세션 스토어·멀티플렉스 SSE·tid별 입력큐"
```

---

## Task 6: 프론트 뷰 — `app-10-term.js` 전면 재작성 (사이드바·그리드·D&D)

**배경:** 지금 파일은 세션·인스턴스·칸을 전역변수 한 벌(`termInst/termTid/termRoot/termAgent`)에 뭉쳐서 터미널이 하나뿐이다. io 를 뺀 자리에 뷰만 남긴다.

**Files:**
- Rewrite: `plugin/scripts/marina-web/app-10-term.js`
- Test: `plugin/tests/test-term.sh`

- [ ] **Step 1: 실패하는 테스트 작성**

`plugin/tests/test-term.sh` 의 프론트 계약 묶음에 추가한다:

```bash
grep -q "data-term-side" "$J" || { echo "FAIL: 사이드바 없음"; exit 1; }
grep -q "data-term-grid" "$J" || { echo "FAIL: 분할 그리드 없음"; exit 1; }
grep -q "termLayoutKey\|marinaTermLayout" "$J" || { echo "FAIL: 레이아웃 복원(localStorage) 없음"; exit 1; }
grep -q "dragstart" "$J" || { echo "FAIL: 사이드바→칸 D&D 없음"; exit 1; }
grep -q "TermIO" "$J" || { echo "FAIL: io 레이어 미사용(뷰가 HTTP 를 직접 부름)"; exit 1; }
grep -q "fetch(" "$J" && { echo "FAIL: 뷰가 HTTP 를 직접 부름 — io 경계 위반"; exit 1; }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `bash plugin/tests/test-term.sh`
Expected: FAIL — `FAIL: 사이드바 없음`

- [ ] **Step 3: 구현**

`plugin/scripts/marina-web/app-10-term.js` 전체를 아래로 교체한다:

```js
    // app-10-term.js — 터미널 탭 뷰: 사이드바(세션 목록) · 그리드(1~4칸 분할) · D&D 배치.
    // 개념 셋: 세션(백엔드 PTY, TermIO 가 소유) / 인스턴스(세션당 xterm, 칸에서 빠져도 살아있음)
    //          / 칸(그리드 슬롯, 어느 세션을 그릴지만 지정).
    // 이 파일은 HTTP 를 모른다 — 백엔드는 전부 TermIO(app-10b) 경유.
    // 전역 공유(classic script): escapeHtml(app-3), WS_VIEWS(app-6), worktreeData/selectedProjectId(app-1), gitMainRoot(app-8)
    const TERM_LAYOUTS = { '1': [1, 1], 'lr': [2, 1], 'tb': [1, 2], '4': [2, 2] };
    const termLayoutKey = 'marinaTermLayout';
    let termLayout = '1';
    let termSlots = [null, null, null, null];   // 칸 index → tid | null
    let termFocus = 0;                          // 활성 칸 — 사이드바 클릭이 여기로 간다
    const termInsts = new Map();                // tid → {term, fit, ro, el} — 세션 종료 때까지 유지
    const termDirty = new Set();                // 칸에 안 떠 있는데 출력이 온 tid → 활동 닷
    let termPending = null;                     // openAgentTerminal/openTerminalCmd 가 심는 1회성 컨텍스트
    let termPane = null;

    function termTheme() {
      const cs = getComputedStyle(document.documentElement);
      const v = (name, fb) => (cs.getPropertyValue(name) || '').trim() || fb;
      return { background: v('--sys-bg-surface', '#101318'), foreground: v('--sys-cont-neutral-default', '#d8dee6'),
               cursor: v('--sys-cont-primary-default', '#7aa2f7'), selectionBackground: 'rgba(122,162,247,0.3)' };
    }
    // 다크/라이트 전환 실시간 반영 — 인스턴스 전부 순회(예전엔 termInst 하나만 갱신했다)
    new MutationObserver(() => { termInsts.forEach(i => { i.term.options.theme = termTheme(); }); })
      .observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });

    function termSaveLayout() {
      try { localStorage.setItem(termLayoutKey, JSON.stringify({ layout: termLayout, slots: termSlots, focus: termFocus })); } catch {}
    }
    function termLoadLayout() {
      try {
        const d = JSON.parse(localStorage.getItem(termLayoutKey) || 'null');
        if (!d) return;
        if (TERM_LAYOUTS[d.layout]) termLayout = d.layout;
        if (Array.isArray(d.slots)) termSlots = [0, 1, 2, 3].map(i => d.slots[i] || null);
        if (typeof d.focus === 'number' && d.focus >= 0 && d.focus < 4) termFocus = d.focus;
      } catch {}
    }
    const termSlotCount = () => TERM_LAYOUTS[termLayout][0] * TERM_LAYOUTS[termLayout][1];
    const termSlotOf = (tid) => termSlots.indexOf(tid);
    const termVisible = (tid) => { const i = termSlotOf(tid); return i >= 0 && i < termSlotCount(); };

    // ── 라벨 — 같은 root 안에서 created 오름차순 N번째 = "셸 N". 에이전트는 CC/CX 칩 + 세션 제목. ──
    function termWtLabel(root) {
      const w = (typeof worktreeData !== 'undefined' ? worktreeData : []).find(x => x.root === root);
      if (!w) return (root || '').split('/').pop();
      if (w.source === 'main' || w.isMain) return `${w.projectLabel || 'main'} (main)`;
      return w.alias || (w.root || '').split('/').pop();
    }
    // 에이전트 세션 제목은 백엔드 term-list 가 주지 않는다(백엔드는 UI 제목을 몰라도 된다) —
    // worktreeData 의 agents({source,title,ts,sid})에서 sid 로 찾는다. 거기 없으면(최근 3개·7일 캡을
    // 벗어난 오래된 세션) 36자 UUID 를 178px 칼럼에 흘리지 않게 앞 8자로 줄인다.
    function termLabel(s) {
      if (s.agent) {
        const w = (typeof worktreeData !== 'undefined' ? worktreeData : []).find(x => x.root === s.root);
        const a = ((w && w.agents) || []).find(x => x.sid === s.agent.sid);
        return (a && a.title) || s.agent.sid.slice(0, 8);
      }
      const peers = TermIO.list().filter(x => x.root === s.root && !x.agent).sort((a, b) => a.created - b.created);
      return `셸 ${peers.findIndex(x => x.tid === s.tid) + 1}`;
    }

    // ── 인스턴스 — 처음 칸에 배치될 때 생성(xterm 은 attach 된 요소에 open 해야 치수가 잡힌다) ──
    // 만들기와 tid 등록을 가른 이유: 새 셸은 tid 를 **알기 전에** 인스턴스를 만들어 fit 해야 한다
    // (term-open 에 실을 cols/rows 를 재려고). termNewShell 참조.
    function termMakeInst() {
      const el = document.createElement('div');
      el.className = 'term-wrap';
      const term = new Terminal({ fontSize: 12.5, fontFamily: 'ui-monospace, Menlo, monospace', cursorBlink: true,
                                  scrollback: 5000, theme: termTheme(), allowProposedApi: true });
      const fit = new FitAddon.FitAddon();
      term.loadAddon(fit);
      return { term, fit, el, ro: null, opened: false };
    }
    function termAdoptInst(tid, inst) {   // tid 를 알았다 — 등록하고 io 에 붙인다
      termInsts.set(tid, inst);
      inst.term.onData(d => TermIO.send(tid, d));
      TermIO.attach(tid, (bytes, isSnap) => { if (isSnap) inst.term.reset(); inst.term.write(bytes); });
      return inst;
    }
    function termEnsureInst(tid) {        // 이미 있는 세션을 칸에 처음 올릴 때
      return termInsts.get(tid) || termAdoptInst(tid, termMakeInst());
    }
    function termDisposeInst(tid) {
      const inst = termInsts.get(tid);
      if (!inst) return;
      TermIO.detach(tid);
      try { inst.ro && inst.ro.disconnect(); } catch {}
      try { inst.term.dispose(); } catch {}
      termInsts.delete(tid);
    }

    function termPlace(slot, tid) {
      if (slot < 0 || slot >= termSlotCount()) return;
      const dup = termSlots.indexOf(tid);           // 이미 다른 칸에 있으면 옮긴다(중복 배치 금지)
      if (dup >= 0 && dup !== slot) termSlots[dup] = null;
      termSlots[slot] = tid;
      termFocus = slot;
      termDirty.delete(tid);
      termSaveLayout();
      termRender();
    }
    function termSetLayout(name) {
      if (!TERM_LAYOUTS[name]) return;
      termLayout = name;
      for (let i = termSlotCount(); i < 4; i++) termSlots[i] = null;   // 줄어든 칸의 배치는 버린다(세션은 유지)
      if (termFocus >= termSlotCount()) termFocus = 0;
      termSaveLayout();
      termRender();
    }

    // 열기 전에 칸을 정하고 그 칸 크기로 xterm 을 먼저 만들어 fit 한다 — cols/rows 를 term-open 에 실어야
    // 하기 때문. 에이전트 attach 는 `claude --resume` 이 즉시 TUI 를 그리는데, 80x24 로 열면 그 하드랩이
    // 스크롤백에 **영구히 구워져** 이후 모든 snap 이 그걸 재생한다(SIGWINCH 는 라이브 화면만 고친다).
    async function termNewShell(root, agent) {
      let slot = termSlots.slice(0, termSlotCount()).indexOf(null);    // 빈 칸 우선, 없으면 활성 칸
      if (slot < 0) slot = termFocus;
      const probe = termMakeInst();                                    // tid 없이 먼저 — 치수만 재려고
      const body = termPane.querySelector(`[data-term-cell="${slot}"] .term-cell-body`);
      body.innerHTML = '';
      body.appendChild(probe.el);
      probe.term.open(probe.el);
      probe.opened = true;
      probe.fit.fit();
      let tid;
      try { tid = await TermIO.open(root, agent, probe.term.cols, probe.term.rows); }
      catch (e) { try { probe.term.dispose(); } catch {} alert(e.message); termRender(); return null; }
      termAdoptInst(tid, probe);                                       // 이제 tid 를 알았으니 그 이름으로 등록
      termPlace(slot, tid);
      return tid;
    }

    // ── 골격 — 1회만. 이후엔 사이드바·그리드 내용만 갱신. ──
    function termEnsureShell(pane) {
      if (pane.querySelector('[data-term-side]')) return;
      pane.innerHTML = `<div class="term-root">
          <div class="term-side" data-term-side></div>
          <div class="term-main">
            <div class="term-bar">
              <button data-term-lay="1" title="분할 없음">▭</button>
              <button data-term-lay="lr" title="좌우 2분할">▯▯</button>
              <button data-term-lay="tb" title="상하 2분할">⊟</button>
              <button data-term-lay="4" title="4분할">⊞</button>
              <span class="git-head-fill"></span>
              <select data-term-new-wt title="새 셸을 열 워크트리"></select>
            </div>
            <div class="term-grid" data-term-grid></div>
          </div></div>`;
      pane.querySelectorAll('[data-term-lay]').forEach(b => { b.onclick = () => termSetLayout(b.dataset.termLay); });
      pane.querySelector('[data-term-new-wt]').onchange = (e) => {
        const root = e.target.value;
        e.target.value = '';
        if (root) termNewShell(root, null);
      };
    }

    function termRenderSide(side) {
      const wts = [...new Set(TermIO.list().map(s => s.root))];
      side.innerHTML = wts.map(root => {
        const rows = TermIO.list().filter(s => s.root === root).sort((a, b) => a.created - b.created).map(s => {
          const slot = termSlotOf(s.tid);
          const badge = termVisible(s.tid) ? `<span class="term-slot-badge">${'①②③④'[slot]}</span>` : '';
          const dot = termDirty.has(s.tid) ? '<span class="term-dot"></span>' : '';
          const chip = s.agent ? `<span class="agent-src ${s.agent.source === 'codex' ? 'codex' : 'claude'}">${s.agent.source === 'codex' ? 'CX' : 'CC'}</span>` : '';
          const cls = `term-item${termVisible(s.tid) ? ' shown' : ''}${slot === termFocus && termVisible(s.tid) ? ' focus' : ''}`;
          return `<div class="${cls}" draggable="true" data-term-item="${escapeHtml(s.tid)}" title="${escapeHtml(s.root)}">
              ${dot}${chip}${badge}<span class="nm">${escapeHtml(termLabel(s))}</span>
              <span class="x" data-term-kill="${escapeHtml(s.tid)}" title="세션 종료 — 프로세스까지 내립니다">✕</span></div>`;
        }).join('');
        return `<div class="term-grp">${escapeHtml(termWtLabel(root))}</div>${rows}`;
      }).join('') || '<div class="term-hint">열린 셸이 없어요 — 우측 위에서 워크트리를 고르면 새 셸이 열려요.</div>';
      side.querySelectorAll('[data-term-item]').forEach(el => {
        el.onclick = (e) => { if (!e.target.closest('[data-term-kill]')) termPlace(termFocus, el.dataset.termItem); };
        el.ondragstart = (e) => { e.dataTransfer.setData('text/plain', el.dataset.termItem); };
      });
      side.querySelectorAll('[data-term-kill]').forEach(el => {
        el.onclick = async (e) => {
          e.stopPropagation();
          const tid = el.dataset.termKill;
          termDisposeInst(tid);
          const i = termSlots.indexOf(tid);
          if (i >= 0) termSlots[i] = null;
          termSaveLayout();
          await TermIO.kill(tid);
        };
      });
    }

    function termRenderGrid(grid) {
      const [cols, rows] = TERM_LAYOUTS[termLayout];
      grid.style.gridTemplateColumns = `repeat(${cols}, 1fr)`;
      grid.style.gridTemplateRows = `repeat(${rows}, 1fr)`;
      const n = termSlotCount();
      for (let i = grid.children.length; i < n; i++) {
        const cell = document.createElement('div');
        cell.className = 'term-cell';
        cell.dataset.termCell = String(i);
        cell.innerHTML = '<div class="term-cell-head"><span class="nm"></span><span class="x" title="칸 비우기 — 세션은 살아있어요">✕</span></div><div class="term-cell-body"></div>';
        cell.onmousedown = () => { if (termFocus !== Number(cell.dataset.termCell)) { termFocus = Number(cell.dataset.termCell); termSaveLayout(); termRender(); } };
        cell.ondragover = (e) => { e.preventDefault(); cell.classList.add('drop'); };
        cell.ondragleave = () => cell.classList.remove('drop');
        cell.ondrop = (e) => { e.preventDefault(); cell.classList.remove('drop'); termPlace(Number(cell.dataset.termCell), e.dataTransfer.getData('text/plain')); };
        cell.querySelector('.x').onclick = (e) => {
          e.stopPropagation();
          termSlots[Number(cell.dataset.termCell)] = null;   // 칸만 비움 — 세션·인스턴스는 유지
          termSaveLayout();
          termRender();
        };
        grid.appendChild(cell);
      }
      while (grid.children.length > n) grid.removeChild(grid.lastChild);

      [...grid.children].forEach((cell, i) => {
        cell.classList.toggle('focus', i === termFocus);
        const tid = termSlots[i];
        const s = tid ? TermIO.get(tid) : null;
        const head = cell.querySelector('.term-cell-head .nm');
        const body = cell.querySelector('.term-cell-body');
        if (!s) {
          head.textContent = '';
          body.innerHTML = '<div class="term-hint">사이드바에서 셸을 끌어다 놓거나 클릭하세요</div>';
          return;
        }
        head.textContent = `${termWtLabel(s.root)} · ${termLabel(s)}`;
        const inst = termEnsureInst(tid);
        if (inst.el.parentElement !== body) { body.innerHTML = ''; body.appendChild(inst.el); }
        if (!inst.opened) { inst.term.open(inst.el); inst.opened = true; }
        inst.fit.fit();
        TermIO.resize(tid, inst.term.cols, inst.term.rows);
        if (!inst.ro) {
          inst.ro = new ResizeObserver(() => {
            if (!inst.el.isConnected) return;
            inst.fit.fit();
            TermIO.resize(tid, inst.term.cols, inst.term.rows);
          });
          inst.ro.observe(inst.el);
        }
        if (i === termFocus) inst.term.focus();
      });
    }

    function termRenderNewWt(sel) {
      const wts = (typeof worktreeData !== 'undefined' ? worktreeData : []);
      const cur = typeof selectedProjectId !== 'undefined' ? selectedProjectId : null;
      const mine = wts.filter(w => !cur || w.projectId === cur);
      const rest = wts.filter(w => cur && w.projectId !== cur);
      // 라벨 중복(예: ~/.codex/worktrees/<id>/mdc-main 들) — 부모 디렉토리를 붙여 구분
      const labels = wts.map(w => termWtLabel(w.root));
      const disp = (w) => {
        const l = termWtLabel(w.root);
        if (labels.filter(x => x === l).length < 2) return l;
        const seg = (w.root || '').split('/').filter(Boolean);
        return `${seg[seg.length - 2] || ''}/${l}`;
      };
      const opts = (arr) => arr.map(w => `<option value="${escapeHtml(w.root)}">${escapeHtml(disp(w))}</option>`).join('');
      sel.innerHTML = `<option value="">＋ 새 셸…</option>${opts(mine)}${rest.length ? `<optgroup label="다른 프로젝트">${opts(rest)}</optgroup>` : ''}`;
      sel.value = '';
    }

    function termRender() {
      if (!termPane) return;
      termEnsureShell(termPane);
      // 지금 어느 분할인지 버튼에 표시 — 없으면 형이 4분할 버튼을 눌렀는지 알 방법이 없다
      termPane.querySelectorAll('[data-term-lay]').forEach(b => b.classList.toggle('on', b.dataset.termLay === termLayout));
      termRenderSide(termPane.querySelector('[data-term-side]'));
      termRenderGrid(termPane.querySelector('[data-term-grid]'));
      termRenderNewWt(termPane.querySelector('[data-term-new-wt]'));
    }

    // 활동 닷 — 인스턴스 유무와 무관하게 한 규칙: 칸에 안 떠 있는 세션에 출력이 오면 켜고, 배치되면 끈다.
    // snap 은 재생된 과거지 새 출력이 아니라 무시한다(인스턴스를 붙이는 순간 자기 자신에 닷이 켜진다).
    TermIO.on('activity', (tid, isSnap) => {
      if (isSnap || termVisible(tid) || termDirty.has(tid)) return;
      termDirty.add(tid);
      if (termPane) termRenderSide(termPane.querySelector('[data-term-side]'));
    });
    TermIO.on('exit', (tid) => {
      const inst = termInsts.get(tid);
      if (inst) inst.term.write('\r\n\x1b[2m[세션 종료됨]\x1b[0m\r\n');
      TermIO.refresh().then(() => termRender());
    });

    // 깃 D&D Interactive Rebase → 터미널에서 실행(웹 UI 로는 대화형 편집 불가, PTY 가 에디터를 띄운다).
    // 그 워크트리 셸을 열고 명령을 타이핑까지만(엔터는 사용자 — 안전).
    function openTerminalCmd(root, cmd) {
      termPending = { root, agent: null, cmd };
      if (typeof setWsTab === 'function') setWsTab('term');
      if (typeof wsActive !== 'undefined' && wsActive === 'term') termActivate(document.getElementById('tab-term'));
    }
    // AGENTS 행 → 터미널 attach 진입점 (오르카 문법 — 좌측 패널과 연동)
    function openAgentTerminal(root, agent) {
      termPending = { root, agent, cmd: null };
      if (typeof setWsTab === 'function') setWsTab('term');
      if (typeof wsActive !== 'undefined' && wsActive === 'term') termActivate(document.getElementById('tab-term'));
    }

    async function termActivate(pane) {
      if (typeof Terminal === 'undefined') { pane.innerHTML = '<div class="git-err" style="padding:14px">xterm 로드 실패 — 새로고침 해보세요</div>'; return; }
      termPane = pane;
      termEnsureShell(pane);
      await TermIO.refresh();
      // 복원: 죽은 tid 가 물린 칸은 비운다(localStorage 는 배치만, 세션 목록은 백엔드가 진실)
      termSlots = termSlots.map(t => (t && TermIO.get(t) ? t : null));
      termRender();
      const p = termPending; termPending = null;
      if (p) {
        const tid = await termNewShell(p.root, p.agent);
        if (tid && p.cmd) setTimeout(() => TermIO.send(tid, p.cmd), 1200);   // 셸 기동(-il rc 로드) 여유
      } else if (!termSlots.some(Boolean) && !TermIO.list().length) {
        const r = typeof gitMainRoot === 'function' ? gitMainRoot() : null;
        if (r) await termNewShell(r, null);                                  // 첫 진입 — 빈 화면 대신 셸 하나
      }
    }

    termLoadLayout();
    // 탭 이탈(deactivate)에도 구독은 유지 — 백그라운드 출력은 백엔드 링버퍼에 쌓이고 인스턴스가 받아쓴다
    WS_VIEWS.term = { activate(pane) { termActivate(pane); } };
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `bash plugin/tests/test-term.sh`
Expected: PASS — `PASS test-term`

- [ ] **Step 5: 커밋**

```bash
git add plugin/scripts/marina-web/app-10-term.js plugin/tests/test-term.sh
git commit -m "feat(term): 뷰 재작성 — 사이드바·1/2/4 분할 그리드·D&D 배치·인스턴스 수명 분리"
```

---

## Task 7: CSS — 사이드바·그리드·칸 헤더

**Files:**
- Modify: `plugin/scripts/marina-web/styles.css:615-625` (`.term-*` 묶음 교체)

- [ ] **Step 1: 구현**

`styles.css` 의 `.term-head`/`.term-body`/`.term-wrap` 관련 줄(615~625)을 아래로 교체한다. `.term-agent-chip`/`.term-agent-title` 은 더 이상 쓰지 않으니 함께 지운다.

```css
    .term-root { display: flex; height: 100%; min-height: 0; }
    /* 사이드바 = 상단 붙박이 `＋ 새 셸` + 목록(스크롤). 둘을 가른 이유: termRenderSide 가 목록 innerHTML 을
       통째로 다시 그리는데 select 가 그 안에 있으면 매 렌더마다 날아간다(형이 열어둔 드롭다운이 닫힌다). */
    .term-side { flex: none; width: 178px; display: flex; flex-direction: column; min-height: 0;
                 border-right: 1px solid var(--sys-style-neutral-light); background: var(--sys-bg-surface); }
    .term-side-list { flex: 1; min-height: 0; display: flex; flex-direction: column; gap: 1px; padding: 6px; overflow-y: auto; }
    .term-side-head { flex: none; padding: 6px; border-bottom: 1px solid var(--sys-style-neutral-light); }
    .term-side-head select { width: 100%; height: 24px; font-size: 11px; border: 1px dashed var(--sys-style-neutral-default);
                             border-radius: 7px; background: var(--sys-bg-surface); color: var(--sys-cont-neutral-light);
                             padding: 0 4px; cursor: pointer; }
    .term-side-head select:hover { background: var(--sys-bg-surface-hover); color: var(--sys-cont-neutral-default); }
    .term-grp { font-size: 10px; font-weight: 700; color: var(--sys-cont-neutral-lightest); padding: 7px 6px 3px;
                letter-spacing: .3px; text-transform: uppercase; }
    .term-item { display: flex; align-items: center; gap: 5px; padding: 5px 7px; border-radius: 7px; cursor: pointer;
                 font-size: 11.5px; color: var(--sys-cont-neutral-light); }
    .term-item:hover { background: var(--sys-bg-surface-hover); }
    .term-item.shown { background: var(--sys-bg-base); color: var(--sys-cont-neutral-default); }
    .term-item.focus { background: var(--sys-cont-neutral-default); color: #fff; font-weight: 600; }
    .term-item .nm { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .term-item .x { color: var(--sys-cont-neutral-lightest); font-size: 11px; opacity: 0; }
    .term-item:hover .x, .term-item.focus .x { opacity: 1; }
    .term-item.focus .x { color: #b9c0cc; }
    .term-slot-badge { flex: none; font-size: 9px; font-weight: 700; border-radius: 4px; padding: 0 3px;
                       background: color-mix(in srgb, var(--sys-cont-primary-default) 18%, transparent);
                       color: var(--sys-cont-primary-default); }
    .term-item.focus .term-slot-badge { background: rgba(255,255,255,.22); color: #fff; }
    .term-dot { flex: none; width: 6px; height: 6px; border-radius: 50%; background: var(--st-run); }
    .term-hint { font-size: 10.5px; color: var(--sys-cont-neutral-lightest); padding: 10px 6px; line-height: 1.5; text-align: center; }

    .term-main { flex: 1; min-width: 0; display: flex; flex-direction: column; }
    .term-bar { flex: none; display: flex; align-items: center; gap: 4px; padding: 5px 8px;
                border-bottom: 1px solid var(--sys-style-neutral-light); }
    .term-bar button { height: 22px; min-width: 26px; border: 1px solid var(--sys-style-neutral-light); border-radius: 6px;
                       background: none; color: var(--sys-cont-neutral-light); font-size: 11px; cursor: pointer; }
    .term-bar button:hover { background: var(--sys-bg-surface-hover); color: var(--sys-cont-neutral-default); }
    .term-bar button.on { border-color: var(--sys-cont-primary-default); color: var(--sys-cont-primary-default);
                          background: color-mix(in srgb, var(--sys-cont-primary-default) 8%, transparent); }
    .term-grid { flex: 1; min-height: 0; display: grid; gap: 3px; padding: 3px; background: var(--sys-style-neutral-light); }
    .term-cell { display: flex; flex-direction: column; min-width: 0; min-height: 0; border-radius: 6px; overflow: hidden;
                 border: 2px solid transparent; background: var(--sys-bg-surface); }
    .term-cell.focus { border-color: var(--sys-cont-primary-default); }
    .term-cell.drop { border-color: var(--sys-cont-primary-default); border-style: dashed; }
    .term-cell-head { flex: none; display: flex; align-items: center; gap: 5px; padding: 3px 7px; font-size: 10.5px;
                      color: var(--sys-cont-neutral-lightest); background: var(--sys-bg-base); }
    .term-cell-head .nm { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .term-cell-head .x { cursor: pointer; opacity: 0; }
    .term-cell:hover .term-cell-head .x { opacity: 1; }
    .term-cell-body { flex: 1; min-height: 0; position: relative; }
    .term-wrap { position: absolute; inset: 0; padding: 4px 2px 4px 8px; }
    .term-wrap .xterm { height: 100%; }
```

- [ ] **Step 2: 문법·잔재 확인**

Run: `grep -c "term-agent-chip" plugin/scripts/marina-web/styles.css plugin/scripts/marina-web/app-10-term.js`
Expected: 두 파일 모두 `0`

- [ ] **Step 3: 커밋**

```bash
git add plugin/scripts/marina-web/styles.css
git commit -m "style(term): 사이드바·분할 그리드·칸 헤더 스타일"
```

---

## Task 8: 실 대시보드 통합 검증

**배경:** 형이 보는 대시보드는 다른 워크트리가 서빙할 수 있어 내 편집이 안 보인다. **내 워크트리로 직접 띄운다.** 정리는 반드시 PID 로 — `pkill -f marina-control.py` 는 다른 세션 대시보드까지 죽인다.

**Files:** 없음(검증 전용)

- [ ] **Step 1: 전체 테스트**

Run: `for f in plugin/tests/test-*.sh; do bash "$f" >/dev/null || echo "FAIL $f"; done; echo done`
Expected: `done` 만 출력(FAIL 줄 없음). 총 개수는 `ls plugin/tests/test-*.sh | wc -l` 로 확인.

- [ ] **Step 2: 내 워크트리 대시보드 기동**

```bash
cd plugin/scripts && MARINA_CONTROL_PORT=3908 python3 marina-control.py &
```
Expected: http://localhost:3908/ 응답. 확인: `curl -s localhost:3908/api/term-list`

- [ ] **Step 3: Aside 로 실측**

`mcp__aside__repl` 로 http://localhost:3908/ 를 열고 터미널 탭에서 확인한다.

⚠️ **Aside 키보드 에뮬이 대문자를 흘린다**(Task 6 실측: `echo HELLO_FROM_SLOT1` → `echo __1`). 내 코드 문제가
아니라 도구 아티팩트다 — **소문자 명령**이나 `term.input()` API 를 써라. 안 그러면 없는 버그를 쫓게 된다.

**기본 계약:**
- 같은 워크트리에 셸 2개 열기 → 사이드바에 `셸 1`·`셸 2`
- 두 셸에 각각 `echo aaa` / `echo bbb` 타이핑 → **글자가 안 섞임**(tid별 입력큐)
- 4분할 → 네 칸 동시 스트리밍
- 커넥션 수: `performance.getEntriesByType('resource').filter(r => r.name.includes('term-stream')).length` 로 스트림이 **1개**인지
- 새로고침 → 세션·배치 복원, 죽은 tid 칸은 비어 있음
- 칸 ✕ → 세션은 사이드바에 남음 / 사이드바 ✕ → 세션 사라짐
- 다크/라이트 토글 → 열린 인스턴스 **전부** 색 바뀜

**Task 6 이 고친 계획 버그 5건 — 여기가 유일한 커버리지다.** 이 파일은 DOM+xterm 이라 grep 이 테스트의
상한이고(하네스는 jsdom 의존성을 요구해 기각), 그래서 아래를 안 하면 이 수정들이 **미검증으로 출하된다**:
- **AGENTS 행 클릭 → 셸이 `1개`만 열림**(계획대로면 `setWsTab` 뒤 `wsActive` 검사가 항상 참이라 2개였다)
- **같은 에이전트 두 번 attach → 인스턴스 1개, 스크롤백 유지**(덮어쓰기 누수 방지)
- **사이드바 ✕ → 목록이 즉시 갱신**(kill 이 스트림을 먼저 끊어 exit 이 안 오므로 재렌더가 필요)
- **세션에서 `exit` → 칸 유지 + `[세션 종료됨]` 표시 + 헤더 `(종료됨)`**(문구를 쓰고 지우지 않는지)
- **손상된 localStorage(예: `focus: 3` + 1분할) → TypeError 없이 복원**

**"열자마자 클릭" — 리뷰어가 우연히 두 번 밟은 경로.** 대시보드를 새로 열고 **즉시** 터미널 탭을 눌러라
(`worktreeData` 첫 폴은 웜 ~1s·콜드 >3s, xterm vendor 는 289KB — 둘 다 안 온 창이 넓다):
- `＋ 새 셸` 드롭다운이 **채워지나**(워크트리 0으로 진입해도 폴링 도착 후 스스로 신선해지는지)
- xterm 이 아직 안 떴을 때 "xterm 로드 실패" 에러 div 로 영구히 죽지 않나(탭 재진입으로 자가치유되는지)

**아무 데서도 안 덮이는 경로 2개 — 실 브라우저만 답할 수 있다:**
- **칸 ✕ → 같은 세션 다시 클릭 → 스크롤백 유지 + 타이핑 동작**(detach/reattach 왕복. vendored xterm 이
  DOM 렌더러라 살아남는 게 실험으로 확인됐지만, 실 앱에서 한 번은 봐야 한다)
- **이미 터미널이 떠 있는 칸에 사이드바 항목을 드롭 → 교체**(`cell.ondrop` 이 xterm DOM 의 조상이라,
  drop 이벤트가 xterm 자체 핸들러를 뚫고 도달하는지는 실 브라우저만 안다)

- [ ] **Step 4: 정리 — PID 로만**

```bash
lsof -nP -iTCP:3908 -sTCP:LISTEN -t | xargs kill
```
⚠️ `pkill -f marina-control.py` 금지 — 다른 세션 대시보드까지 죽는다.

- [ ] **Step 5: 커밋(스크린샷·메모 있으면)**

```bash
git add -A && git commit -m "test(term): 멀티세션·4분할 실 대시보드 검증" --allow-empty
```

---

## Self-Review 결과

**스펙 커버리지:** D1 개념 3분할→Task 6 / D2 셸 재사용 폐지→Task 1 / D3 term-list→Task 2 / D4 멀티플렉스 SSE→Task 3+4 / D5 파일 분리→Task 5+6 / D6 입력큐·구독·인스턴스 수명·활동 닷·테마·리사이즈→Task 5+6 / D7 사이드바·프리셋 분할·D&D·프로젝트 미추종→Task 6+7 / D8 두 ✕→Task 6 / D9 복원→Task 6. 에러 처리는 Task 5(백오프·snap 폴백)·Task 6(open 실패·exit)에 분산.

**미구현 1건(의도):** D7 의 "칸 사이 경계 드래그로 비율 조절"은 이번 계획에서 뺐다 — 프리셋 4종만으로 형이 원한 4분할이 서고, 비율 드래그는 별도 상태(ratios)와 핸들 DOM 을 더 요구한다. 실제로 써보고 필요하면 후속. **형 확인 필요.**

**타입 일관성:** `TermIO.{on,refresh,list,get,attach,detach,open,kill,resize,send}` 가 Task 5 정의와 Task 6 호출부에서 일치. `termLabel(s)`/`termWtLabel(root)` 인자 형태 일치(전자는 세션 객체, 후자는 경로 문자열). 백엔드 `term_stream(handler, tids, froms)` 시그니처가 Task 3 정의·Task 4 호출·테스트에서 일치.
