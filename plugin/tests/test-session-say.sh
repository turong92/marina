#!/usr/bin/env bash
# marina session say <프로젝트/이름> <글> — 그 채팅방에 사람이 말한 것처럼 글을 넣는다(예약 브리핑이 부른다).
# 꺼진 방은 wake 와 같은 경로(방 잠금 + start_with_launch_env)로 띄우며 첫 지시로, 떠 있는 방은 쉬는 순간 입력창에 친다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
printf '{"projects":{"/elsewhere":{"hasTrustDialogAccepted":true}},"keep":1}\n' > "$MARINA_CLAUDE_JSON"
msess new chat shopping >/dev/null 2>&1 || fail "new chat"
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new dev"

# 없는 방·개발 방은 분명한 오류
out="$(msess say nope/none 안녕 2>&1)" && fail "없는 방이 성공함"
echo "$out" | grep -q "세션을 찾지 못했어" || fail "없는 방 안내: $out"
out="$(msess say proj/feat/a 안녕 2>&1)" && fail "개발 방이 성공함"
echo "$out" | grep -q "채팅방이 아니야" || fail "개발 방 안내: $out"

# 꺼진 방: 띄우면서 첫 지시로 준다
msess stop chat/shopping >/dev/null 2>&1 || fail "stop"
out="$(msess say chat/shopping '아침 브리핑: 일정 정리해줘' 2>&1)" || fail "꺼진 방 say 실패: $out"
[ "$(echo "$out" | wc -l | tr -d ' ')" = 1 ] || fail "출력은 한 줄: $out"
echo "$out" | grep -q "chat/shopping" || fail "어디에 넣었는지: $out"
has_first() { python3 - "$FAKE_OUT" "$@" <<'PY'
import glob, sys
need = sys.argv[2:]
for f in glob.glob(sys.argv[1] + "/*/argv"):
    args = [x.decode("utf-8", "replace") for x in open(f, "rb").read().split(b"\0")]
    if any(all(n in x for n in need) for x in args): sys.exit(0)
sys.exit(1)
PY
}
for _ in $(seq 100); do has_first "아침 브리핑: 일정 정리해줘" && break; sleep 0.1; done
has_first "아침 브리핑: 일정 정리해줘" || fail "첫 지시로 글이 안 들어감"
has_first "아침 브리핑" "chat_id=1003" || fail "답할 채널(chat_id)이 첫 지시에 없음"

# 떠 있는 방: 쉬는 순간 입력창에 친다(run_slash) — 못 치면 오류
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import sys
import marina_session as ms
import marina_discord_bot as mb
import marina_discord_wake as mw
mw.SAY_CHECK_GAP = 0      # 확인 재시도 사이 대기 없이
fails = []
def check(c, m):
    if not c: fails.append(m)
