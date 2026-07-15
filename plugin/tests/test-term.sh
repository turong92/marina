#!/usr/bin/env bash
# 터미널 탭 백엔드(marina_term) — PTY 세션 열기(셸은 매번 새로)/에이전트 attach 재사용·청소/
# 입력→출력 왕복/리사이즈/종료/죽은 세션 수거, 핸들러 게이트웨이 가드(X-Forwarded 거부)·프론트 문법 계약.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$SCR" "$TMP" <<'PY'
import base64, re as _re, sys, time
from pathlib import Path
scr, tmp = sys.argv[1:3]
sys.path.insert(0, scr)
import marina_term as mt

d = mt.term_open(Path(tmp), 80, 24)
assert not d["reused"] and d["tid"], d
d2 = mt.term_open(Path(tmp), 100, 30)
assert not d2["reused"] and d2["tid"] != d["tid"], "셸은 매번 새 세션(같은 워크트리 N개)"
assert mt._by_tid[d2["tid"]].cond is mt._by_tid[d["tid"]].cond, "전 세션 공유 Condition"
mt.term_kill(d2["tid"])
tid = d["tid"]

mt.term_input(tid, "echo TERM_$((40+2))\n")
term = mt._by_tid[tid]
deadline = time.time() + 15   # -il 셸 기동(rc 로드) 여유
while time.time() < deadline:
    with term.cond:
        if b"TERM_42" in bytes(term.history):
            break
    time.sleep(0.2)
else:
    raise AssertionError(f"PTY 출력 미도착: {bytes(term.history)[-300:]!r}")

mt.term_resize(tid, 120, 40)   # 예외 없이 통과하면 충분(WINSZ ioctl)
mt.term_kill(tid)
assert tid not in mt._by_tid, "kill 이 _by_tid 청소"
try:
    mt.term_input(tid, "x")
    raise AssertionError("kill 후 입력이 살아있음")
except ValueError:
    pass

# ── term_list — 새로고침 복원의 근거(고아 PTY 방지) ──
la = mt.term_open(Path(tmp), 80, 24)
lb = mt.term_open(Path(tmp), 80, 24)
lst = mt.term_list()["sessions"]
by = {s["tid"]: s for s in lst}
assert la["tid"] in by and lb["tid"] in by, "열린 세션이 목록에 없음"
assert by[la["tid"]]["root"] == str(Path(tmp).resolve()), "root 가 실제 경로여야"
assert by[la["tid"]]["agent"] is None and by[la["tid"]]["alive"] is True
order = [s["tid"] for s in lst]
assert order.index(la["tid"]) < order.index(lb["tid"]), "created 오름차순이 라벨(셸 N)의 근거"
mt.term_kill(la["tid"])
assert la["tid"] not in {s["tid"] for s in mt.term_list()["sessions"]}, "kill 후 목록에서 빠져야"
mt.term_kill(lb["tid"])

d3 = mt.term_open(Path(tmp), 80, 24)   # 아래 '에이전트는 별도 키' 비교용 셸

# ── 에이전트 attach 모드 — source/sid 검증 + 셸과 별도 세션 키 + CLI 실행 ──
for bad in [("evil", "abcd1234"), ("claude", "../x"), ("claude", "a"), ("codex", "bad sid"), ("claude", "-rf-danger"), ("claude", "--resume")]:  # leading dash 거부(codex P2)
    try:
        mt.term_open(Path(tmp), 80, 24, agent_source=bad[0], agent_sid=bad[1])
        raise AssertionError(f"검증 뚫림: {bad}")
    except ValueError:
        pass
mt._AGENT_CLIS["fake"] = lambda sid: ["sh", "-c", f"echo FAKE_{sid}; sleep 2"]   # argv 리스트(셸 문자열 조립 폐지)
d6 = mt.term_open(Path(tmp), 80, 24, agent_source="fake", agent_sid="sid0001")
assert not d6["reused"] and mt._by_tid[d3["tid"]].key == "" and mt._by_tid[d6["tid"]].key, "셸은 키 없음·에이전트만 키 보유"
assert {s["tid"]: s for s in mt.term_list()["sessions"]}[d6["tid"]]["agent"] == {"source": "fake", "sid": "sid0001"}, "에이전트 세션은 agent 필드가 실려야"
d7 = mt.term_open(Path(tmp), 80, 24, agent_source="fake", agent_sid="sid0001")
assert d7["reused"] and d7["tid"] == d6["tid"], "같은 에이전트 재진입은 재사용"
ag = mt._by_tid[d6["tid"]]
deadline = time.time() + 15
while time.time() < deadline:
    with ag.cond:
        if b"FAKE_sid0001" in bytes(ag.history):
            break
    time.sleep(0.2)
