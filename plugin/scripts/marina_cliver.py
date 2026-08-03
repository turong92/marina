"""marina_cliver.py — claude/codex **CLI 자체** 버전 감지·업데이트.

marina_update.py 와 다르다: 저쪽은 marina 플러그인의 SHA 를, 여기는 하네스 CLI 의 버전을 본다.
CLI 새 버전은 터미널에서 CLI 를 띄울 때만 보였다 — 대시보드·모바일에서는 알 길이 없었고,
native 설치 + autoUpdates=false 면 자동으로 올라가지도 않는다.

설계 원칙 하나: **모르면 배너를 안 띄운다.** 설치본을 못 읽거나 네트워크가 죽으면 behind=False 다.
없는 업데이트를 있다고 하는 오탐이, 있는 업데이트를 놓치는 미탐보다 나쁘다.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
import urllib.request
from pathlib import Path
from typing import Any

CLAUDE_JSON = Path(os.environ.get("CLAUDE_JSON", str(Path.home() / ".claude.json")))
PACKAGES = {"claude": "@anthropic-ai/claude-code", "codex": "@openai/codex"}

# TTL 30분 — 버전은 하루 단위로 바뀌고 네트워크 조회라 짧을 이유가 없다.
_TTL_S = float(os.environ.get("MARINA_CLI_VERSION_TTL", "1800"))
_LATEST_CACHE: dict[str, Any] = {}
_STATUS_CACHE: dict[str, Any] = {}

# 2.1.220 / 0.146.0 / 2.2.0-beta.1 — 앞의 숫자.숫자.숫자 를 잡고 프리릴리스 꼬리를 허용한다.
_VERSION_RE = re.compile(r"(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)")

# 업데이트가 실행 파일을 갈아치우면 돌고 있는 세션이 깨진다 — 이 상태면 막는다.
#
# 어휘는 resolve_session_liveness 가 캐논화한 것을 그대로 쓴다:
#   working(작업 중) · blocked(권한 승인 대기) · waiting(응답 마치고 입력 대기) ·
#   completed · failed · idle
# working 은 당연히 막고, blocked 도 막는다 — 권한 프롬프트를 띄운 채 바이너리가 갈리면
# 그 프롬프트가 죽는다. waiting/idle/completed/failed 는 막지 않는다(바쁘지 않다).
# ('running' 은 에이전트 상태가 아니라 **서비스**의 상태다 — 여기 쓰면 영영 안 걸린다.)
_BUSY_STATUSES = ("working", "blocked")


class BusyError(Exception):
    """작업 중인 세션이 있어 업데이트를 거부했다."""

    def __init__(self, busy: list[dict[str, str]]):
        super().__init__("작업 중인 세션이 있어요")
        self.busy = busy


def _parse_version(text: str) -> str:
    m = _VERSION_RE.search(text or "")
    return m.group(1) if m else ""


def _version_key(v: str) -> list[int]:
    # 숫자 세그먼트로 비교한다 — 문자열 비교면 2.1.9 > 2.1.10 으로 오판한다.
    # 프리릴리스 꼬리(-beta.1)의 숫자도 뒤에 붙지만, 같은 릴리스끼리만 갈리므로 판정에 해가 없다.
    return [int(x) for x in re.findall(r"\d+", v or "")]


def _version_behind(installed: str, latest: str) -> bool:
    if not installed or not latest:
        return False
    return _version_key(installed) < _version_key(latest)


def _installed_version(harness: str) -> str:
    exe = shutil.which(harness)
    if not exe:
        return ""
    try:
        out = subprocess.check_output([exe, "--version"], text=True, timeout=10,
                                      stderr=subprocess.STDOUT)
    except Exception:
        return ""
    return _parse_version(out)


def _fetch_latest(pkg: str) -> str | None:
    # native·brew 설치본도 버전 번호가 npm 과 일치한다(실측: claude 2.1.220 / codex 0.146.0 양쪽 동일).
    # 그래서 설치 방식과 무관하게 registry 하나로 '최신'을 안다.
    try:
        req = urllib.request.Request(f"https://registry.npmjs.org/{pkg}/latest",
                                     headers={"accept": "application/json"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            version = str(json.loads(resp.read().decode("utf-8")).get("version") or "")
        return version or None
    except Exception:
        return None   # 네트워크 실패는 조용히 — 배너를 안 띄우면 된다


def _latest_version(pkg: str) -> str | None:
    now = time.time()
    hit = _LATEST_CACHE.get(pkg)
    if hit and now - hit["ts"] < _TTL_S:
        return hit["version"]
    version = _fetch_latest(pkg)
    if version is not None:
        _LATEST_CACHE[pkg] = {"ts": now, "version": version}
        return version
    return hit["version"] if hit else None   # 실패하면 마지막 성공값을 유지한다


def _claude_config() -> dict[str, Any]:
    try:
        return json.loads(CLAUDE_JSON.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _codex_method(path: str) -> str:
    # codex 는 설치 기록 파일이 없다 — 실행 파일 경로로 가른다.
    if not path:
        return ""
    return "brew" if path.startswith(("/opt/homebrew/", "/usr/local/")) else "npm"


def _update_cmd(harness: str, method: str) -> list[str] | None:
    if harness not in PACKAGES:
        return None
    if harness == "claude" and method == "native":
        return ["claude", "update"]          # native 설치는 자체 업데이터가 있다
    if method == "brew":
        return ["brew", "upgrade", harness]
    if method in ("npm", "global"):
        return ["npm", "i", "-g", PACKAGES[harness]]
    return None


def cli_status(refresh: bool = False) -> dict[str, Any]:
    """{"claude": {installed, latest, behind, method, cmd[, autoUpdates]}, "codex": {...}}.
    설치되지 않은 하네스는 **항목 자체가 없다** — 배너를 띄울 근거가 없기 때문."""
    now = time.time()
    if not refresh and _STATUS_CACHE and now - _STATUS_CACHE.get("ts", 0) < _TTL_S:
        return _STATUS_CACHE["payload"]
    cfg = _claude_config()
    out: dict[str, Any] = {}
    for harness, pkg in PACKAGES.items():
        installed = _installed_version(harness)
        if not installed:
            continue
        latest = _latest_version(pkg)
        method = (str(cfg.get("installMethod") or "") if harness == "claude"
                  else _codex_method(shutil.which("codex") or ""))
        cmd = _update_cmd(harness, method)
        item: dict[str, Any] = {
            "installed": installed,
            "latest": latest,
            "behind": _version_behind(installed, latest or ""),
            "method": method,
            "cmd": " ".join(cmd) if cmd else "",
        }
        if harness == "claude":
            # 자동 업데이트가 꺼져 있으면 배너가 유일한 통로다 — UI 가 문구를 달리 쓸 수 있게 실어 준다.
            item["autoUpdates"] = bool(cfg.get("autoUpdates"))
        out[harness] = item
    _STATUS_CACHE.update({"ts": now, "payload": out})
    return out


def busy_agents(source: str) -> list[dict[str, str]]:
    """그 하네스의 '작업 중' 세션. 업데이트가 실행 파일을 갈아치우면 돌고 있는 세션이 깨진다.
    상태는 agents_payload 가 resolve_session_liveness 로 캐논화한 값을 그대로 쓴다."""
    from marina_registry import discover_all_roots
    from marina_sessions import agents_payload

    busy: list[dict[str, str]] = []
    for root in discover_all_roots():
        try:
            agents = agents_payload(root)
        except Exception:
            continue   # 워크트리 하나가 깨졌다고 업데이트 판정을 막지는 않는다
        for a in agents:
            if a.get("source") == source and a.get("status") in _BUSY_STATUSES:
                busy.append({"title": str(a.get("title") or ""),
                             "status": str(a.get("status") or ""),
                             "root": str(root)})
    return busy


def _run_update(cmd: list[str]) -> str:
    try:
        return subprocess.check_output(cmd, text=True, timeout=300, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as exc:
        raise ValueError(f"{' '.join(cmd)} 실패: {(exc.output or '').strip()[-200:]}")
    except Exception as exc:
        raise ValueError(f"{' '.join(cmd)} 실패: {exc}")


def cli_update(harness: str) -> dict[str, Any]:
    if harness not in PACKAGES:
        raise ValueError(f"알 수 없는 하네스: {harness}")
    busy = busy_agents(harness)
    if busy:
        raise BusyError(busy)
    status = cli_status(refresh=True).get(harness) or {}
    cmd = _update_cmd(harness, str(status.get("method") or ""))
    if not cmd:
        raise ValueError(f"{harness} 설치 방식을 알 수 없어 자동 업데이트를 못 해요")
    out = _run_update(cmd)
    # 무효화는 완료 "후" — 진행 중(수십 초) 폴링이 옛 버전으로 캐시를 재충전하는 레이스 차단.
    # **두 계층 다** 지운다: update_status 가 이 페이로드를 통째로 감싸 60초 캐시하므로, 여기만
    # 지우면 받은 직후에도 배너가 옛 behind=true 로 다시 뜬다.
    _STATUS_CACHE.clear()
    try:
        from marina_update import _status_cache
        _status_cache.clear()
    except Exception:
        pass
    return {"ok": True, "harness": harness,
            "installed": _installed_version(harness), "output": (out or "").strip()[-200:]}
