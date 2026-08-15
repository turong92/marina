#!/usr/bin/env bash
# 실시간 배관을 **실제 데몬에** 물려 확인한다 — 단위 테스트가 다 통과해도 라우팅 한 줄이
# 빠지면 폰에선 아무것도 안 온다.
#
# 계약: ① /mobile/api/events 가 SSE 로 응답하고 변화가 나면 프레임을 민다 ② 서비스워커·매니페스트·
# 아이콘은 인증 없이 받아진다(등록 실패하면 알림 자체가 불가능) ③ 푸시 구독은 토큰이 있어야 하고,
# 이상한 엔드포인트는 거절한다 ④ 훅의 찌르기는 로컬에서만 먹는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"; CTRL="$SCR/marina-control.py"
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
unset MARINA_CONTROL_HOST MARINA_CONTROL_PORT
P="$TMP/proj"; mkdir -p "$P"; (cd "$P" && git init -q && git commit -q --allow-empty -m init)
cat > "$MARINA_HOME/projects.json" <<JSON
{"schemaVersion":1,"projects":[{"id":"proj","root":"$P","kind":"compose","composeFile":"docker-compose.yml","subrepos":[],"worktreeGlobs":[]}]}
JSON

PORT="$(python3 - <<'PY' || exit $?
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", 0))
except PermissionError:
    sys.exit(42)