else:
    raise AssertionError(f"에이전트 CLI 출력 미도착: {bytes(ag.history)[-300:]!r}")
mt.term_kill(d6["tid"])
assert d6["tid"] not in mt._by_tid, "kill 이 _by_tid 청소"
d8 = mt.term_open(Path(tmp), 80, 24, agent_source="fake", agent_sid="sid0001")
assert not d8["reused"] and d8["tid"] != d6["tid"], "에이전트 kill 후엔 새 세션(_by_key 청소)"
mt.term_kill(d8["tid"])
mt.term_kill(d3["tid"])

# ── 죽은 세션 수거 — exit 한 셸의 시체가 history(최대 256KB)를 문 채 남으면 안 된다 ──
d9 = mt.term_open(Path(tmp), 80, 24)
sh9 = mt._by_tid[d9["tid"]]
mt.term_input(d9["tid"], "exit\n")
deadline = time.time() + 15
while time.time() < deadline:
    with sh9.cond:
        if not sh9.alive:
            break
    time.sleep(0.2)
else:
    raise AssertionError("셸 exit 후에도 세션이 살아있음")
mt._reap_idle()
assert d9["tid"] not in mt._by_tid, "죽은 셸은 _reap_idle 이 수거(시체 누적 방지)"

# 에이전트 CLI 가 스스로 끝나도 _by_key 까지 청소돼야 다음 attach 가 새로 열린다
d10 = mt.term_open(Path(tmp), 80, 24, agent_source="fake", agent_sid="sid0002")
ag2 = mt._by_tid[d10["tid"]]
deadline = time.time() + 15   # fake CLI 는 sleep 2 후 스스로 종료
while time.time() < deadline:
    with ag2.cond:
        if not ag2.alive:
            break
    time.sleep(0.2)
else:
    raise AssertionError("fake CLI 종료 후에도 에이전트 세션이 살아있음")
mt._reap_idle()
assert d10["tid"] not in mt._by_tid, "죽은 에이전트 세션도 수거"
assert not mt._by_key, f"reap 이 _by_key 까지 청소: {mt._by_key}"

# ── reap 경합 흡수 — stale 을 락 안에서 뽑고 kill 은 락 밖이라, 그 사이 다른 요청이 수거하면
#    _get 이 ValueError 를 던진다. 새면 term_open/term_list 가 500 이 된다 ──
d11 = mt.term_open(Path(tmp), 80, 24)
mt._by_tid[d11["tid"]].last = 0                       # 즉시 stale
_o = mt.term_kill
mt.term_kill = lambda tid: (_ for _ in ()).throw(ValueError("경합"))
try:
    mt._reap_idle()                                   # 흘리면 여기서 터진다
finally:
    mt.term_kill = _o
mt.term_kill(d11["tid"])

print("ok term open/reuse/io/resize/kill + agent attach(검증·별도 키·CLI 실행) + 죽은 세션 수거 + reap 경합 흡수")

# ── 사이드바 라벨의 재료 — 지금 뭐가 돌고 뭐가 마지막으로 나왔나 ──
# "셸 1" 은 어느 게 어느 건지 알려주지 않는다(형). tmux 처럼 실행 중인 명령을 이름으로 쓰고
# 마지막 출력을 부제로 깐다. 둘 다 백엔드만 알 수 있다(fg 는 tcgetpgrp, preview 는 링버퍼).
lb = mt.term_open(Path(tmp), 80, 24)
mt.term_input(lb["tid"], "echo hi-there\n")
# 둘 다 자리잡을 때까지 기다린다 — 커널 tty 가 친 글자를 zsh 보다 **먼저** 에코해서, "hi-there 보이면 통과"로
# 짜면 프롬프트가 아직 없는 순간에 빠져나와 cmd 가 빈다(이 작업에서 한 번 데인 레이스).
deadline = time.time() + 15
while time.time() < deadline:
    row = {s["tid"]: s for s in mt.term_list()["sessions"]}[lb["tid"]]
    if row.get("preview") == "hi-there":
        break
    time.sleep(0.2)
else:
    raise AssertionError(f"preview 미도착: {row.get('preview')!r}")
