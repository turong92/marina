"""marina_discord_usage.py — discord 의 사용량·컨텍스트 % (분리 B, 스펙 R3).

대시보드 쪽(세션 목록·사용량 모듈)과 같은 계산의 **사본**이다 — 공용 모듈로 묶으면 discord 와 dashboard 가 다시 엮인다.
  · claude_windows(): 구독 사용량 창(5시간·주간…) — /api/oauth/usage 직접 조회, 실패하면 신선한 claude-hud 캐시
  · context_percent(transcript): 세션 기록의 마지막 assistant usage 로 컨텍스트 %
"""
from __future__ import annotations

import json
import math
import mmap
import re
from datetime import datetime, timezone
import os
import subprocess
import time
import urllib.request
from pathlib import Path
from typing import Any, Optional

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


CLAUDE_CONFIG_FILE = Path(os.environ.get("CLAUDE_CONFIG_FILE", str(Path.home() / ".claude.json")))


CLAUDE_USAGE_CACHE_FILE = Path(os.environ.get(
    "CLAUDE_USAGE_CACHE_FILE",
    str(Path.home() / ".claude" / "plugins" / "claude-hud" / ".usage-cache.json"),
))


CLAUDE_USAGE_CACHE_MAX_AGE_MS = int(os.environ.get("CLAUDE_USAGE_CACHE_MAX_AGE_MS", "300000"))


def _reverse_json_objects(path: Path):
    """Yield complete JSONL objects newest-first without a fixed tail window."""
    if not path.is_file() or path.stat().st_size == 0:
        return
    with path.open("rb") as handle:
        with mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as data:
            cursor = len(data)
            while cursor > 0:
                line_end = cursor - 1 if data[cursor - 1] == 10 else cursor
                if line_end <= 0:
                    break
                newline = data.rfind(b"\n", 0, line_end)
                line_start = newline + 1
                raw = data[line_start:line_end].strip()
                cursor = line_start
                if not raw.startswith(b"{"):
                    continue
                try:
                    obj = json.loads(raw)
                except Exception:
                    continue
                if isinstance(obj, dict):
                    yield obj


def _usage_token_count(usage: dict[str, Any], key: str) -> int:
    value = usage.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return 0
    return max(0, int(value))


# Claude Code CLI 가 받는 모델 + 네이티브 컨텍스트 윈도우(권위 자료: claude-api 스킬, 2026).
# codex 는 ~/.codex/models_cache.json 을 쓰지만 Claude Code 는 완전한 모델 캐시가 없다
# (~/.claude.json additionalModelOptionsCache 는 사용자가 직접 만진 커스텀 모델만 담아 불완전).
# 그래서 모바일 모델 드롭다운과 컨텍스트 윈도우 폴백을 이 큐레이트 목록에서 공급한다.
# 기본값 + 정식 버전만(형 지시 — opus/sonnet/haiku alias '최신' 항목은 헷갈려 제거). 목록에 없는 건 "직접 입력"으로.
# 지금 제공되는 모델 전부(2026-09-23 갱신 — CLI 2.1.280 바이너리의 모델 id 목록과 대조). 순서는 **고르는 빈도**다 — 기본값·Opus 5 가 위,
# 지난 세대는 아래. Mythos 는 Project Glasswing 전용이라 넣지 않는다(고를 수 없는 걸 보여주면
# 눌러보고 나서야 안 된다는 걸 안다). id 에 날짜 접미사를 붙이지 않는다 — 표의 문자열 그대로다.
CLAUDE_MODEL_CATALOG = [
    {"value": "default", "label": "기본값 (CLI 설정 모델)", "window": None},
    {"value": "claude-opus-5-5", "label": "Opus 5.5", "window": 1_000_000},
    {"value": "claude-opus-5", "label": "Opus 5", "window": 1_000_000},
    {"value": "claude-fable-5-1", "label": "Fable 5.1", "window": 1_000_000},
    {"value": "claude-fable-5", "label": "Fable 5", "window": 1_000_000},
    {"value": "claude-opus-4-8", "label": "Opus 4.8", "window": 1_000_000},
    {"value": "claude-opus-4-7", "label": "Opus 4.7", "window": 1_000_000},
    {"value": "claude-opus-4-6", "label": "Opus 4.6", "window": 1_000_000},
    {"value": "claude-sonnet-5", "label": "Sonnet 5", "window": 1_000_000},
    {"value": "claude-sonnet-4-6", "label": "Sonnet 4.6", "window": 1_000_000},
    {"value": "claude-haiku-5-5", "label": "Haiku 5.5", "window": 1_000_000},
    {"value": "claude-haiku-4-5", "label": "Haiku 4.5", "window": 200_000},
]


_CLAUDE_WINDOW_BY_MODEL = {m["value"]: m["window"] for m in CLAUDE_MODEL_CATALOG if m["window"]}


