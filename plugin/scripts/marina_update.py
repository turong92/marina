"""marina_update.py — marina-control.py 에서 분리(레이어드). 동작 변경 0."""
from __future__ import annotations
import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
import importlib.util as _ilu

from marina_state import CLAUDE_CONFIG_DIR, CODEX_HOME, CONTROL_SCRIPT, MARINA_HOME, MARKETPLACE, PLUGIN_ID, _bin, _env, _origin_cache

def update_state(serving: str | None, installed: str | None, origin: str | None) -> str:
    # serving=실행 중 SHA, installed=받아진 SHA, origin=배포된 최신 SHA. 모두 short SHA.
    # serving/installed 모르면 판정 불가(dev/repo 실행) → unknown(배너 없음).
    if not serving or not installed:
        return "unknown"
    # origin 모르면(네트워크 실패) 무네트워크 판정: serving==installed 면 current, 아니면 stale.
    if origin is None:
        return "current" if serving == installed else "stale"
    if serving == origin:
        return "current"
    if installed == origin:
        return "stale"   # 파일은 최신, 데몬만 옛 코드 → 재시작
    return "new"         # 배포된 게 받아진 것보다 최신 → 업데이트(다음 세션/수동) 필요

_SHA_RE = re.compile(r"^([0-9a-f]{7,40}|\d+\.\d+)")

def _serving_sha() -> str | None:
    env = os.environ.get("MARINA_SERVING_SHA")
    if env:
        return env[:12]
    # 설치 레이아웃: .../<marketplace>/marina/<SHA>/scripts/marina-control.py → <SHA> = parent.parent.name
    name = CONTROL_SCRIPT.parent.parent.name
    return name[:12] if _SHA_RE.match(name) else None   # 레포/dev 실행(name='plugin')은 None

def _installed_sha() -> str | None:
    env = os.environ.get("MARINA_INSTALLED_SHA")
    if env:
        return env[:12]
    for mf in (CLAUDE_CONFIG_DIR / "plugins" / "installed_plugins.json",
               CODEX_HOME / "plugins" / "installed_plugins.json"):
        try:
            data = json.loads(mf.read_text(encoding="utf-8"))
            raw = Path(str(data["plugins"][PLUGIN_ID][0]["installPath"])).name[:12]
            if _SHA_RE.match(raw):   # _serving_sha 와 대칭 — 비-SHA installPath 는 무시(오탐 방지)
                return raw
        except Exception:
            continue
    return None

def _marketplace_repo() -> str:
    # settings.json 의 marina-dev source.repo (fork 대응), 없으면 기본.
    try:
        s = json.loads((CLAUDE_CONFIG_DIR / "settings.json").read_text(encoding="utf-8"))
        repo = s["extraKnownMarketplaces"][MARKETPLACE]["source"]["repo"]
        if isinstance(repo, str) and repo:
            return repo
    except Exception:
        pass
    return "turong92/marina"

def _origin_sha() -> str | None:
    env = os.environ.get("MARINA_ORIGIN_SHA")
    if env:
        return env[:12]
    ttl = float(_env("UPDATE_TTL", "60"))
    now = time.time()
    if _origin_cache and now - _origin_cache.get("ts", 0) < ttl:
        return _origin_cache.get("sha")
    sha = _origin_cache.get("sha")  # 실패 시 마지막 값 유지
    try:
        out = subprocess.check_output(
            ["git", "ls-remote", f"https://github.com/{_marketplace_repo()}.git", "main"],
            text=True, timeout=5, stderr=subprocess.DEVNULL,
        )
        if out.strip():
            sha = out.split()[0][:12]
    except Exception:
        pass
    _origin_cache.update({"sha": sha, "ts": now})
    return sha

def _harnesses() -> list[str]:
    # 설치된 하네스 감지. Claude=installed_plugins.json, Codex=config.toml 에 설치 기록(installed_plugins.json 없음).
    out: list[str] = []
    if (CLAUDE_CONFIG_DIR / "plugins" / "installed_plugins.json").exists():
        out.append("claude")
    try:
        if f'[plugins."{PLUGIN_ID}"]' in (CODEX_HOME / "config.toml").read_text(encoding="utf-8"):
            out.append("codex")
    except Exception:
        pass
    return out

def _git_head(d: Path) -> str | None:
    try:
        out = subprocess.check_output(["git", "-C", str(d), "rev-parse", "HEAD"],
                                      text=True, timeout=5, stderr=subprocess.DEVNULL)
        sha = out.strip()[:12]
        return sha if _SHA_RE.match(sha) else None
    except Exception:
        return None

def _codex_marketplace() -> dict[str, str] | None:
    # ~/.codex/config.toml 의 [marketplaces.marina-dev] 블록 (text-parse; py3.9 라 tomllib 없음)
    try:
        t = (CODEX_HOME / "config.toml").read_text(encoding="utf-8")
    except Exception:
        return None
    m = re.search(r"\[marketplaces\.marina-dev\](.*?)(?=\n\[|\Z)", t, re.S)
    if not m:
        return None
    src = re.search(r'source\s*=\s*"([^"]+)"', m.group(1))
    typ = re.search(r'source_type\s*=\s*"([^"]+)"', m.group(1))
    return {"source": src.group(1), "sourceType": typ.group(1) if typ else ""} if src else None