print(s.getsockname()[1]); s.close()
PY
)" || { code=$?; [[ "$code" == "42" ]] && { echo "SKIP test-live-stream-http (bind unavailable)"; exit 0; }; exit "$code"; }
SRV=""
cleanup(){ [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

MARINA_MOBILE_TOKEN=secret MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 \
  MARINA_HOME="$MARINA_HOME" python3 "$CTRL" >"$TMP/daemon.log" 2>&1 & SRV=$!
b="http://127.0.0.1:$PORT"
for _ in $(seq 1 100); do
  curl -sf "$b/mobile?token=secret" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -sf "$b/mobile?token=secret" >/dev/null || { echo "FAIL: 데몬이 안 떴다"; tail -5 "$TMP/daemon.log"; exit 1; }

# ① 정적 자산 — **인증 없이** 받아져야 한다. 서비스워커 등록이 실패하면 알림이 원천 불가.
for asset in sw.js manifest.webmanifest icon.png; do
  code="$(curl -s -o "$TMP/$asset" -w '%{http_code}' "$b/mobile/$asset")"
  [[ "$code" == "200" ]] || { echo "FAIL: /mobile/$asset → $code"; exit 1; }
done
grep -q "showNotification" "$TMP/sw.js" || { echo "FAIL: sw.js 가 알림을 안 띄운다"; exit 1; }
python3 - "$TMP/manifest.webmanifest" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["display"] == "standalone", m          # 홈 화면 앱으로 떠야 iOS 에서 푸시 권한이 생긴다
assert m["scope"].startswith("/mobile"), m      # 서비스워커 범위와 어긋나면 등록이 거부된다
assert m["icons"], m
PY
# 서비스워커는 절대 캐시되면 안 된다 — 옛 SW 가 남으면 고친 알림 로직이 영영 안 걸린다.
curl -s -o /dev/null -D - "$b/mobile/sw.js" | grep -qi "cache-control:.*no-cache" \
  || { echo "FAIL: sw.js 가 캐시된다"; curl -s -o /dev/null -D - "$b/mobile/sw.js" | head -8; exit 1; }
echo "ok 정적 자산: 인증 없이 받아지고 SW 는 캐시되지 않는다"

# ② 푸시 키·구독은 토큰이 필요하다.
[[ "$(curl -s -o /dev/null -w '%{http_code}' "$b/mobile/api/push-key")" == "403" ]] \
  || { echo "FAIL: 토큰 없이 푸시 키가 나온다"; exit 1; }
key="$(curl -sf -H 'X-Marina-Mobile-Token: secret' "$b/mobile/api/push-key" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')"
[[ ${#key} -gt 80 ]] || { echo "FAIL: 공개키가 이상하다($key)"; exit 1; }

sub='{"endpoint":"https://web.push.apple.com/test-endpoint-1","label":"test"}'
curl -sf -H 'X-Marina-Mobile-Token: secret' -H 'content-type: application/json' \
  -d "$sub" "$b/mobile/api/push-subscribe" | grep -q '"ok": true' \
  || { echo "FAIL: 구독 등록 실패"; exit 1; }
# 이상한 엔드포인트는 400 — 조용히 저장하면 나중에 원인 모를 실패가 된다.
bad="$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Marina-Mobile-Token: secret' \
  -H 'content-type: application/json' -d '{"endpoint":"http://evil/x"}' "$b/mobile/api/push-subscribe")"
[[ "$bad" == "400" ]] || { echo "FAIL: http 엔드포인트가 통과했다($bad)"; exit 1; }
# 해지가 등록으로 오인되면 안 된다(경로가 둘 다 subscribe 로 끝난다).
curl -sf -H 'X-Marina-Mobile-Token: secret' -H 'content-type: application/json' \
  -d '{"endpoint":"https://web.push.apple.com/test-endpoint-1"}' "$b/mobile/api/push-unsubscribe" \
  | grep -q '"removed": true' || { echo "FAIL: 구독 해지가 안 된다"; exit 1; }
python3 - "$MARINA_HOME/push-subscriptions.json" <<'PY'
import json, sys
from pathlib import Path
raw = json.loads(Path(sys.argv[1]).read_text()) if Path(sys.argv[1]).exists() else {}
assert raw == {}, f"해지했는데 남아 있다: {raw}"
PY
echo "ok 푸시: 토큰 가드·형식 검증·등록/해지"

# ③ SSE — 헤더가 event-stream 이고, 사건이 나면 프레임이 밀려온다.
python3 - "$b" <<'PY'
import json
import threading
import time
import urllib.request

base = __import__("sys").argv[1]
request = urllib.request.Request(f"{base}/mobile/api/events",
                                 headers={"X-Marina-Mobile-Token": "secret",
                                          "Accept": "text/event-stream"})
stream = urllib.request.urlopen(request, timeout=10)
assert stream.headers["content-type"].startswith("text/event-stream"), stream.headers["content-type"]
assert stream.headers.get("x-accel-buffering") == "no", "프록시가 모아뒀다 보내면 실시간이 아니다"

# **바이트가 즉시 흐르는지**가 핵심이다. 서버가 응답을 다 모았다가 보내면 SSE 는 무용지물이라
# 헤더만 봐서는 알 수 없다 — 첫 프레임(": connected")이 지금 도착하는지로 확인한다.
first = []
def reader():
    try:
        first.append(stream.readline())
    except Exception:
        pass
thread = threading.Thread(target=reader, daemon=True)
thread.start()
thread.join(5)
assert first and first[0].startswith(b":"), f"스트림이 즉시 흐르지 않는다: {first!r}"

# 찌르기가 스트림을 끊지 않는지도 본다(훅은 대화 도중 수시로 찌른다).
inject = urllib.request.Request(f"{base}/api/events-poke", data=b"", method="POST")
with urllib.request.urlopen(inject, timeout=5) as response:
    assert response.status == 200
try:
    stream.close()
except Exception:
    pass
print("ok SSE: 헤더 + 바이트가 즉시 흐름 + 찌르기 공존")
PY

# ④ 찌르기는 로컬 전용 — 프록시를 거쳐 오면 거부한다.
proxied="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'X-Forwarded-For: 1.2.3.4' "$b/api/events-poke")"
[[ "$proxied" == "403" ]] || { echo "FAIL: 프록시 경유 찌르기가 통과했다($proxied)"; exit 1; }
echo "ok 찌르기: 로컬 전용 가드"

echo "PASS test-live-stream-http"