assert "\x1b[" not in row["preview"], f"preview 에 ANSI 가 남음(사이드바에 제어문자가 새 나온다): {row['preview']!r}"
assert "\b" not in row["preview"], f"preview 에 백스페이스가 남음: {row['preview']!r}"
assert row.get("fg") in (None, ""), f"유휴 셸은 fg 가 없어야(zsh 를 이름으로 쓰면 알아볼 게 없다): {row.get('fg')!r}"
# 유휴여도 이름이 있어야 한다 — "셸 1" 은 어느 게 어느 건지 안 알려준다(형).
# 안 돌고 있으면 마지막으로 친 명령이 그 세션의 정체다.
assert row.get("cmd") == "echo hi-there", f"유휴 셸의 이름 = 마지막으로 친 명령: {row.get('cmd')!r}"

# 부제는 178px 안에 들어가야 쓸모가 있다 — 프롬프트 접두사를 안 떼면 잘려서 호스트명만 보인다.
# 백스페이스도 '적용'해야 한다(zsh 자동완성이 s\bsleep 처럼 쓰고 지운다 — 그냥 지우면 ssleep).
assert not _re.match(r"^\S+@\S+\s+\S+\s*[%$#]\s", row["preview"]), \
    f"preview 에 프롬프트 접두사가 남음(사이드바에서 잘려 호스트명만 보인다): {row['preview']!r}"
assert mt._preview.__doc__, "preview 헬퍼가 사라짐"
# 좁은 칸에서 zsh ZLE 가 명령을 CR·EL 로 다시 그려 어느 한 줄에도 원문이 없다(45칼럼 실측:
# `npm run b` + `uild` 두 줄). 그래서 이름은 스크롤백이 아니라 **친 바이트**에서 잡는다.
_t = mt.term_open(Path(tmp), 45, 23)
_tm = mt._by_tid[_t["tid"]]
mt._note_typed(_tm, "npm run build\n")
assert _tm.cmd == "npm run build", f"친 명령을 그대로 잡아야: {_tm.cmd!r}"
mt._note_typed(_tm, "ech")
mt._note_typed(_tm, "\x7fho hi\r")
assert _tm.cmd == "echo hi", f"백스페이스 반영: {_tm.cmd!r}"
mt._note_typed(_tm, "rm -rf /\x03")
assert _tm.cmd == "echo hi", f"Ctrl-C 로 버린 줄이 명령이 되면 안 된다: {_tm.cmd!r}"
mt._note_typed(_tm, "\x1b[A\r")
assert _tm.cmd == "echo hi", f"제어 시퀀스가 이름을 지우면 안 된다: {_tm.cmd!r}"
mt._note_typed(_tm, "export TOKEN=ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r")
assert "ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" not in _tm.cmd, f"이름에도 비밀값 마스킹: {_tm.cmd!r}"
mt.term_kill(_t["tid"])
assert mt._apply_bs("s\bsleep 60") == "sleep 60", "백스페이스를 지우기만 하면 ssleep 이 된다"
assert mt._PROMPT_PREFIX_RE.sub("", "u@h dir % npm run dev") == "npm run dev", "프롬프트 접두사 제거"
assert mt._PROMPT_PREFIX_RE.sub("", "Progress: 50% done") == "Progress: 50% done", \
    "출력 줄이 프롬프트로 오인되면 안 된다(% 가 들어간 정상 출력)"

mt.term_input(lb["tid"], "sleep 25\n")
deadline = time.time() + 15
while time.time() < deadline:
    row = {s["tid"]: s for s in mt.term_list()["sessions"]}[lb["tid"]]
    if row.get("fg"):
        break
    time.sleep(0.2)
else:
    raise AssertionError("실행 중인 명령이 fg 로 안 잡힘")
assert row["fg"].startswith("sleep"), f"fg 가 실행 중인 명령이어야: {row['fg']!r}"

# 비밀값은 사이드바에 뿌리면 안 된다 — 셸 스크롤백엔 섞인다(저장소의 redact_text 를 태운다)
mt.term_input(lb["tid"], "\x03")          # sleep 중단
time.sleep(0.5)
mt.term_input(lb["tid"], "echo 'export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI0K7MDENGbPxRfiCY'\n")
deadline = time.time() + 15
while time.time() < deadline:
    row = {s["tid"]: s for s in mt.term_list()["sessions"]}[lb["tid"]]
    if row.get("preview") and "AWS_SECRET" in row["preview"]:
        break
    time.sleep(0.2)
