"""marina_docker_gc.py — 워크트리에 묶이지 않는 도커 산출물의 주기 정리.

**왜 여기서.** 빌드캐시·dangling 이미지·익명 볼륨·e2e 잔재는 누가 만들었든 아무도 회수하지 않았다
(2026-09-14 실측: 7일 넘은 빌드캐시 21GB, e2e 이미지 383개, 익명 볼륨 319개). 형: "밖에서 cron 거는 건
의미 없다, marina 에서 컨트롤돼야 한다" — 정책도 실행도 marina 가 쥔다.

**범위 밖.** 워크트리 소유 이미지(remove_worktree → clear_worktree_images, marina_lifecycle) 는 여기서
다루지 않는다. 명명 볼륨(사용자 데이터일 수 있다)과 사용 중인 어떤 것도.

**구조.** 도커 호출은 전부 `run(args) -> str` 하나를 통해 나간다 — 테스트는 가짜 run 을 주입해 명령·순서·
판정을 검증하고, 실 도커를 만지는 테스트는 dry-run 경로만 탄다.
설계: docs/superpowers/specs/2026-09-14-docker-gc-policy-design.md
"""
from __future__ import annotations

import fnmatch
import json
import os
import re
import subprocess
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from marina_state import MARINA_HOME, _bin

POLICY_FILE = MARINA_HOME / "docker-gc.json"
STATE_FILE = MARINA_HOME / "docker-gc-state.json"
LOG_FILE = MARINA_HOME / "docker-gc.log"

E2E_LABEL = "marina.e2e"          # 테스트 하네스가 e2e 산출물에 붙이는 라벨(값 "1")

DEFAULT_POLICY: dict[str, Any] = {
    "enabled": True,
    "interval_hours": 24,
    "build_cache_keep_days": 7,
    "dangling_images": True,
    "anonymous_volumes": True,
    "stale_test_artifacts_days": 3,
    "stale_test_artifact_names": ["marina-*-e2e-*"],
}
_POLICY_TYPES: dict[str, str] = {
    "enabled": "bool",
    "interval_hours": "int",
    "build_cache_keep_days": "int",
    "dangling_images": "bool",
    "anonymous_volumes": "bool",
    "stale_test_artifacts_days": "int",
    "stale_test_artifact_names": "globs",
}

_TRUE = {"1", "true", "yes", "on", "y"}
_FALSE = {"0", "false", "no", "off", "n"}


# ─────────────────────────── 정책 ───────────────────────────

def _coerce(key: str, value: Any) -> Any:
    """CLI·API 가 주는 문자열도 받아 정책 타입으로. 틀리면 ValueError(메시지에 키)."""
    kind = _POLICY_TYPES.get(key)
    if kind is None:
        raise ValueError(f"모르는 정책 키: {key} (가능: {', '.join(_POLICY_TYPES)})")
    if kind == "bool":
        if isinstance(value, bool):
            return value
        s = str(value).strip().lower()
        if s in _TRUE:
            return True
        if s in _FALSE:
            return False
        raise ValueError(f"{key}: true/false 여야 합니다 (받은 값: {value!r})")
    if kind == "int":
        if isinstance(value, bool) or not isinstance(value, (int, str, float)):
            raise ValueError(f"{key}: 0 이상의 정수여야 합니다 (받은 값: {value!r})")
        try:
            n = int(str(value).strip())
        except ValueError:
            raise ValueError(f"{key}: 0 이상의 정수여야 합니다 (받은 값: {value!r})") from None
        if n < 0:
            raise ValueError(f"{key}: 0 이상의 정수여야 합니다 (받은 값: {value!r})")
        return n
    # globs — 목록 또는 쉼표 구분 문자열. 빈 목록은 "아무 이름도 안 잡음" 이라 허용하지 않는다(라벨은 여전히 잡힘이지만
    # 실수로 비우는 걸 막는다; 끄려면 stale_test_artifacts_days=0).
    items = value if isinstance(value, (list, tuple)) else str(value).split(",")
    globs = [str(x).strip() for x in items if str(x).strip()]
    if not globs:
        raise ValueError(f"{key}: 글롭을 하나 이상 주세요 (예: 'marina-*-e2e-*,mdce2e*')")
    return globs


def load_policy() -> dict[str, Any]:
    """정책 파일 + 기본값. 없음/깨짐/모르는 키/틀린 타입은 그 키만 기본값으로 두고 `warnings` 에 적는다."""
    policy = {k: (list(v) if isinstance(v, list) else v) for k, v in DEFAULT_POLICY.items()}
    warnings: list[str] = []
    raw: Any = None
    if POLICY_FILE.exists():
        try:
            raw = json.loads(POLICY_FILE.read_text(encoding="utf-8"))
        except Exception as exc:
            warnings.append(f"정책 파일을 읽지 못해 기본값을 씁니다: {exc}")
            raw = None
        if raw is not None and not isinstance(raw, dict):
            warnings.append("정책 파일이 객체가 아니라 기본값을 씁니다")
            raw = None
    for key, value in (raw or {}).items():
        try:
            policy[key] = _coerce(key, value)
        except ValueError as exc:
            warnings.append(f"{exc} → 기본값")
    policy["warnings"] = warnings
    return policy


def _atomic_write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix="." + path.name + ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def set_policy(key: str, value: Any) -> dict[str, Any]:
    """한 키를 검증해 바꾸고 원자적으로 쓴다. 틀리면 ValueError 이고 파일은 안 건드린다."""
    coerced = _coerce(key, value)          # 파일 읽기 전에 검증 — 실패해도 파일 무변경
    current = load_policy()
    data = {k: current[k] for k in DEFAULT_POLICY}
    data[key] = coerced
    _atomic_write_json(POLICY_FILE, data)
    return load_policy()


# ─────────────────────────── 상태·주기 ───────────────────────────

def load_state() -> dict[str, Any]:
    try:
        data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def next_run_at(policy: dict[str, Any], state: dict[str, Any]) -> float | None:
    """마지막 실행(성공·실패 무관) + interval. 기록이 없으면 None(= 지금)."""
    last = state.get("finishedAt")
    if not isinstance(last, (int, float)):
        return None
    return float(last) + float(policy.get("interval_hours", DEFAULT_POLICY["interval_hours"])) * 3600.0


def due(policy: dict[str, Any], state: dict[str, Any], now: float | None = None) -> bool:
    if not policy.get("enabled", True):
        return False
    now = time.time() if now is None else now
    nxt = next_run_at(policy, state)
    return nxt is None or now >= nxt