check(ms.tmux_alive("chat-shopping"), "준비: 방이 떠 있어야 함")
calls = []
_orig_left = mw._left_in_input
mw._left_in_input = lambda tmux, text: False      # 진짜 판정은 아래에서 따로 — 여기선 가짜 claude 화면에 입력창이 없다
mb.run_slash = lambda tmux, cmd, ch, mid, **kw: (calls.append((tmux, cmd, ch, mid)), True)[1]
r = mw.say("chat/shopping", "오늘\n할 일 알려줘")
check(r == "delivered" and len(calls) == 1, f"떠 있으면 전달: {r} {calls}")
t, cmd, ch, mid = calls[0]
check(t == "chat-shopping" and ch == "1003" and "\n" not in cmd and "오늘 할 일 알려줘" in cmd, f"한 줄로 친다: {calls}")
# ① 제어문자(ESC·Ctrl-C 등)는 입력창에서 키 입력으로 해석된다 — 인쇄 가능한 글자만 남기고 길이 상한(/skill 인자와 같은 1500)
calls.clear()
mw.say("chat/shopping", "a\x1bb\x03c\x7fd\u200be\r\n\tf" + "가" * 5000)
cmd = calls[0][1]
check(all(c.isprintable() for c in cmd), f"제어문자가 입력창으로 샌다: {[c for c in cmd if not c.isprintable()]!r}")
check("abcde f" in cmd, f"글자는 남는다: {cmd[:120]!r}")
body = cmd.split("보내 줘: ", 1)[1]
check(len(body) == 1500, f"본문은 1500자까지만: {len(body)}")
check(len(cmd) < 1500 + 400, f"상한 없음: {len(cmd)}")
# ② 출처를 그대로 적는다 — 형이 직접 말한 것처럼 꾸미지 않는다. 비서가 '사람이 방에서 한 말이 아니다' 를 알아야 한다
calls.clear()
mw.say("chat/shopping", "메일 보내")
manual = calls[0][1]
check("형이 예약" not in manual and "형이 시킨" not in manual and "형이 말" not in manual, f"직접 부른 say 가 형 명의: {manual!r}")
check("사람이 방에서 직접 한 말이 아니" in manual and "marina session say" in manual, f"출처 문구(수동): {manual!r}")
calls.clear()
mw.say("chat/shopping", "아침 브리핑", source="brief")
sched = calls[0][1]
check("예약" in sched and "사람이 방에서 직접 한 말이 아니" in sched and "형이 예약" not in sched, f"출처 문구(예약): {sched!r}")
# ③ '쳤다' 와 '들어간 걸 확인했다' 를 구분한다 — 입력창에 글이 남아 있으면 typed
mw._left_in_input = lambda tmux, text: True
check(mw.say("chat/shopping", "남음") == "typed", "입력창에 남았는데 delivered")
mw._left_in_input = lambda tmux, text: False
check(mw.say("chat/shopping", "감") == "delivered", "남지 않았으면 delivered")
mw._left_in_input = _orig_left      # 진짜 판정: 마지막 ❯ 줄 이후(줄바꿈으로 이어진 칸 포함)에 글 머리·꼬리·붙여넣기 표시가 남았나
import types
_orig_tmux = ms._tmux
def pane(text):
    ms._tmux = lambda *a, **k: types.SimpleNamespace(stdout=text, returncode=0)
long = "[마리나] " + "가" * 200 + "끝맺음꼬리표시"
pane("❯ [마리나] 예전 글\n● 답했다\n❯ \n  ⏵⏵ bypass")
check(mw._left_in_input("t", long) is False, "보냈고 새 입력창이 비었는데 남았다고 판정")
pane("● 답\n❯ [마리나] " + "가" * 30 + "\n  " + "가" * 30 + "끝맺음꼬리표시\n  ⏵⏵ bypass")
check(mw._left_in_input("t", long) is True, "래핑돼 머리가 안 보여도 꼬리가 남았는데 못 잡음")
pane("● 답\n❯ [Pasted text #1 +3 lines]\n  ⏵⏵")
check(mw._left_in_input("t", long) is True, "붙여넣기 표시로 남은 걸 못 잡음")
pane("")
check(mw._left_in_input("t", long) is True, "화면을 못 읽으면 갔다고 단정하지 않는다(애매하면 미확인)")
# 입력창 아래 구분선 밑(상태줄·알림)에 글 조각이 있어도 입력창에 남은 게 아니다
pane("❯ \n" + "─" * 20 + "\n  [마리나] marina 알림\n  ⏵⏵")
check(mw._left_in_input("t", long) is False, "구분선 아래 줄을 입력창으로 읽었다")
# 실측 오탐: 방금 보낸 글이 ❯ 로 올라간 '기록'이 막 그려진 순간 — 곧 새 빈 입력창이 그려진다
echoed = "● 답\n❯ [마리나] marina session say 로 넣은 글이야 — " + "가" * 40 + " 보내\n  줘: 끝맺음꼬리표시\n  Called plugin:discord\n"
emptybox = echoed + "\n" + "─" * 20 + "\n❯ \n" + "─" * 20 + "\n  ⏵⏵"
frames = [echoed, echoed, emptybox]
import time as _t
def seq(fs):
    it = iter(fs); last = [fs[-1]]
    def f(*a, **k):
        try: last[0] = next(it)
        except StopIteration: pass
        return types.SimpleNamespace(stdout=last[0], returncode=0)
    return f
