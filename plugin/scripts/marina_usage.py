"""marina_usage.py — Claude 계정 사용량(5시간/7일 한도)을 **직접** 가져온다.

왜 새로 만들었나. 예전엔 써드파티 플러그인(claude-hud)이 써 둔 캐시 파일을 읽었다. 그 캐시가
47일째 갱신되지 않아 사용량이 늘 빈칸이었다. 원인을 끝까지 따라가면 이렇다:

  · 키체인에 서비스명이 같은 항목이 **두 개** 있다(acct=unknown, acct=<사용자>).
  · `security find-generic-password -s <svc>` 는 계정을 안 주면 **첫 항목만** 준다.
  · 첫 항목의 토큰은 만료돼 있었고(1129시간 전), hud 는 만료면 **갱신 없이 포기**한다.
  · 그래서 캐시가 그 시점에 얼어붙었다 — 캐시 마지막 기록 시각과 토큰 만료 시각이 일치한다.

즉 marina 가 남의 캐시를 기다린 게 잘못이었다. 공식 claude CLI 자신이 쓰는 경로가 있다
(바이너리에 `/api/oauth/usage` 문자열이 박혀 있다). 여기서는 그 경로를 그대로 쓰되,
hud 가 틀린 지점 하나를 고친다: **매칭되는 키체인 항목을 전부 열거해 살아있는 토큰을 고른다.**

토큰 갱신은 **하지 않는다.** refresh_token 회전은 CLI 의 인증을 깨뜨릴 수 있다. CLI 가 알아서
갱신하므로(형은 하루 종일 claude 를 쓴다) 살아있는 토큰은 사실상 항상 있다. 읽기만 한다.

토큰은 요청 헤더로만 쓰고 로그·응답·예외 메시지 어디에도 싣지 않는다.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
import urllib.request
from pathlib import Path
from typing import Any

CLAUDE_CONFIG_DIR = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude")))
KEYCHAIN_SERVICE = "Claude Code-credentials"
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
USAGE_UA = "claude-code/2.1"

# 사용량은 분 단위로만 의미가 바뀐다. hud 와 같은 60초.
_TTL_S = float(os.environ.get("MARINA_CLAUDE_USAGE_TTL", "60"))
_FAIL_TTL_S = float(os.environ.get("MARINA_CLAUDE_USAGE_FAIL_TTL", "15"))
_CACHE: dict[str, Any] = {}


def _run(cmd: list[str], timeout: float = 5.0) -> str:
    try:
        return subprocess.check_output(cmd, text=True, timeout=timeout, stderr=subprocess.DEVNULL)
    except Exception:
        return ""


def keychain_service_name(config_dir: Path | None = None) -> str:
    """기본 설정 디렉터리면 서비스명 그대로, 커스텀이면 sha256 앞 8자를 붙인다(CLI 규칙)."""
    import hashlib

    target = (config_dir or CLAUDE_CONFIG_DIR).expanduser().resolve()
    default = (Path.home() / ".claude").resolve()
    if target == default:
        return KEYCHAIN_SERVICE
    digest = hashlib.sha256(str(target).encode("utf-8")).hexdigest()[:8]
    return f"{KEYCHAIN_SERVICE}-{digest}"


def _keychain_accounts(service: str) -> list[str]:
    """그 서비스명을 쓰는 계정을 전부 찾는다. **여기가 hud 와 갈리는 지점** — 계정을 안 주면
    첫 항목만 잡히고, 그게 만료본이면 영영 빈 값이 된다."""
    dump = _run(["security", "dump-keychain"], timeout=15.0)
    if not dump:
        return []
    accounts: list[str] = []
    for block in dump.split("keychain: "):
        if f'"svce"<blob>="{service}"' not in block:
            continue
        for line in block.splitlines():
            token = line.strip()
            if token.startswith('"acct"<blob>="'):
                name = token[len('"acct"<blob>="'):].rstrip('"')
                if name and name not in accounts:
                    accounts.append(name)
                break
    return accounts


def _oauth_from_blob(raw: str) -> dict[str, Any] | None:
    try:
        value = json.loads(raw).get("claudeAiOauth")
    except Exception:
        return None
    return value if isinstance(value, dict) else None


def _alive(oauth: dict[str, Any]) -> bool:
    expires = oauth.get("expiresAt")
    # expiresAt 없음 = 만료 정보 없음. 만료로 치지 않는다(있는 토큰은 일단 써 본다).
    return not isinstance(expires, (int, float)) or expires / 1000.0 > time.time()


def _access_token() -> str:
    """살아있는 액세스 토큰. 없으면 빈 문자열. **절대 로그로 새지 않게** 호출부에서도 담아두지 말 것."""
    service = keychain_service_name()
    candidates: list[dict[str, Any]] = []
    for account in _keychain_accounts(service):
        blob = _run(["security", "find-generic-password", "-w", "-s", service, "-a", account])
        oauth = _oauth_from_blob(blob.strip()) if blob else None
        if oauth and oauth.get("accessToken"):
            candidates.append(oauth)
    if not candidates:   # 계정 열거 실패(권한 등) — 계정 없이 한 번 더
        blob = _run(["security", "find-generic-password", "-w", "-s", service])
        oauth = _oauth_from_blob(blob.strip()) if blob else None
        if oauth and oauth.get("accessToken"):
            candidates.append(oauth)
    if not candidates:   # 옛 배포는 파일에 넣었다
        try:
            oauth = _oauth_from_blob((CLAUDE_CONFIG_DIR / ".credentials.json").read_text(encoding="utf-8"))
            if oauth and oauth.get("accessToken"):
                candidates.append(oauth)
        except OSError:
            pass
    # 살아있는 것 중 가장 늦게 만료되는 것 — 여러 계정이 살아있으면 가장 여유 있는 쪽
    alive = [c for c in candidates if _alive(c)]
    if not alive:
        return ""
    alive.sort(key=lambda c: c.get("expiresAt") or 0, reverse=True)
    return str(alive[0].get("accessToken") or "")


def _fetch(token: str) -> dict[str, Any] | None:
    req = urllib.request.Request(USAGE_URL, headers={
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": USAGE_UA,
        "accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception:
        # 토큰이 실려 있을 수 있는 예외는 통째로 삼킨다 — 메시지에 헤더가 섞여 로그로 새지 않게.
        return None


def claude_usage_payload(refresh: bool = False) -> dict[str, Any] | None:
    """`/api/oauth/usage` 원본 페이로드. 실패하면 None(호출부가 조용히 폴백)."""
    now = time.time()
    hit = _CACHE.get("payload")
    if not refresh and hit and now - hit["ts"] < (_TTL_S if hit["value"] else _FAIL_TTL_S):
        return hit["value"]
    token = _access_token()
    value = _fetch(token) if token else None
    _CACHE["payload"] = {"ts": now, "value": value}
    return value