else:
    raise AssertionError(f"테스트 준비 실패 — preview 에 그 줄이 안 옴: {row.get('preview')!r}")
assert "wJalrXUtnFEMI0K7MDENGbPxRfiCY" not in row["preview"], f"비밀값이 마스킹 안 됨: {row['preview']!r}"
mt.term_kill(lb["tid"])

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
# 명령을 `echo MUX'_A'` 로 인용한다 — 에코되는 명령 텍스트엔 MUX_A 가 없고 실행 결과에만 있다.
# 커널 tty 라인 디시플린이 zsh 기동 전에 명령을 그대로 에코하므로, 그냥 `echo MUX_A` 를 쓰면
# "MUX_A 가 보인다"가 원시 에코만으로 충족돼 아래 단언들이 실제 출력을 기다리지 않는다.
mt.term_input(ma["tid"], "echo MUX'_A'\n")
mt.term_input(mb["tid"], "echo MUX'_B'\n")
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

# 새로고침 재연결 — snap 도 tid 별로 자기 스크롤백만 실어야. 위 단언은 snap 경로를 못 잡는다:
# 최초 구독 땐 history 가 비어 있어 MUX_A/B 가 전부 out 으로 오기 때문(뮤테이션으로 확인).
h5 = _FakeHandler()
t5 = _th.Thread(target=mt.term_stream, args=(h5, [ma["tid"], mb["tid"]], {}), daemon=True)
t5.start()
deadline = time.time() + 10
while time.time() < deadline:
    ev5 = _events(h5)
    sa = "".join(_b64s(o) for e, o in ev5 if o and e == "snap" and o.get("tid") == ma["tid"])
    sb = "".join(_b64s(o) for e, o in ev5 if o and e == "snap" and o.get("tid") == mb["tid"])
    if "MUX_A" in sa and "MUX_B" in sb:
        break
    time.sleep(0.2)
else:
    raise AssertionError(f"재연결 snap 미도착: {bytes(h5.buf)[-300:]!r}")
assert "MUX_B" not in sa and "MUX_A" not in sb, "snap 이 남의 스크롤백을 실음"

def _settle(h, tid):
    """PTY 가 조용해지고 스트림이 그걸 다 뱉을 때까지 기다린 뒤 off 고수위를 돌려준다.
    한 명령은 tty 에코 → 프롬프트 재렌더 → ZLE 재에코 → 실제 출력으로 여러 번에 나눠 도착하니,
    출력 한복판에서 off 를 집으면 올바른 구현인데도 재개 구간에 나머지가 실린다.
    (이 대기의 게이트는 호출부의 술어다 — 그 술어가 tty 에코만으로 충족되면 여기서 못 막는다:
     zsh -il 이 rc 를 소싱하는 동안 PTY 는 확인 창보다 오래 조용할 수 있다. 그래서 명령을 인용한다.)"""
    term = mt._by_tid[tid]
    deadline = time.time() + 20
    while time.time() < deadline:
        with term.cond:
            end = term.base + len(term.history)
        offs = [o["off"] for e, o in _events(h) if o and o.get("tid") == tid and "off" in o]
        if offs and max(offs) == end:          # 스트림이 PTY 를 따라잡음
            time.sleep(0.5)                    # 더 나올 게 없는지 한 번 더 확인
            with term.cond:
                if term.base + len(term.history) == end:
                    return end
        time.sleep(0.1)
    raise AssertionError("PTY 가 조용해지지 않음(off 고수위를 못 정함)")

# from 재개 — 오프셋 이후만, 중복 없이
off_a = _settle(h1, ma["tid"])
h2 = _FakeHandler()
t2 = _th.Thread(target=mt.term_stream, args=(h2, [ma["tid"]], {ma["tid"]: off_a}), daemon=True)
t2.start()
mt.term_input(ma["tid"], "echo RESUM'ED'\n")   # 위와 같은 이유로 인용 — 에코엔 RESUMED 가 없다
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
t1.join(timeout=5); t2.join(timeout=5); t3.join(timeout=5); t5.join(timeout=5)
assert not t1.is_alive(), "모든 세션이 죽으면 스트림이 끝나야"
assert any(e == "exit" for e, _ in _events(h1)), "exit 이벤트 없음"