def _harness_status() -> dict[str, Any]:
    # 하네스별 설치 버전 + origin 대비 뒤처짐 (배너 칩용). claude=설치 복사본 SHA, codex=마켓 스냅샷 git HEAD(라이브 참조)
    origin = _origin_sha()
    out: dict[str, Any] = {}
    try:
        data = json.loads((CLAUDE_CONFIG_DIR / "plugins" / "installed_plugins.json").read_text(encoding="utf-8"))
        ent = data["plugins"][PLUGIN_ID][0]
        sha = str(ent.get("gitCommitSha") or Path(str(ent["installPath"])).name)[:12]
        if _SHA_RE.match(sha):
            out["claude"] = {"installed": sha, "behind": bool(origin and sha != origin)}
    except Exception:
        pass
    mk = _codex_marketplace()
    if mk:
        sha = _git_head(Path(mk["source"]))
        if sha:
            out["codex"] = {"installed": sha, "behind": bool(origin and sha != origin), "sourceType": mk.get("sourceType", "")}
    return out

def update_codex() -> dict[str, Any]:
    # codex 는 마켓 스냅샷 디렉토리를 라이브로 읽으므로, 그 git repo 를 origin/main 으로 ff-pull = codex 갱신
    mk = _codex_marketplace()
    if not mk:
        raise ValueError("codex marina-dev 마켓플레이스를 찾을 수 없음 (codex 미설치?)")
    src = Path(mk["source"])
    try:
        out = subprocess.check_output(["git", "-C", str(src), "pull", "--ff-only", "origin", "main"],
                                      text=True, timeout=30, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as exc:
        raise ValueError(f"codex 스냅샷 git pull 실패: {(exc.output or '').strip()[-200:]}")
    except Exception as exc:
        raise ValueError(f"codex 갱신 실패: {exc}")
    # 무효화는 완료 "후" — 진행 중(수십 초) 폴링이 옛 SHA 로 캐시를 재충전하는 레이스 차단(코덱스 P3)
    _status_cache.clear()
    return {"ok": True, "harness": "codex", "installed": _git_head(src), "output": out.strip()[-160:]}

def update_claude() -> dict[str, Any]:
    # claude 는 plugin marketplace update → plugin update 두 단계로 설치 복사본을 교체
    if os.environ.get("MARINA_UPDATE_CLAUDE_DRY_RUN") == "1":
        MARINA_HOME.mkdir(parents=True, exist_ok=True)
        with (MARINA_HOME / "update-claude-dry-run.log").open("a", encoding="utf-8") as fh:
            fh.write("would run: claude plugin marketplace update marina-dev && claude plugin update marina@marina-dev\n")
        return {"ok": True, "harness": "claude", "output": "(dry-run)", "installed": _installed_sha()}
    try:
        out1 = subprocess.check_output(
            [_bin("claude"), "plugin", "marketplace", "update", "marina-dev"],
            text=True, timeout=60, stderr=subprocess.STDOUT,
        )
    except subprocess.CalledProcessError as exc:
        raise ValueError(f"claude marketplace update 실패: {(exc.output or '').strip()[-200:]}")
    except Exception as exc:
        raise ValueError(f"claude 마켓플레이스 갱신 실패: {exc}")
    try:
        out2 = subprocess.check_output(
            [_bin("claude"), "plugin", "update", "marina@marina-dev"],
            text=True, timeout=60, stderr=subprocess.STDOUT,
        )
    except subprocess.CalledProcessError as exc:
        raise ValueError(f"claude plugin update 실패: {(exc.output or '').strip()[-200:]}")
    except Exception as exc:
        raise ValueError(f"claude 플러그인 업데이트 실패: {exc}")
    combined = (out1.strip() + "\n" + out2.strip()).strip()[-160:]
    # 무효화는 완료 "후" — 진행 중(최대 2분) 폴링이 옛 SHA 로 캐시를 재충전하는 레이스 차단(코덱스 P3)
    _status_cache.clear()
    return {"ok": True, "harness": "claude", "installed": _installed_sha(), "output": combined}

_status_cache: dict[str, Any] = {}   # 전체 payload 캐시 — 파일 읽기·git rev-parse 를 폴링마다 반복하지 않게

def update_status() -> dict[str, Any]:
    # UPDATE_TTL(기본 60s) 캐시 — 상태는 분 단위로만 변하고, update_claude/codex 가 성공 경로에서 무효화.
    # 외부에서 직접 plugin update 를 돌린 경우도 최대 TTL 안에 반영.
    now = time.time()
    if _status_cache and now - _status_cache.get("ts", 0) < float(_env("UPDATE_TTL", "60")):
        return _status_cache["payload"]
    serving, installed, origin = _serving_sha(), _installed_sha(), _origin_sha()
    payload = {
        "serving": serving,
        "installed": installed,
        "origin": origin,
        "state": update_state(serving, installed, origin),
        "harnesses": _harnesses(),
        "harnessStatus": _harness_status(),
    }
    _status_cache.update({"ts": now, "payload": payload})
    return payload