def _model_context_window(value: str) -> int | None:
    match = re.search(r"\[(\d+(?:\.\d+)?)([km])\]$", value.strip().lower())
    if not match:
        return None
    multiplier = 1_000 if match.group(2) == "k" else 1_000_000
    return int(float(match.group(1)) * multiplier)


def _claude_context_window(model: str) -> int | None:
    direct = _model_context_window(model)
    if direct is not None or not model:
        return direct
    try:
        config = json.loads(CLAUDE_CONFIG_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        config = None
    options = config.get("additionalModelOptionsCache") if isinstance(config, dict) else None
    if isinstance(options, list):
        for option in options:
            value = str(option.get("value") or "") if isinstance(option, dict) else ""
            if value.split("[", 1)[0] == model:
                window = _model_context_window(value)
                if window is not None:
                    return window
    # 폴백 — 트랜스크립트의 message.model 은 접미사 없는 bare id(claude-opus-4-8)라 위 두 경로가 못 잡는다.
    # 알려진 Claude 모델의 네이티브 윈도우로 컨텍스트% 를 계산(없으면 모바일 usage 패널이 "-" 로 뜬다).
    return _CLAUDE_WINDOW_BY_MODEL.get(model)


def _empty_agent_usage(source: str, model: str = "") -> dict[str, Any]:
    return {
        "source": source,
        "model": model,
        "usedTokens": None,
        "contextWindow": None,
        "remainingTokens": None,
        "contextPercent": None,
    }


def _usage_percent(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return None
    return min(100.0, max(0.0, round(float(value), 1)))


def _usage_reset_timestamp(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(value):
        return int(value)
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return int(parsed.timestamp())
    except ValueError:
        return None


def _usage_window(key: str, label: str, used: Any, reset: Any) -> dict[str, Any] | None:
    percent = _usage_percent(used)
    if percent is None:
        return None
    return {
        "key": key,
        "label": label,
        "usedPercent": percent,
        "remainingPercent": round(100.0 - percent, 1),
        "resetsAt": _usage_reset_timestamp(reset),
    }


_USAGE_PERCENT_KEYS = ("percent", "utilization", "used_percent", "usedPercent", "percentage")


_USAGE_RESET_KEYS = ("resets_at", "resetAt", "resetsAt")


# limits 항목의 kind → 우리 창. 나머지(weekly_scoped 등)는 모델 이름으로 칸을 만든다.
_CLAUDE_LIMIT_KINDS = {"session": ("fiveHour", "5시간"), "weekly_all": ("weekly", "주간")}


def _scoped_weekly_slot(name: Any) -> tuple[str, str]:
    """'Fable 5' → ('fableWeekly', 'Fable 주간'). 버전 꼬리는 뗀다 — 모델이 올라가도 같은 칸에 쌓인다."""
    head = next((part for part in re.split(r"[\s_-]+", str(name or "").strip()) if part), "")
    if not head or not head[0].isalpha():
        return "", ""
    return head[0].lower() + head[1:] + "Weekly", f"{head} 주간"


def _claude_limit_windows(data: dict[str, Any]) -> list[tuple[str, str, Any, Any]]:
    """`limits` 배열을 창 후보로 편다.

    **이 배열이 계정 한도의 진짜 목록이다.** 평평한 seven_day_opus/seven_day_sonnet 등은 이 계정에서
    전부 null 인데 배열에는 페이블 주간이 들어 있었다 — 평평한 키만 보면 영영 안 보인다. 모델을
    하드코딩하지 않는다: 새 모델이 생기면 배열에 얹혀 그대로 뜬다.

    hud 캐시의 옛 모양({"display_name": …, "utilization": …})도 같이 받는다.
    """
    entries = data.get("limits")
    if not isinstance(entries, list):
        return []
    found: list[tuple[str, str, Any, Any]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        percent = next((entry[name] for name in _USAGE_PERCENT_KEYS if entry.get(name) is not None), None)
        if percent is None:
            continue
        reset = next((entry[name] for name in _USAGE_RESET_KEYS if entry.get(name) is not None), None)
        slot = _CLAUDE_LIMIT_KINDS.get(str(entry.get("kind") or ""))
        if slot:
            found.append((slot[0], slot[1], percent, reset))
            continue
        scope = entry.get("scope") if isinstance(entry.get("scope"), dict) else {}
        model = scope.get("model") if isinstance(scope.get("model"), dict) else {}
        key, label = _scoped_weekly_slot(
            model.get("display_name") or model.get("displayName")
            or entry.get("display_name") or entry.get("displayName") or entry.get("name"))
        if key:
            found.append((key, label, percent, reset))
    return found


def account_usage_from_claude_cache(cache: dict[str, Any] | None) -> dict[str, Any]:
    """Claude 계정 사용량을 창 목록으로 정규화한다(공식 /api/oauth/usage 응답과 hud 캐시 두 모양)."""
    value = cache.get("data") if isinstance(cache, dict) and isinstance(cache.get("data"), dict) else cache
    data = value if isinstance(value, dict) else {}
    scoped = _claude_limit_windows(data)
    from_limits = {key: (percent, reset) for key, _, percent, reset in reversed(scoped)}
    windows: list[dict[str, Any]] = []
    emitted: set[str] = set()
    # 모델별 주간 창은 계정/플랜에 따라 있을 때만 값이 온다(없으면 null → 창이 안 생긴다).
    for key, label, percent_keys, reset_keys in (
        ("fiveHour", "5시간", ("fiveHour", "five_hour"), ("fiveHourResetAt", "five_hour_reset_at")),
        ("weekly", "주간", ("sevenDay", "seven_day"), ("sevenDayResetAt", "seven_day_reset_at")),
        ("opusWeekly", "Opus 주간", ("sevenDayOpus", "seven_day_opus"), ()),
        ("sonnetWeekly", "Sonnet 주간", ("sevenDaySonnet", "seven_day_sonnet"), ()),
        ("fableWeekly", "Fable 주간", ("fableWeekly", "fable_weekly", "sevenDayFable", "seven_day_fable"),
         ("fableWeeklyResetAt", "fable_weekly_reset_at", "sevenDayFableResetAt", "seven_day_fable_reset_at")),
    ):
        percent = next((data.get(name) for name in percent_keys if name in data), None)
        reset = next((data.get(name) for name in reset_keys if name in data), None)
        if isinstance(percent, dict):
            item = percent
            percent = next((item.get(name) for name in _USAGE_PERCENT_KEYS if name in item), None)
            reset = next((item.get(name) for name in _USAGE_RESET_KEYS if name in item), reset)
        if percent is None:   # 평평한 키가 없거나 null 이면 limits 배열이 답이다
            percent, reset = from_limits.get(key, (None, reset))
        normalized = _usage_window(key, label, percent, reset)
        if normalized:
            windows.append(normalized)
            emitted.add(key)
    # 위 목록에 없는 모델의 주간 창(=우리가 모르는 새 모델)은 응답 순서대로 뒤에 붙인다
    for key, label, percent, reset in scoped:
        normalized = _usage_window(key, label, percent, reset) if key not in emitted else None
        if normalized:
            windows.append(normalized)
            emitted.add(key)
    return {"source": "claude", "windows": windows}


def _normalized_agent_usage(source: str, model: str, used: int,
                            window: int | None) -> dict[str, Any]:
    if window is None or window <= 0:
        remaining = None
        percent = None
    else:
        remaining = max(0, window - used)
        percent = min(100.0, round(used * 100 / window, 1))
    return {
        "source": source,
        "model": model,
        "usedTokens": used,
        "contextWindow": window,
        "remainingTokens": remaining,
        "contextPercent": percent,
    }


def agent_usage_from_path(path: Path, source: str) -> dict[str, Any]:
    """Read the newest native context counter without scanning session history."""
    if source not in ("claude", "codex"):
        raise ValueError("unknown source")
    if not path.is_file():
        return _empty_agent_usage(source)
    for obj in _reverse_json_objects(path):
        if source == "codex":
            payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
            if obj.get("type") != "event_msg" or payload.get("type") != "token_count":
                continue
            info = payload.get("info") if isinstance(payload.get("info"), dict) else {}
            latest = info.get("last_token_usage") if isinstance(info.get("last_token_usage"), dict) else {}
            used = latest.get("total_tokens")
            window = info.get("model_context_window")
            if isinstance(used, bool) or not isinstance(used, (int, float)):
                continue
            normalized_window = int(window) if isinstance(window, (int, float)) and not isinstance(window, bool) else None
            return _normalized_agent_usage(source, "", max(0, int(used)), normalized_window)
        if obj.get("type") != "assistant":
            continue
        message = obj.get("message") if isinstance(obj.get("message"), dict) else {}
        usage = message.get("usage") if isinstance(message.get("usage"), dict) else {}
        if not usage:
            continue
        model = str(message.get("model") or "")
        used = sum(_usage_token_count(usage, key) for key in (
            "input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens",
        ))
        return _normalized_agent_usage(source, model, used, _claude_context_window(model))
    return _empty_agent_usage(source)


def claude_windows() -> list[dict[str, Any]]:
    payload = None
    try:
        payload = claude_usage_payload()
    except Exception:
        payload = None
    if payload:
        live = account_usage_from_claude_cache(payload)
        if live.get("windows"):
            return list(live["windows"])
    try:
        cache = json.loads(CLAUDE_USAGE_CACHE_FILE.read_text(encoding="utf-8"))
        ts = cache.get("timestamp") if isinstance(cache, dict) else None
        if not isinstance(ts, (int, float)) or time.time() * 1000 - ts > CLAUDE_USAGE_CACHE_MAX_AGE_MS:
            return []
        return list(account_usage_from_claude_cache(cache).get("windows") or [])
    except (OSError, ValueError):
        return []


def context_percent(transcript: Path) -> Optional[float]:
    try:
        return agent_usage_from_path(Path(transcript), "claude").get("contextPercent")
    except Exception:
        return None
