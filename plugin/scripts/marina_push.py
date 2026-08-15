"""웹 푸시 — 폰이 잠겨 있어도 도착하는 알림.

**의존성 0으로 어떻게 하나.** 웹 푸시로 *내용*을 보내려면 RFC 8291 암호화(ECDH + HKDF +
AES-128-GCM)가 필요한데, 이 환경엔 암호 라이브러리가 하나도 없다(마리나는 표준 라이브러리
전용). AES-GCM 을 손으로 구현하는 건 위험하고, 의존성을 들이는 건 배포 방식을 바꾼다.

그래서 **내용 없는 푸시**를 보낸다(RFC 8030 이 허용한다). 폰이 깨면 서비스워커가 마리나에
직접 물어서 무엇을 보여줄지 정한다. 필요한 암호는 VAPID 서명(ES256) 하나뿐이고 그건 이미
깔려 있는 openssl 로 한다. 덤으로 **알림 내용이 애플·구글 서버를 지나가지 않는다**.

**키.** VAPID 키쌍은 처음 한 번 만들어 MARINA_HOME 에 둔다(0600). 키가 바뀌면 기존 구독이
전부 무효가 되므로 절대 재생성하지 않는다 — 있으면 그대로 쓴다.
"""
from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from marina_state import MARINA_HOME

VAPID_KEY_FILE = MARINA_HOME / "push-vapid.pem"
SUBSCRIPTIONS_FILE = MARINA_HOME / "push-subscriptions.json"
VAPID_TTL_S = 12 * 3600          # JWT 유효기간(푸시 서비스 상한은 24시간)
PUSH_TTL_S = 3600                # 폰이 꺼져 있으면 이만큼만 붙들어 달라고 요청
_LOCK = threading.Lock()
_OPENSSL_TIMEOUT_S = 5


def _b64(raw: bytes) -> str:
    """웹 푸시는 패딩 없는 base64url 만 쓴다."""
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _unb64(value: str) -> bytes:
    padded = value + "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(padded.encode("ascii"))


def _openssl(args: list[str], stdin: bytes | None = None) -> bytes:
    result = subprocess.run(["openssl", *args], input=stdin, capture_output=True,
                            timeout=_OPENSSL_TIMEOUT_S)
    if result.returncode != 0:
        raise RuntimeError(f"openssl {args[0]} 실패: {result.stderr.decode('utf-8', 'ignore')[:200]}")
    return result.stdout


def ensure_vapid_key() -> Path:
    """키쌍을 보장한다. **있으면 절대 새로 만들지 않는다** — 바뀌는 순간 모든 구독이 죽는다."""
    with _LOCK:
        if VAPID_KEY_FILE.is_file() and VAPID_KEY_FILE.stat().st_size:
            return VAPID_KEY_FILE
        VAPID_KEY_FILE.parent.mkdir(parents=True, exist_ok=True)
        pem = _openssl(["ecparam", "-genkey", "-name", "prime256v1", "-noout"])
        temporary = VAPID_KEY_FILE.with_suffix(".tmp")
        temporary.write_bytes(pem)
        os.chmod(temporary, 0o600)
        os.replace(temporary, VAPID_KEY_FILE)
        return VAPID_KEY_FILE


def public_key() -> str:
    """브라우저가 구독할 때 쓰는 공개키(base64url, 비압축 65바이트)."""
    der = _openssl(["ec", "-in", str(ensure_vapid_key()), "-pubout", "-outform", "DER"])
    point = der[-65:]
    if len(point) != 65 or point[0] != 0x04:
        raise RuntimeError("VAPID 공개키를 뽑지 못했다")
    return _b64(point)


def _der_signature_to_raw(der: bytes) -> bytes:
    """openssl 은 DER(SEQUENCE{r,s})로 서명하는데 JWS 는 r||s 고정 64바이트를 요구한다."""
    if len(der) < 8 or der[0] != 0x30:
        raise RuntimeError("서명 형식이 DER 이 아니다")
    index = 2 if der[1] < 0x80 else 3
    numbers = []
    for _ in range(2):
        if der[index] != 0x02:
            raise RuntimeError("서명 안에 INTEGER 가 없다")
        length = der[index + 1]
        value = der[index + 2:index + 2 + length].lstrip(b"\x00")
        numbers.append(value.rjust(32, b"\x00"))
        index += 2 + length
    return b"".join(numbers)