# 썩은 tid 는 raise 가 아니라 exit — 하나 때문에 살아있는 터미널 전부의 스트림이 죽으면 안 된다.
# 중복 tid 도 함께 태운다 — 쿼리스트링은 신뢰할 수 없고, 중복이 남으면 종료 조건(exited==terms)이
# 영영 안 맞아 스트림이 안 끝난다(아래 t4 join 이 그걸 잡는다).
mc = mt.term_open(Path(tmp), 80, 24)
h4 = _FakeHandler()
t4 = _th.Thread(target=mt.term_stream, args=(h4, ["deadbeef", mc["tid"], mc["tid"]], {}), daemon=True)
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
assert not t4.is_alive(), "중복 tid 스트림이 안 끝남(exited 집합 vs terms 리스트 길이 불일치)"
assert sum(1 for e, o in _events(h4) if e == "exit" and o.get("tid") == mc["tid"]) == 1, "중복 tid 에 exit 이 두 번"
try:
    mt.term_stream(_FakeHandler(), [], {})
    raise AssertionError("tid 가 아예 없으면 raise 해야")
except ValueError:
    pass
# 문자열은 시끄럽게 거부 — str 도 iterable 이라 그냥 두면 글자 단위로 순회해 200 OK 에 글자마다
# 가짜 exit 을 뱉는다(핸들러가 .split(",") 를 빠뜨려도 안 터지고 터미널만 이유 없이 죽어 보인다)
try:
    mt.term_stream(_FakeHandler(), "abc123", {})
    raise AssertionError("문자열 tids 는 TypeError 여야(글자 단위 순회로 조용히 오동작)")
except TypeError:
    pass

# ── 단일 pass 계약 — terms·gone 이 같은 스냅샷에서 파생돼 서로소여야 한다 ──
# 조회 사이에 키가 증발하는 dict 로 경쟁(_reap_idle 이 두 순회 사이에 끼어듦)을 재현한다.
# 스레드·타이밍 없이 결정론적: 두 번 순회하면 같은 tid 가 terms·gone 양쪽에 들어가 exit 이 두 번 난다.
class _RacyDict(dict):
    """지목한 키를 첫 .get() 직후 떨군다 — _reap_idle 이 그 순간 수거한 것과 같다."""
    def __init__(self, src, drop):
        super().__init__(src)
        self._drop = drop
    def get(self, k, default=None):
        v = super().get(k, default)
        if k == self._drop:
            self.pop(k, None)
        return v

md = mt.term_open(Path(tmp), 80, 24)
_real = mt._by_tid
mt._by_tid = _RacyDict(_real, md["tid"])
h6 = _FakeHandler()
t6 = _th.Thread(target=mt.term_stream, args=(h6, [md["tid"]], {}), daemon=True)
t6.start()
deadline = time.time() + 10
while time.time() < deadline and not any(e == "snap" for e, _ in _events(h6)):
    time.sleep(0.05)   # snap 이 보이면 해석이 끝난 시점 — 그 전에 복원하면 경쟁이 재현되지 않는다
mt._by_tid = _real
assert any(e == "snap" for e, _ in _events(h6)), "RacyDict 아래서 스트림이 시작도 못 함"
mt.term_kill(md["tid"]); t6.join(timeout=5)
_n = sum(1 for e, o in _events(h6) if e == "exit" and o.get("tid") == md["tid"])
assert _n == 1, f"단일 pass 계약 위반 — 같은 tid 에 exit 이 {_n}번(terms·gone 양쪽에 들어감)"
print("ok 멀티플렉스 SSE(tid 태그·from 재개·snap 폴백·썩은 tid 격리)")

# ── 핸들러 배선 — 쿼리스트링 → term_stream 인자 계약을 실요청으로 검증 ──
# 위 SSE 테스트는 전부 term_stream 을 직접 부르며 _FakeHandler 로 쿼리 파싱을 통째로 건너뛴다.
# Task 3 이 term_stream 시그니처를 list[str] 로 바꿨을 때 핸들러가 맨 문자열을 계속 넘기는데도
# 아무 테스트가 안 터진 게 정확히 이 구멍이다. 셸을 실행하는 라우트에서 grep 이 최후 방어선이면 안 된다.
import socket, threading
from http.server import ThreadingHTTPServer
import marina_handler as MH

srv = ThreadingHTTPServer(("127.0.0.1", 0), MH.Handler)   # port 0 = 커널이 빈 포트 배정(다른 세션 대시보드와 무관)
threading.Thread(target=srv.serve_forever, daemon=True).start()
_host, _port = srv.server_address[:2]

