#!/usr/bin/env bash
# 웹 푸시 — 폰이 잠겨 있어도 오는 알림. **의존성 0**으로 만든다.
#
# 내용까지 보내려면 RFC 8291 암호화(ECDH+HKDF+AES-GCM)가 필요한데 이 환경엔 암호 라이브러리가
# 없다(마리나는 표준 라이브러리 전용). 그래서 **내용 없는 푸시**만 보내고, 폰이 깨면 서비스워커가
# 마리나에 내용을 물으러 온다. 그러면 필요한 암호는 VAPID 서명(ES256) 하나뿐 — openssl 로 된다.
# 덤: 알림 내용이 애플·구글 서버를 지나지 않는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import base64
import json
import subprocess
import sys
import time
from pathlib import Path

import marina_push as push

tmp = Path(sys.argv[1])
push.VAPID_KEY_FILE = tmp / "vapid.pem"
push.SUBSCRIPTIONS_FILE = tmp / "subs.json"

# ① 키는 한 번만 만든다 — 바뀌는 순간 등록된 폰의 구독이 전부 죽는다.
first = push.ensure_vapid_key().read_bytes()
again = push.ensure_vapid_key().read_bytes()
assert first == again, "키를 다시 만들었다 — 기존 구독이 전부 무효가 된다"
assert oct(push.VAPID_KEY_FILE.stat().st_mode)[-3:] == "600", "개인키 권한이 열려 있다"

# ② 공개키는 비압축 65바이트(0x04 로 시작)여야 브라우저가 받아준다.
raw = base64.urlsafe_b64decode(push.public_key() + "==")
assert len(raw) == 65 and raw[0] == 0x04, (len(raw), raw[:1])

# ③ VAPID 헤더: JWT 3조각 + 대상(aud)은 엔드포인트의 출처. 서명은 r||s 64바이트여야 한다.
endpoint = "https://web.push.apple.com/abcdef123"
headers = push.vapid_headers(endpoint, now=1000)
assert headers["authorization"].startswith("vapid t="), headers
token = headers["authorization"].split("t=")[1].split(",")[0]
head, claims, signature = token.split(".")
unb64 = lambda v: base64.urlsafe_b64decode(v + "=" * (-len(v) % 4))
assert json.loads(unb64(head))["alg"] == "ES256"
body = json.loads(unb64(claims))
assert body["aud"] == "https://web.push.apple.com", body
assert body["exp"] == int(1000 + push.VAPID_TTL_S), body
assert len(unb64(signature)) == 64, "JWS 는 r||s 고정 64바이트를 요구한다(DER 그대로면 거부된다)"

# ④ 서명이 **진짜 검증되는지** 확인한다 — 형식만 맞고 검증에 실패하면 푸시가 통째로 안 간다.
signing_input = f"{head}.{claims}".encode()
r, s = unb64(signature)[:32], unb64(signature)[32:]
def der_int(value):
    trimmed = value.lstrip(b"\x00") or b"\x00"
    if trimmed[0] & 0x80:
        trimmed = b"\x00" + trimmed
    return b"\x02" + bytes([len(trimmed)]) + trimmed
der_body = der_int(r) + der_int(s)
der = b"\x30" + bytes([len(der_body)]) + der_body
(tmp / "sig.der").write_bytes(der)
(tmp / "input.bin").write_bytes(signing_input)
subprocess.run(["openssl", "ec", "-in", str(push.VAPID_KEY_FILE), "-pubout",
                "-out", str(tmp / "pub.pem")], check=True, capture_output=True)
verify = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(tmp / "pub.pem"),
                         "-signature", str(tmp / "sig.der"), str(tmp / "input.bin")],
                        capture_output=True)
assert verify.returncode == 0, f"서명 검증 실패: {verify.stderr.decode()[:200]}"

# ⑤ https 가 아니면 거부 — 푸시 서비스는 https 뿐이고, 오타를 조용히 삼키면 원인 찾기가 지옥이다.
for bad in ("http://web.push.apple.com/x", "", "not-a-url"):
    try:
        push.vapid_headers(bad)
    except ValueError:
        continue
    raise AssertionError(f"거부해야 하는 엔드포인트: {bad!r}")

print("ok VAPID: 키 보존·공개키 형식·서명 검증 통과")

# ⑥ 구독 보관: 같은 폰이 다시 구독하면 늘지 않는다(endpoint 가 신원).
push.add_subscription(endpoint, "형 아이폰")
push.add_subscription(endpoint, "형 아이폰")
assert push.subscriptions() == [endpoint], push.subscriptions()
assert oct(push.SUBSCRIPTIONS_FILE.stat().st_mode)[-3:] == "600"
# 브라우저 키(p256dh/auth)는 받지도 저장하지도 않는다 — 내용 없는 푸시엔 필요가 없다.
saved = json.loads(push.SUBSCRIPTIONS_FILE.read_text())
assert "p256dh" not in json.dumps(saved) and "auth" not in saved[endpoint], saved

# ⑦ 형식이 이상한 엔드포인트는 저장하지 않는다.
for bad in ("http://x/y", "https://" + "a" * 3000, "javascript:alert(1)"):
    try:
        push.add_subscription(bad)
    except ValueError:
        continue
    raise AssertionError(f"저장하면 안 되는 값: {bad[:40]!r}")

# ⑧ 죽은 구독(404/410)은 즉시 지운다 — 안 그러면 영원히 실패하는 폰에 계속 쏜다.
import urllib.error
def gone(*a, **k):
    raise urllib.error.HTTPError(endpoint, 410, "Gone", {}, None)
push.urllib.request.urlopen = gone
assert push.send_push(endpoint) is False
assert push.subscriptions() == [], "410 인데 구독이 남았다"

# ⑨ 일시적 실패는 세다가 지운다(네트워크가 잠깐 나간 것까지 구독 해지로 보면 안 된다).
push.add_subscription(endpoint)
def flaky(*a, **k):
    raise OSError("network down")
push.urllib.request.urlopen = flaky
for expected in range(1, 5):
    assert push.send_push(endpoint) is False
    raw_subs = json.loads(push.SUBSCRIPTIONS_FILE.read_text())
    assert raw_subs[endpoint]["failures"] == expected, raw_subs
assert push.send_push(endpoint) is False
assert push.subscriptions() == [], "계속 실패하는데 영원히 남는다"

# ⑩ 성공하면 실패 카운트가 풀린다.
class OK:
    status = 201
    def __enter__(self): return self
    def __exit__(self, *a): return False
push.add_subscription(endpoint)
push.urllib.request.urlopen = flaky
push.send_push(endpoint)
push.urllib.request.urlopen = lambda *a, **k: OK()
assert push.send_push(endpoint) is True
assert json.loads(push.SUBSCRIPTIONS_FILE.read_text())[endpoint]["failures"] == 0

# ⑪ 한 대가 실패해도 나머지는 계속 간다.
second = "https://fcm.googleapis.com/fcm/send/xyz"
push.add_subscription(second)
def half(request, *a, **k):
    if request.full_url == second:
        raise OSError("boom")
    return OK()
push.urllib.request.urlopen = half
assert push.broadcast() == 1

print("ok 구독: 중복 없음·형식 검증·죽은 구독 정리·부분 실패 내성")
PY

echo "PASS test-push-vapid"