mb.run_slash = lambda *a, **k: True
ms._tmux = seq(frames)
check(mw.say("chat/shopping", "끝맺음꼬리표시") == "delivered", "Enter 직후엔 남아 보이다 곧 사라지는 화면을 한 번 보고 미확인으로 끝냈다")
ms._tmux = seq([echoed])           # 끝까지 남아 있으면 미확인 — 갔다고 지어내지 않는다
check(mw.say("chat/shopping", "끝맺음꼬리표시") == "typed", "계속 남아 있는데 delivered")
ms._tmux = seq([""])
check(mw.say("chat/shopping", "끝맺음꼬리표시") == "typed", "화면을 못 읽는데 delivered")
ms._tmux = _orig_tmux
ms._tmux = _orig_tmux
# 실측 실패: 글을 쳤는데 Enter 가 안 먹어 입력창에 남았다(긴 글은 붙여넣기 표시로 접혀 머리 글자가 안 보인다).
# 진짜 run_slash 가 남아 있는 동안 Enter 를 다시 눌러야 한다 — 그래도 안 되면 typed(안 갔는데 갔다고 하지 않는다)
import os as _os
class FakePane:
    def __init__(self, eats_after, folded=False): self.enters, self.eats_after, self.folded, self.typed, self.sent = 0, eats_after, folded, "", False
    def __call__(self, *a, **k):
        if a[0] == "send-keys" and "-l" in a: self.typed = a[-1]
        elif a[0] == "send-keys" and a[-1] == "Enter":
            self.enters += 1
            if self.enters >= self.eats_after: self.sent = True
        if a[0] == "capture-pane":
            if self.sent: out = "● 처리\n" + "─" * 20 + "\n❯ \n" + "─" * 20 + "\n  ⏵⏵"
            else:
                shown = "[Pasted text #1 +1 lines]" if self.folded else self.typed
                out = "● 답\n" + "─" * 20 + "\n❯ " + shown + "\n" + "─" * 20 + "\n  ⏵⏵"
            return types.SimpleNamespace(stdout=out, returncode=0)
        return types.SimpleNamespace(stdout="", returncode=0)
import importlib
real_run_slash = importlib.reload(mb).run_slash
mw.mb = mb
mb._pane_busy = lambda t: (True, False)
mb._input_empty = lambda t: True
ms.tmux_leave_mode = lambda t: None
mb.time.sleep = lambda s: None
_os.environ["MARINA_ENTER_DELAY"] = "0"
for eats, folded, want_enters in ((1, False, 1), (2, False, 2), (2, True, 2), (3, True, 3), (99, True, 4)):
    fp = FakePane(eats, folded); ms._tmux = fp
    real_run_slash("t", "[마리나] 긴 글 " + "가" * 200 + " 끝", "1003", "", poll=0, settle=0, timeout=5)
    check(fp.enters == want_enters, f"Enter 횟수(eats={eats}, 접힘={folded}): {fp.enters} != {want_enters}")
ms._tmux = FakePane(99, True)
mb.run_slash = real_run_slash
mw._left_in_input = _orig_left
mw.SAY_CHECK_GAP = 0
check(mw.say("chat/shopping", "안 먹는 Enter") == "typed", "Enter 가 끝내 안 먹었는데 delivered")
ms._tmux = FakePane(2, True)
check(mw.say("chat/shopping", "두 번째 Enter 에 먹음") == "delivered", "Enter 재시도로 들어갔는데 typed")
ms._tmux = _orig_tmux
mb.run_slash = lambda *a, **k: False
try:
    mw.say("chat/shopping", "또")
    check(False, "못 쳤는데 성공으로 끝남")
except ms.SessionError as exc:
    check("못" in str(exc), f"못 친 안내: {exc}")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-say"