def _raw_get(path, headers="", want=0, timeout=20):
    """실제 HTTP GET — SSE 는 안 끝나니 이벤트가 want 개 모이면(또는 timeout) 끊는다.
    핸들러가 HTTP/1.0(protocol_version 미설정)이라 청크 인코딩 없이 본문이 그대로 온다."""
    s = socket.create_connection((_host, _port), timeout=timeout)
    # Host 는 진짜 값이어야 — /api/* 는 DNS 리바인딩 가드(host_allowed) 뒤라 아무 값이나 쓰면 403 이다
    s.sendall(f"GET {path} HTTP/1.1\r\nHost: {_host}:{_port}\r\n{headers}Connection: close\r\n\r\n".encode())
    s.settimeout(0.3)
    buf, deadline = b"", time.time() + timeout
    while time.time() < deadline:
        try:
            b = s.recv(65536)
            if not b:
                break
            buf += b
        except socket.timeout:
            pass
        head, sep, body = buf.partition(b"\r\n\r\n")
        if sep and want and body.count(b"\n\n") >= want:
            break
        if sep and not want and body:
            break
    s.close()
    head, _, body = buf.partition(b"\r\n\r\n")
    status = int(head.split(b" ")[1]) if head else 0
    return status, head, body

class _BufShim:                 # _events 는 .buf 만 본다
    def __init__(self, body): self.buf = bytearray(body)

try:
    ha = mt.term_open(Path(tmp), 80, 24)
    hb = mt.term_open(Path(tmp), 80, 24)

    # term-list — 새로고침 복원이 읽는 인벤토리 모양
    st, _, body = _raw_get("/api/term-list")
    assert st == 200, f"term-list 가 {st}"
    lst = _json.loads(body)["sessions"]
    row = {s["tid"]: s for s in lst}.get(ha["tid"])
    assert row, f"열린 세션이 term-list 응답에 없음: {body[:200]!r}"
    assert row["root"] == str(Path(tmp).resolve()) and row["agent"] is None and row["alive"] is True
    assert isinstance(row["created"], float), "created 가 정렬 가능한 수여야(라벨 '셸 N'의 근거)"

    # ?tid=a,b — 쿼리 파싱이 진짜로 되는지. 맨 문자열이 넘어가면 term_stream 이 TypeError 를 던져
    # 200 조차 못 나가고(500), .split(",") 만 빠져도 tid 가 "a,b" 한 덩이라 snap 이 0 개다.
    st, _, body = _raw_get(f"/api/term-stream?tid={ha['tid']},{hb['tid']}", want=2)
    assert st == 200, f"term-stream 이 {st} — 핸들러↔term_stream 배선이 깨짐: {body[:200]!r}"
    snaps = {o["tid"] for e, o in _events(_BufShim(body)) if e == "snap" and o}
    assert snaps == {ha["tid"], hb["tid"]}, f"두 tid 다 snap 이 와야(쿼리 파싱): {snaps}"

    # from=tid:off — 파싱만 확인(재개 의미는 위 _settle 블록이 이미 단언). 잘못된 값은 버리고 snap 폴백.
    st, _, body = _raw_get(f"/api/term-stream?tid={ha['tid']}&from={ha['tid']}:0,junk,{hb['tid']}:x", want=1)
    assert st == 200 and any(e in ("snap", "out") for e, _ in _events(_BufShim(body))), \
        f"잘못된 from 이 스트림을 죽임(버리고 snap 폴백해야): {body[:200]!r}"

    # 썩은 tid 단독 → exit 통지지 400 이 아니다(프론트가 캐시된 목록으로 영구 재연결하는 걸 막는다)
    st, _, body = _raw_get("/api/term-stream?tid=deadbeef", want=1)
    assert st == 200, f"썩은 tid 가 {st} — exit 통지여야"
    assert any(e == "exit" and o.get("tid") == "deadbeef" for e, o in _events(_BufShim(body))), \
        f"썩은 tid 에 exit 이 없음: {body[:200]!r}"

    # tid 없음 → 400 (term_stream 의 ValueError 를 핸들러가 받는 경로)
    st, _, _ = _raw_get("/api/term-stream")
    assert st == 400, f"tid 없는 스트림이 {st}"

    # 게이트웨이 경유 거부 — 터미널 = 원격 코드 실행. 두 라우트 다 덮어야.
    for p in ("/api/term-list", f"/api/term-stream?tid={ha['tid']}"):
        st, _, _ = _raw_get(p, headers="X-Forwarded-For: 1.2.3.4\r\n")
        assert st == 403, f"{p} 가 X-Forwarded-For 에 {st} — 403 이어야"
        st, _, _ = _raw_get(p, headers="X-Forwarded-Host: evil\r\n")
        assert st == 403, f"{p} 가 X-Forwarded-Host 에 {st} — 403 이어야"

    mt.term_kill(ha["tid"]); mt.term_kill(hb["tid"])
