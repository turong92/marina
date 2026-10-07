#!/usr/bin/env bash
# 세션 죽음을 상시 감시 없이 안다: claude 가 스스로 끝나면 감싼 셸이 채널에 알린다.
# stop·rm 의 kill-session 은 셸째 죽으므로 알리지 않는다(일부러 끈 건 알림 0).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
notices() { local n; n="$(grep -c '"POST", "p": "/channels/[0-9]*/messages"' "$FD/log.jsonl" 2>/dev/null)" || true; echo "${n:-0}"; }
claude_pid() { ls -t "$FAKE_OUT" | head -1; }   # 가짜 claude 는 exec sleep 이라 폴더 이름 = 살아 있는 pid

msess new proj feat/one --no-start >/dev/null 2>&1 || fail "new"
for _ in $(seq 50); do ls "$FAKE_OUT"/*/argv >/dev/null 2>&1 && break; sleep 0.1; done   # 기동은 비동기
kill -TERM "$(claude_pid)"
for _ in $(seq 50); do [ "$(notices)" -ge 1 ] && break; sleep 0.1; done
[ "$(notices)" = 1 ] || fail "claude 가 스스로 끝났는데 알림이 없음(또는 여러 건): $(notices)"
notice_text() { python3 -c 'import json,sys; print("\n".join(e["b"]["content"] for e in map(json.loads, open(sys.argv[1])) if e["m"]=="POST" and e["p"].endswith("/messages")))' "$FD/log.jsonl"; }
notice_text | grep -q "꺼졌어" || fail "알림 문구: $(notice_text)"
notice_text | grep -q "글을 쓰면 다시 켜져" || fail "깨우기가 켜져 있으면 알림에 글을 쓰면 켜진다고 알려야 한다: $(notice_text)"
notice_text | grep -q "marina session start proj/feat/one" || fail "다시 켜는 명령 안내: $(notice_text)"

msess start feat/one >/dev/null || fail "start"
msess stop feat/one >/dev/null || fail "stop"
sleep 1
[ "$(notices)" = 1 ] || fail "stop 으로 끈 세션을 알림: $(notices)"
msess start feat/one >/dev/null || fail "start 2"
msess rm proj/feat/one >/dev/null 2>&1 || fail "rm"
sleep 1
[ "$(notices)" = 1 ] || fail "rm 으로 끈 세션을 알림: $(notices)"

# wake:false 면 "글을 쓰면 다시 켜져" 를 약속하지 않는다
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import json, sys
import marina_session as ms
sent = []
class FakeDiscord:
    def __init__(self, token): pass
    def send_message(self, ch, text): sent.append(text)
ms.Discord = FakeDiscord
ms.find_session = lambda ref: {"channelId": "C1"}
ms.read_token = lambda cfg: "t"
ms.load_config = lambda: {"wake": False}
ms.notify_exit("p/x", "1")
ms.load_config = lambda: {}
ms.notify_exit("p/x", "1")
if "글을 쓰면" in sent[0] or "글을 쓰면 다시 켜져" not in sent[1]:
    print("FAIL: wake:false 문구", sent); sys.exit(1)
PY
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 "$DSCRIPTS/marina_session.py" notify-exit nope/x 1 || fail "모르는 세션 알림이 실패 코드"
echo "PASS test-session-exit-notice"