def vapid_headers(endpoint: str, subject: str = "mailto:marina@localhost",
                  now: float | None = None) -> dict[str, str]:
    """푸시 서비스에 '이 발신자가 맞다'를 증명하는 헤더. 대상(aud)은 엔드포인트의 출처다."""
    parts = urllib.parse.urlsplit(endpoint)
    if parts.scheme != "https" or not parts.netloc:
        raise ValueError("푸시 엔드포인트는 https 여야 합니다")
    current = time.time() if now is None else now
    header = _b64(json.dumps({"typ": "JWT", "alg": "ES256"}, separators=(",", ":")).encode())
    claims = _b64(json.dumps({"aud": f"{parts.scheme}://{parts.netloc}",
                              "exp": int(current + VAPID_TTL_S),
                              "sub": subject}, separators=(",", ":")).encode())
    signing_input = f"{header}.{claims}".encode("ascii")
    der = _openssl(["dgst", "-sha256", "-sign", str(ensure_vapid_key())], stdin=signing_input)
    token = f"{header}.{claims}.{_b64(_der_signature_to_raw(der))}"
    return {"authorization": f"vapid t={token}, k={public_key()}",
            "ttl": str(PUSH_TTL_S), "content-length": "0"}


# ── 구독 보관 ────────────────────────────────────────────────────────────────
# 브라우저가 준 endpoint 가 곧 신원이다. 같은 폰이 다시 구독하면 endpoint 가 같으므로 덮어쓴다.

def _read_subscriptions() -> dict[str, Any]:
    try:
        value = json.loads(SUBSCRIPTIONS_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return value if isinstance(value, dict) else {}


def _write_subscriptions(payload: dict[str, Any]) -> None:
    SUBSCRIPTIONS_FILE.parent.mkdir(parents=True, exist_ok=True)
    temporary = SUBSCRIPTIONS_FILE.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, SUBSCRIPTIONS_FILE)


_ENDPOINT_RE = re.compile(r"^https://[A-Za-z0-9.-]+(?::\d+)?/[^\s]*$")


def add_subscription(endpoint: str, label: str = "") -> dict[str, Any]:
    """구독 등록. 내용 없는 푸시만 보내므로 브라우저 키(p256dh/auth)는 받지도 저장하지도 않는다."""
    endpoint = str(endpoint or "").strip()
    if not _ENDPOINT_RE.match(endpoint) or len(endpoint) > 2000:
        raise ValueError("푸시 엔드포인트 형식이 올바르지 않아요")
    with _LOCK:
        payload = _read_subscriptions()
        payload[endpoint] = {"label": str(label or "")[:60], "added": time.time(),
                             "failures": 0}
        _write_subscriptions(payload)
    return {"ok": True, "count": len(payload)}


def remove_subscription(endpoint: str) -> dict[str, Any]:
    with _LOCK:
        payload = _read_subscriptions()
        existed = payload.pop(str(endpoint or ""), None) is not None
        if existed:
            _write_subscriptions(payload)
    return {"ok": True, "removed": existed}


def subscriptions() -> list[str]:
    return list(_read_subscriptions().keys())


def _note_failure(endpoint: str, gone: bool) -> None:
    """404/410 은 '그 구독은 죽었다'는 확답 — 즉시 지운다. 그 외 실패는 세다가 지운다."""
    with _LOCK:
        payload = _read_subscriptions()
        record = payload.get(endpoint)
        if not isinstance(record, dict):
            return
        if gone or int(record.get("failures") or 0) + 1 >= 5:
            payload.pop(endpoint, None)
        else:
            record["failures"] = int(record.get("failures") or 0) + 1
        _write_subscriptions(payload)


def _note_success(endpoint: str) -> None:
    with _LOCK:
        payload = _read_subscriptions()
        record = payload.get(endpoint)
        if isinstance(record, dict) and record.get("failures"):
            record["failures"] = 0
            _write_subscriptions(payload)


def send_push(endpoint: str, timeout: float = 8.0) -> bool:
    """내용 없는 푸시 하나. 폰이 깨면 서비스워커가 마리나에 내용을 물으러 온다."""
    request = urllib.request.Request(endpoint, data=b"", method="POST")
    for name, value in vapid_headers(endpoint).items():
        request.add_header(name, value)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            _note_success(endpoint)
            return 200 <= response.status < 300
    except urllib.error.HTTPError as error:
        _note_failure(endpoint, gone=error.code in (404, 410))
        return False
    except Exception:
        _note_failure(endpoint, gone=False)
        return False


def broadcast() -> int:
    """등록된 모든 폰을 깨운다. 몇 대가 깼는지 돌려준다(한 대가 실패해도 나머지는 계속)."""
    sent = 0
    for endpoint in subscriptions():
        try:
            if send_push(endpoint):
                sent += 1
        except Exception:
            continue
    return sent