finally:
    srv.shutdown(); srv.server_close()   # 임시 포트라도 스레드·소켓은 반드시 정리

print("ok 핸들러 라우트(term-list 모양·다중 tid 파싱·from·썩은 tid=exit·가드 403)")
PY

# 핸들러 계약 — 터미널 = 원격 코드 실행: 게이트웨이 경유(X-Forwarded-*) 거부 + 엔드포인트 존재
grep -q 'x-forwarded-for' "$SCR/marina_handler.py" || { echo "FAIL: 터미널 게이트웨이 가드 없음"; exit 1; }
grep -q '"/api/term-stream"' "$SCR/marina_handler.py" || { echo "FAIL: term-stream 엔드포인트 없음"; exit 1; }
grep -q '"/api/term-open"' "$SCR/marina_handler.py" || { echo "FAIL: term-open 엔드포인트 없음"; exit 1; }
grep -q '"/api/term-list"' "$SCR/marina_handler.py" || { echo "FAIL: term-list 엔드포인트 없음"; exit 1; }
grep -q 'term_list' "$SCR/marina_handler.py" || { echo "FAIL: term_list 미배선"; exit 1; }
grep -q 'froms' "$SCR/marina_handler.py" || { echo "FAIL: term-stream from 오프셋 파싱 없음"; exit 1; }
grep -q '"/api/term-stream", "/api/term-list"' "$SCR/marina_handler.py" \
  || { echo "FAIL: term-list 가 게이트웨이 가드 분기 밖(term-stream 과 같은 튜플이어야)"; exit 1; }

# 프론트 계약 — 입력 직렬 큐(병렬 fetch 유실 방지)·vendor 로드·탭 활성화
J="$SCR/marina-web/app-10-term.js"
IO="$SCR/marina-web/app-10b-term-io.js"
grep -q "queues" "$IO" || { echo "FAIL: tid별 입력큐 없음(전역 큐 한 벌이면 탭끼리 글자가 샌다)"; exit 1; }
grep -q "chain" "$IO" || { echo "FAIL: 입력 직렬 큐 없음(병렬 fetch 는 글자 유실)"; exit 1; }
grep -q "term-stream?tid=" "$IO" || { echo "FAIL: 멀티플렉스 구독 없음"; exit 1; }
grep -q "app-10b-term-io.js" "$SCR/marina-web/index.html" || { echo "FAIL: io 스크립트 미로드"; exit 1; }
if command -v node >/dev/null 2>&1; then
  node --check "$IO" || { echo "FAIL: 문법 오류 $IO"; exit 1; }
  # grep 은 "있다"만 본다 — 백오프 재무장·400=exit·요청 시퀀싱은 전부 grep 을 통과하며 깨진다.
  # 스텁(fetch/EventSource/api)으로 io 레이어를 실제로 돌려 구조를 검증한다.
  node "$HERE/term-io-harness.js" || { echo "FAIL: term-io 하네스"; exit 1; }
fi
grep -q "WS_VIEWS.term" "$J" || { echo "FAIL: 터미널 탭 등록 없음"; exit 1; }
grep -q "function openAgentTerminal" "$J" || { echo "FAIL: AGENTS→터미널 attach 진입점 없음(오르카)"; exit 1; }
# 뷰 계약 — 사이드바·분할 그리드·복원·D&D, 그리고 io 경계(뷰는 HTTP 를 모른다)
grep -q "data-term-side" "$J" || { echo "FAIL: 사이드바 없음"; exit 1; }
grep -q "data-term-grid" "$J" || { echo "FAIL: 분할 그리드 없음"; exit 1; }
grep -q "termLayoutKey\|marinaTermLayout" "$J" || { echo "FAIL: 레이아웃 복원(localStorage) 없음"; exit 1; }
grep -q "dragstart" "$J" || { echo "FAIL: 사이드바→칸 D&D 없음"; exit 1; }
grep -q "TermIO" "$J" || { echo "FAIL: io 레이어 미사용(뷰가 HTTP 를 직접 부름)"; exit 1; }
# SSE 가 끊긴 사이 PTY 가 죽으면 exit 이 영영 안 온다(재연결은 살아있는 tid 만 구독) — 목록을 바로잡는
# 유일한 경로가 io 의 백오프 재시도(refresh)라, 뷰가 'sessions' 를 안 들으면 유령 행이 남는다.
grep -q "TermIO.on('sessions'" "$J" || { echo "FAIL: sessions 훅 없음(SSE 끊긴 사이 죽은 세션이 유령으로 남음)"; exit 1; }
# 배치 규칙은 한 곳(termOpenSlotFor)이어야 — 사이드바 클릭과 새 셸이 갈리면 4분할에 빈 칸이 셋 있어도
# 세션을 누를 때마다 활성 칸을 덮어쓴다(형: "셸 누를 때마다 터미널 위치가 이상하다").
grep -q "function termOpenSlotFor" "$J" || { echo "FAIL: 배치 규칙이 함수로 안 모임"; exit 1; }
# resize 는 실제로 바뀐 값만 보내야 — TIOCSWINSZ 는 크기가 같아도 SIGWINCH 를 쏘고, 렌더가 3초 폴링으로
# 도니까 무조건 보내면 zsh 가 3초마다 프롬프트를 다시 그려 화면이 한 줄씩 먹힌다(형 실사용 리포트).
grep -q "function termSyncSize" "$J" || { echo "FAIL: resize 게이트 없음(SIGWINCH 폭풍)"; exit 1; }
# 사이드바 폭 드래그(형 요청) — 깃 탭 gs-rail 과 같은 패턴: 드래그·더블클릭 리셋·localStorage 기억
grep -q "data-term-rail" "$J" || { echo "FAIL: 사이드바 폭 드래그 레일 없음"; exit 1; }
grep -q "marinaTermSideW" "$J" || { echo "FAIL: 사이드바 폭이 안 기억됨"; exit 1; }
grep -q "ondblclick" "$J" || { echo "FAIL: 더블클릭 기본 폭 복귀 없음"; exit 1; }
grep -q "term-rail" "$SCR/marina-web/styles.css" || { echo "FAIL: 레일 스타일 없음(잡을 면적이 없다)"; exit 1; }
grep -q "sentCols" "$J" || { echo "FAIL: 마지막 전송 치수를 안 기억함"; exit 1; }
! grep -qE "^\s+TermIO\.resize\(tid, inst\.term\.cols" "$J" || { echo "FAIL: 무조건 resize 부활"; exit 1; }
[ "$(grep -c "termOpenSlotFor(" "$J")" -ge 3 ] || { echo "FAIL: 배치 규칙 호출부 부족 — 클릭·새 셸이 같은 규칙을 써야"; exit 1; }
! grep -q "termPlace(termFocus," "$J" || { echo "FAIL: 활성 칸 하드코딩 배치 부활(빈 칸을 무시하고 덮어씀)"; exit 1; }
# 경계는 fetch 만이 아니다 — api()·EventSource 도 똑같이 뷰가 백엔드를 직접 만지는 것이다
grep -qE "fetch\(|[^.]\bapi\(|EventSource" "$J" && { echo "FAIL: 뷰가 HTTP 를 직접 부름(fetch·api·EventSource) — io 경계 위반"; exit 1; }
grep -q "openAgentTerminal" "$SCR/marina-web/app-5-sessions.js" || { echo "FAIL: AGENTS 행 클릭=attach 배선 없음"; exit 1; }
grep -q "data-agent-peek" "$SCR/marina-web/app-5-sessions.js" || { echo "FAIL: '대화' 읽기 전용 버튼 없음"; exit 1; }
grep -q "vendor-xterm.js" "$SCR/marina-web/index.html" || { echo "FAIL: xterm vendor 로드 없음"; exit 1; }
! grep -q 'data-ws-tab="term" disabled' "$SCR/marina-web/index.html" || { echo "FAIL: 터미널 탭이 여전히 disabled"; exit 1; }
if command -v node >/dev/null 2>&1; then node --check "$J" || { echo "FAIL: 문법 오류 $J"; exit 1; }; fi
echo "PASS test-term"
