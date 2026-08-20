"""Mobile control surface: token-protected, minimal phone UI for sending prompts."""
from __future__ import annotations

import hmac
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import threading
import time
import urllib.parse
from pathlib import Path
from typing import Any

from marina_registry import discover_all_roots
from marina_rooms import build_room, change_summary, finalize_room, room_has_changes
from marina_agent_events import latest_agent_event
from marina_sessions import (
    _live_agent_cwds,
    _live_agent_tids,
    _native_agent_status,
    _root_has_live_agent,
    agent_runtime_settings,
    agent_transcript_path,
    agent_usage_from_path,
    AGENTS_MAX_PER_ROOT,
    agents_payload,
    claude_model_catalog,
    resolve_session_liveness,
    safe_root,
    worktree_info,
    worktree_labels,
)
from marina_login import extract_login_url, login_stage
from marina_paths import write_meta
from marina_state import MARINA_HOME, PORT
from marina_term import (_agent_cli, term_await_redraw, term_input, term_kill, term_list,
                         term_open, term_output_mark, term_tail)


TOKEN_FILE = MARINA_HOME / "mobile-token"
CLAUDE_HOME = Path(os.environ.get("CLAUDE_HOME", str(Path.home() / ".claude")))
CODEX_USER_HOME = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
AGENTS_HOME = Path(os.environ.get("AGENTS_HOME", str(Path.home() / ".agents")))
PENDING_SETTINGS_FILE = MARINA_HOME / "mobile-pending-agent-settings.json"
# 라이브로 먹인 설정의 기억. current 는 트랜스크립트의 마지막 assistant 행에서 읽는데, /model 을
# 쳐도 다음 응답 전엔 새 행이 없다 — 그 공백 동안 화면이 옛 모델로 되돌아가 "안 먹었다"로 보인다.
APPLIED_SETTINGS_FILE = MARINA_HOME / "mobile-applied-agent-settings.json"
CODEX_MODELS_FILE = CODEX_USER_HOME / "models_cache.json"
_SESSION_SETTINGS_LOCK = threading.Lock()
_AGENT_SEND_LOCK = threading.Lock()
AGENT_INPUT_SETTLE_S = 0.16
# 인수인계(takeover): SIGTERM 후 이만큼 기다렸다가 안 죽으면 SIGKILL.
TAKEOVER_TIMEOUT_S = float(os.environ.get("MARINA_TAKEOVER_TIMEOUT_S", "3"))
_SERVER_INSTANCE = secrets.token_hex(8)   # 프로세스마다 새 값 — 데몬 재시작 감지용(모바일이 바뀌면 자동 새로고침)


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return value if isinstance(value, dict) else {}


def _session_settings_key(root: Path, source: str, sid: str) -> str:
    return f"{root.resolve()}\n{source}\n{sid}"


def mobile_pending_session_settings(root: Path, source: str, sid: str) -> dict[str, str]:
    raw = _read_json(PENDING_SETTINGS_FILE).get(_session_settings_key(root, source, sid))
    if not isinstance(raw, dict):
        return {"model": "", "effort": ""}
    return {"model": str(raw.get("model") or ""), "effort": str(raw.get("effort") or "")}


def _settings_file_update(path: Path, key: str, value: Any) -> None:
    """키 하나짜리 JSON 파일의 원자적 갱신 — value=None 이면 삭제.

    pending/applied 세션 설정과 방 아카이브가 같이 쓴다(값은 dict 든 숫자든 상관없다).
    직접 write 하지 않는 이유: 임시파일 → chmod 0600 → replace 를 락 안에서 해야 동시에
    두 요청이 들어와도 파일이 반쪽으로 남지 않는다."""
    with _SESSION_SETTINGS_LOCK:
        payload = _read_json(path)
        if value is None:
            if key not in payload:
                return
            payload.pop(key, None)
        else:
            payload[key] = value
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
        try:
            temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            os.chmod(temporary, 0o600)
            os.replace(temporary, path)
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def _persist_pending_session_settings(root: Path, source: str, sid: str,
                                      value: dict[str, str]) -> None:
    _settings_file_update(PENDING_SETTINGS_FILE, _session_settings_key(root, source, sid), value)


def _diff_against_current(root: Path, source: str, sid: str,
                          value: dict[str, str]) -> dict[str, str]:
    """이미 현재값과 같은 항목은 지운다 — **바꾼 것만** 슬래시로 친다(형: "바꾼것만 보고 바로
    적용돼야"). 모델만 바꿨는데 강도까지 다시 치면 느리고, 예약 배지도 안 바꾼 항목까지 물고
    늘어진다. 현재값을 모르면(빈 문자열) 지우지 않는다 — 모르는 것과 같은 것은 다르다."""
    current = mobile_current_session_settings(root, source, sid)
    return {key: ("" if value[key] and value[key] == current.get(key) else value[key])
            for key in ("model", "effort")}


def mobile_update_session_settings(body: dict[str, Any]) -> dict[str, str]:
    root = safe_root(str(body.get("root") or ""))
    source = str(body.get("source") or "")
    sid = str(body.get("sid") or "")
    value = {"model": str(body.get("model") or ""), "effort": str(body.get("effort") or "")}
    _agent_cli(source, sid, model=value["model"], effort=value["effort"])
    with _AGENT_SEND_LOCK:
        wanted = _diff_against_current(root, source, sid, value)
        if not (wanted["model"] or wanted["effort"]):
            _clear_pending_session_settings(root, source, sid)   # 이미 그 값 — 남은 예약도 무의미
            return {**value, "applyMode": "live"}
        tid = _live_agent_tid(root, source, sid)
        try:
            if _apply_live_agent_settings(root, source, sid, tid, wanted["model"], wanted["effort"]):
                _clear_pending_session_settings(root, source, sid)
                return {**value, "applyMode": "live"}
        except (OSError, ValueError):
            pass
        # 왜 미뤘는지까지 말해야 한다. 살아있는 세션에 "다음 Marina 연결에 적용합니다"라고만 하면
        # 그 '다음'이 언제인지 알 수 없고, 실제로 오지 않을 수도 있다.
        # unverified = 쳤는데 트랜스크립트에 실행 행이 안 보였다 — 드레이너가 유휴 때 재시도한다.
        if not tid:
            reason = "detached"
        elif _native_agent_active(root, source, sid):
            reason = "busy"
        else:
            reason = "unverified"
        _persist_pending_session_settings(
            root, source, sid, {**wanted, "attempts": 1} if reason == "unverified" else wanted)
    return {**value, "applyMode": "pending", "pendingReason": reason}


def _clear_pending_session_settings(root: Path, source: str, sid: str) -> None:
    _settings_file_update(PENDING_SETTINGS_FILE, _session_settings_key(root, source, sid), None)


def _record_applied_session_settings(root: Path, source: str, sid: str,
                                     model: str, effort: str) -> None:
    """라이브 적용 성공을 기억한다 — 트랜스크립트가 따라잡을 때까지 current 를 이 값으로 보인다.

    base = 적용 시점의 트랜스크립트 값. 다음 턴이 기록되면(어느 모델이든) current 가 base 에서
    벗어나고, 그 순간부터는 트랜스크립트가 진실이다(기록은 지운다). CLI 에서 직접 바꾼 경우도
    같은 규칙으로 자연히 트랜스크립트가 이긴다."""
    base = agent_runtime_settings(root, source, sid)
    _settings_file_update(APPLIED_SETTINGS_FILE, _session_settings_key(root, source, sid), {
        "model": model, "effort": effort,
        "baseModel": base["model"], "baseEffort": base["effort"], "ts": time.time(),
    })


def mobile_current_session_settings(root: Path, source: str, sid: str) -> dict[str, str]:
    """화면의 '현재 모델·강도'. 트랜스크립트 값 위에, 방금 라이브로 먹인 값을 덮는다."""
    current = agent_runtime_settings(root, source, sid)
    key = _session_settings_key(root, source, sid)
    record = _read_json(APPLIED_SETTINGS_FILE).get(key)
    if not isinstance(record, dict):
        return current
    caught_up = current != {"model": str(record.get("baseModel") or ""),
                            "effort": str(record.get("baseEffort") or "")}
    if caught_up:
        _settings_file_update(APPLIED_SETTINGS_FILE, key, None)
        return current
    return {"model": str(record.get("model") or "") or current["model"],
            "effort": str(record.get("effort") or "") or current["effort"]}


def mobile_agent_options() -> dict[str, Any]:
    codex_models: list[dict[str, Any]] = []
    for item in (_read_json(CODEX_MODELS_FILE).get("models") or []):
        if not isinstance(item, dict):
            continue
        value = str(item.get("slug") or "")
        if not value:
            continue
        efforts = [
            str(level.get("effort")) for level in (item.get("supported_reasoning_levels") or [])
            if isinstance(level, dict) and level.get("effort")
        ]
        codex_models.append({"value": value, "label": str(item.get("display_name") or value), "efforts": efforts})
    # Claude 는 codex 의 models_cache.json 같은 완전한 캐시가 없어 큐레이트 카탈로그로 드롭다운을 채운다
    # (marina_sessions.CLAUDE_MODEL_CATALOG — 컨텍스트 윈도우 폴백과 같은 출처). manualModel 로 "직접 입력"도 유지.
    # 모바일 표기 통일: 실모델은 "Claude Opus 4.8" 처럼 브랜드 포함(default 안내문구는 그대로). 데스크톱 카탈로그(CLAUDE_MODEL_CATALOG)는 불변.
    claude_models = [
        {"value": m["value"], "label": m["label"] if m["value"] == "default" else f"Claude {m['label']}"}
        for m in claude_model_catalog()
    ]
    return {
        "codex": {"models": codex_models, "efforts": ["low", "medium", "high", "xhigh", "max", "ultra"], "manualModel": True},
        "claude": {"models": claude_models, "efforts": ["low", "medium", "high", "xhigh", "max"], "manualModel": True},
    }


def _definition(path: Path) -> tuple[str, str]:
    try:
        raw = path.read_text(encoding="utf-8")[:16_384]
    except OSError:
        return "", ""
    data: dict[str, Any] = {}
    if path.suffix == ".toml":
        for match in re.finditer(r'(?m)^(name|description)\s*=\s*(["\'])(.*?)\2\s*$', raw):
            data[match.group(1)] = match.group(3)
    elif raw.startswith("---"):
        for line in raw.splitlines()[1:]:
            if line.strip() == "---":
                break
            match = re.match(r"^(name|description):\s*(.*?)\s*$", line)
            if match:
                data[match.group(1)] = match.group(2).strip("'\"")
    fallback = path.parent.name if path.name == "SKILL.md" else path.stem
    return str(data.get("name") or fallback), str(data.get("description") or "")


def _catalog_item(path: Path, insert_prefix: str, scope: str = "") -> dict[str, str] | None:
    name, description = _definition(path)
    if not name:
        return None
    scoped = f"{scope}:{name}" if scope else name
    return {"name": scoped, "insert": f"{insert_prefix}{scoped}" if insert_prefix else "", "description": description}


def _dedupe_catalog(items: list[dict[str, str]]) -> list[dict[str, str]]:
    deduped: dict[str, dict[str, str]] = {}
    for item in items:
        key = item.get("insert") or item.get("name") or ""
        if key and key not in deduped:
            deduped[key] = item
    return sorted(deduped.values(), key=lambda item: item.get("name", "").lower())


def _claude_plugin_roots(root: Path) -> list[tuple[str, Path]]:
    enabled_state: dict[str, bool] = {}
    for settings_path in (CLAUDE_HOME / "settings.json", root / ".claude" / "settings.json", root / ".claude" / "settings.local.json"):
        settings = _read_json(settings_path)
        for name, value in (settings.get("enabledPlugins") or {}).items():
            if isinstance(value, bool):
                enabled_state[str(name)] = value
    enabled = {name for name, value in enabled_state.items() if value}
    installed = (_read_json(CLAUDE_HOME / "plugins" / "installed_plugins.json").get("plugins") or {})
    roots: list[tuple[str, Path]] = []
    for key in sorted(enabled):
        records = installed.get(key) if isinstance(installed, dict) else None
        if not isinstance(records, list) or not records:
            continue
        path = Path(str((records[-1] or {}).get("installPath") or ""))
        if path.is_dir():
            roots.append((key.split("@", 1)[0], path))
    return roots


def _codex_plugin_roots() -> list[tuple[str, Path]]:
    try:
        config = (CODEX_USER_HOME / "config.toml").read_text(encoding="utf-8")
    except OSError:
        config = ""
    roots: list[tuple[str, Path]] = []
    sections = re.finditer(r'(?ms)^\[plugins\."([^"]+)"\]\s*(.*?)(?=^\[|\Z)', config)
    for section in sections:
        key, body = section.group(1), section.group(2)
        if not re.search(r"(?m)^enabled\s*=\s*true\s*$", body):
            continue
        name, _, marketplace = str(key).partition("@")
        base = CODEX_USER_HOME / "plugins" / "cache" / marketplace / name
        versions = [path for path in base.iterdir() if path.is_dir()] if base.is_dir() else []
        if versions:
            roots.append((name, max(versions, key=lambda path: path.stat().st_mtime)))
    return roots


def _native_catalog(root: Path, source: str) -> dict[str, list[dict[str, str]]]:
    skills: list[dict[str, str]] = []
    agents: list[dict[str, str]] = []
    if source == "claude":
        for base in (CLAUDE_HOME, root / ".claude"):
            for path in base.glob("skills/*/SKILL.md"):
                item = _catalog_item(path, "/")
                if item:
                    skills.append(item)
            for path in base.glob("commands/*.md"):
                item = _catalog_item(path, "/")
                if item:
                    skills.append(item)
            for path in base.glob("agents/**/*.md"):
                item = _catalog_item(path, "@agent-")
                if item:
                    agents.append(item)
        for plugin, plugin_root in _claude_plugin_roots(root):
            for path in plugin_root.glob("skills/*/SKILL.md"):
                item = _catalog_item(path, "/", plugin)
                if item:
                    skills.append(item)
            for path in plugin_root.glob("commands/*.md"):
                item = _catalog_item(path, "/", plugin)
                if item:
                    skills.append(item)
            for path in plugin_root.glob("agents/**/*.md"):
                item = _catalog_item(path, "@agent-", plugin)
                if item:
                    agents.append(item)
    elif source == "codex":
        for base in (AGENTS_HOME, CODEX_USER_HOME, root / ".agents", root / ".codex"):
            for path in base.glob("skills/*/SKILL.md"):
                item = _catalog_item(path, "$")
                if item:
                    skills.append(item)
        for base in (CODEX_USER_HOME, root / ".codex"):
            for path in base.glob("agents/*.toml"):
                item = _catalog_item(path, "")
                if item:
                    agents.append(item)
        for plugin, plugin_root in _codex_plugin_roots():
            for path in plugin_root.glob("skills/*/SKILL.md"):
                item = _catalog_item(path, "$", plugin)
                if item:
                    skills.append(item)
    return {"skills": _dedupe_catalog(skills), "agents": _dedupe_catalog(agents)}


def mobile_catalog(root: Path, source: str, query: str = "") -> dict[str, Any]:
    if source not in ("claude", "codex"):
        raise ValueError("unknown source")
    query = query.strip().lower()[:120]
    files: list[dict[str, str]] = []
    if query:
        try:
            output = subprocess.check_output(
                ["git", "-C", str(root), "ls-files"], text=True, stderr=subprocess.DEVNULL, timeout=2,
            )
        except Exception:
            output = ""
        for name in output.splitlines():
            if query not in name.lower():
                continue
            files.append({"name": name, "insert": f"@{name}", "description": "file"})
            if len(files) >= 30:
                break
    return {**_native_catalog(root, source), "files": files}


def mobile_token() -> str:
    env = os.environ.get("MARINA_MOBILE_TOKEN", "").strip()
    if env:
        return env
    try:
        return TOKEN_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def ensure_mobile_token() -> str:
    token = mobile_token()
    if token:
        return token
    MARINA_HOME.mkdir(parents=True, exist_ok=True)
    token = secrets.token_urlsafe(32)
    TOKEN_FILE.write_text(token + "\n", encoding="utf-8")
    try:
        TOKEN_FILE.chmod(0o600)
    except OSError:
        pass
    return token


def rotate_mobile_token() -> str:
    MARINA_HOME.mkdir(parents=True, exist_ok=True)
    token = secrets.token_urlsafe(32)
    TOKEN_FILE.write_text(token + "\n", encoding="utf-8")
    try:
        TOKEN_FILE.chmod(0o600)
    except OSError:
        pass
    return token


def disable_mobile_token() -> bool:
    try:
        TOKEN_FILE.unlink()
        return True
    except FileNotFoundError:
        return False


def mobile_url(host: str = "") -> str:
    token = ensure_mobile_token()
    host = (host or os.environ.get("MARINA_MOBILE_HOST") or os.environ.get("MARINA_CONTROL_HOST") or "localhost").strip()
    if "://" in host:
        base = host.rstrip("/")
    else:
        port = os.environ.get("MARINA_CONTROL_PORT") or str(PORT)
        base = f"http://{host}:{port}"
    return f"{base}/mobile?token={urllib.parse.quote(token)}"


def mobile_access_status(
    remote_status: dict[str, Any],
    control_host: str,
    control_port: int,
    auth_enabled: bool = False,
) -> dict[str, Any]:
    token = mobile_token()
    remote_url = str(remote_status.get("url") or "").rstrip("/")
    host = str(control_host or "localhost").strip()
    port = int(control_port)
    network_bind = host in ("0.0.0.0", "::", "") or host not in ("localhost", "127.0.0.1", "::1")
    transport = "local"
    if remote_url:
        base = remote_url
        transport = str(remote_status.get("mode") or "tailscale")
    else:
        ips = remote_status.get("ips") if isinstance(remote_status.get("ips"), list) else []
        ip = next((str(value) for value in ips if value and ":" not in str(value)), "")
        if network_bind and bool(remote_status.get("online")) and ip:
            base = f"http://{ip}:{port}"
            transport = "tailscale-ip"
        else:
            display_host = "localhost" if host in ("0.0.0.0", "::", "") else host
            if ":" in display_host and not display_host.startswith("["):
                display_host = f"[{display_host}]"
            base = f"http://{display_host}:{port}"
            if network_bind:
                transport = "network"
    address = base + "/mobile"
    login_url = address
    if token and not auth_enabled:
        login_url += "?token=" + urllib.parse.quote(token)
    reachable = bool(remote_url or (network_bind and transport != "local"))
    return {
        "enabled": bool(auth_enabled or token),
        "tokenEnabled": bool(token),
        "authEnabled": bool(auth_enabled),
        "address": address,
        "loginUrl": login_url if auth_enabled or token else "",
        "reachable": reachable,
        "transport": transport,
        "tailscaleInstalled": bool(remote_status.get("installed")),
        "tailscaleOnline": bool(remote_status.get("online")),
    }


def request_mobile_token(handler: Any, parsed: urllib.parse.ParseResult) -> str:
    header = handler.headers.get("x-marina-mobile-token", "").strip()
    if header:
        return header
    auth = handler.headers.get("authorization", "").strip()
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    query = urllib.parse.parse_qs(parsed.query)
    return (query.get("token", [""])[0] or "").strip()


def mobile_request_ok(handler: Any, parsed: urllib.parse.ParseResult) -> bool:
    expected = mobile_token()
    supplied = request_mobile_token(handler, parsed)
    return bool(expected and supplied and hmac.compare_digest(expected, supplied))


AGENT_QUESTIONS_DIR = MARINA_HOME / "agent-questions"
# 질문 파일은 PostToolUse(답함)·UserPromptSubmit·Stop(중단) 때 훅이 지운다 — 그게 정상 경로다.
# 이 상한은 그 신호가 **영영 안 오는 경우**(세션이 죽었다)를 위한 안전장치다.
# 나이만 보고 내리면 안 된다: 형이 15분 안에 폰을 못 보면 살아 있는 질문이 사라지고, 터미널엔
# 그대로 떠 있다(2026-08-18 형 지적: "ask UI 아예 안뜨고 터미널 가야 보였거든").
# 그래서 **세션이 살아 있으면 상한을 적용하지 않는다** — 살아 있다면 그 질문은 여전히 형을
# 기다리는 중이다.
_QUESTION_STALE_S = 900


def _question_state_token(sid: str) -> str:
    """pending AskUserQuestion 상태파일의 식별 토큰(없으면 "").

    답이 실제로 먹혔는지 판정하는 유일한 서버측 진실이다 — PostToolUse 훅이 답변 완료 때 파일을
    지우므로, 토큰이 바뀌거나 사라지면 그 질문은 끝난 것이다. PTY 에 키를 쓰는 건 무조건 성공하니까
    (200) 이 확인이 없으면 "안 갔는데 갔다고 하는" 상태를 구분할 수가 없다."""
    if not sid:
        return ""
    try:
        data = json.loads((AGENT_QUESTIONS_DIR / f"claude-{sid}.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    return f"{data.get('toolUseId') or ''}:{data.get('ts') or ''}"


def mobile_pending_question(source: str, sid: str) -> dict[str, Any] | None:
    # PreToolUse 훅(marina_question.py)이 기록한 pending AskUserQuestion 을 읽는다.
    # 트랜스크립트엔 답 전까지 질문이 없으므로, pending 창 동안 카드를 그리는 유일한 라이브 소스.
    if source != "claude" or not sid:
        return None
    try:
        data = json.loads((AGENT_QUESTIONS_DIR / f"claude-{sid}.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    questions = data.get("questions")
    if not isinstance(questions, list) or not questions:
        return None
    나이 = time.time() - float(data.get("ts") or 0)
    if 나이 > _QUESTION_STALE_S and not _agent_proc_lookup("claude", sid):
        # 상한을 넘겼고 그 세션도 살아 있지 않다 = 답할 상대가 없는 카드. 눌러봐야 아무 일도
        # 안 나므로 내린다. 반대로 살아 있으면 몇 시간이 지나도 보여준다.
        return None
    return {"questions": questions, "toolUseId": str(data.get("toolUseId") or ""),
            "token": f"{data.get('toolUseId') or ''}:{data.get('ts') or ''}"}


def _agent_proc_lookup(source: str, sid: str) -> dict[str, Any] | None:
    """그 세션이 지금 살아 있나(등록 기록 기준). 모르면 None.

    함수로 감싼 이유는 둘이다: import 실패에도 질문 카드가 죽지 않게, 그리고 테스트가
    살아있음/죽음을 갈아끼울 수 있게."""
    try:
        import marina_agent_procs

        return marina_agent_procs.lookup(source, sid)
    except Exception:
        return None


PINS_FILE = MARINA_HOME / "pinned-worktrees.json"


def mobile_pins() -> list[str]:
    """고정한 워크트리 목록. **서버 저장** — 폰에서 꽂은 핀이 웹에도 보여야 "다시 찾아가기"가 된다.
    핀은 워크트리에만 붙인다(세션은 7일 미활동이면 목록에서 사라져 대상이 증발한다)."""
    try:
        data = json.loads(PINS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    roots = data.get("roots") if isinstance(data, dict) else None
    if not isinstance(roots, list):
        return []
    return [str(item) for item in roots if isinstance(item, str) and item.strip()]


def mobile_set_pin(body: dict[str, Any]) -> dict[str, Any]:
    root = safe_root(str(body.get("root", "")))     # 등록된 워크트리만 — 임의 경로 저장 금지
    pinned = bool(body.get("pinned"))
    key = str(root.resolve())
    roots = [item for item in mobile_pins() if item != key and item != str(root)]
    if pinned:
        roots.insert(0, key)
    PINS_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = PINS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps({"roots": roots}, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, PINS_FILE)
    return {"ok": True, "roots": roots}


_ROOM_LOG_SEEN: set[str] = set()


def _room_log_once(message: str) -> None:
    """방 조립 실패를 **처음 한 번만** 남긴다.

    방 조립은 폴마다 워크트리 수만큼 돈다 — 매번 찍으면 로그가 못 쓰게 되고, 아예 안 찍으면
    방이 영영 안 보이는데 이유를 알 수 없다."""
    if message in _ROOM_LOG_SEEN:
        return
    _ROOM_LOG_SEEN.add(message)
    print(f"[marina] 방 조립 실패: {message}", file=sys.stderr, flush=True)


# 아카이브 = 방을 접어둔다(스펙 §7). 모바일의 '숨김'을 여기로 흡수한다 — 비슷한 개념 둘을
# 따로 둘 이유가 없고, 숨김은 세션 키 단위라 "방이 단위"라는 원칙과 어긋난다.
ARCHIVE_FILE = MARINA_HOME / "archived-rooms.json"


def room_archive() -> dict[str, dict[str, Any]]:
    """접어둔 방들 — 워크트리 경로 → {at: 접은 시각, status: 접을 때 상태}.

    옛 형식(숫자만)도 읽는다 — 형이 이미 접어둔 방이 배포 한 번에 다 펴지면 안 된다."""
    out: dict[str, dict[str, Any]] = {}
    for key, value in _read_json(ARCHIVE_FILE).items():
        if isinstance(value, (int, float)):
            out[str(key)] = {"at": float(value), "mark": None}
        elif isinstance(value, dict) and isinstance(value.get("at"), (int, float)):
            mark = value.get("mark")
            out[str(key)] = {"at": float(value["at"]),
                             "mark": None if mark is None else str(mark)}
    return out


def _archive_entry(root: Path, archive: dict[str, dict[str, Any]]) -> dict[str, Any] | None:
    """저장 키와 조회 키의 모양이 달라도 찾는다.

    저장은 safe_root() 가 resolve 한 경로, 조회는 discover_all_roots() 가 준 원본 경로다.
    지금은 우연히 같지만 프로젝트가 심볼릭 링크 아래로 하나만 들어와도 갈라진다 —
    그러면 접기 버튼이 200 OK 를 받고 파일에도 써지는데 방은 안 접힌다(핀 저장은 이미
    같은 함정을 알고 두 모양을 다 본다)."""
    return archive.get(str(root)) or archive.get(str(Path(root).resolve()))


# 접어둔 방을 도로 펴는 상태 — **형을 부르는 것들만**이다.
# 작업중·대기는 여기 없다: 접는 순간에도 에이전트는 계속 움직여 lastAt 이 갱신되므로,
# '활동이 있으면 편다'로 두면 작업 중인 방은 접자마자 튀어나온다(버튼이 고장 나 보인다).
# "접어둠"은 지금 안 본다는 뜻이지 멈추라는 뜻이 아니다.
_ROOM_ATTENTION = ("응답필요", "문제")
# 완료도 "접어둔 뒤에 그렇게 됐다면" 보여준다 — 접어둘 때 이미 완료였다면 그대로 접힌 채다.
_ROOM_ATTENTION_OR_DONE = _ROOM_ATTENTION + ("완료",)


def room_unarchives(root: Path, archive: dict[str, dict[str, Any]], status: str = "",
                    mark: str = "") -> bool:
    """접어둔 방을 지금 펴야 하나 — **접을 때와 상태가 달라져 형을 부르면** 편다.

    활동 시각(lastAt)을 안 보는 이유가 핵심이다. 시각은 세션 파일의 mtime 인데, 답을
    기다리는 AskUserQuestion 은 **트랜스크립트에 안 써진다**(그래서 PreToolUse 훅으로
    따로 잡는다). 시각으로 관문을 만들면 질문이 떠도 통과를 못 하고, 형은 방이 안 보여서
    답을 못 하고, 답을 안 해서 시각이 안 움직이는 **교착**이 된다.

    상태 문자열이 아니라 **부르는 내용(mark)**을 비교한다. 상태만 보면 "질문 뜬 방을 접었는데
    더 급한 걸 새로 묻는" 경우가 통째로 사라진다 — 상태는 여전히 응답필요라 영영 안 펴진다.
    접기의 취지가 정확히 반대로 작동하는 셈이다.

    접을 때와 같은 내용이면 접힌 채다 — 완료인 채로 치운 방을 파일이 한 번 갱신됐다고 다시
    들이밀면 접기가 무의미하다.

    판정이 서면 호출자가 기록을 **지운다**(끈적한 복귀). 그래야 질문이 15분 뒤 만료돼 상태가
    내려가도 방이 슬그머니 다시 접히지 않는다 — 형이 못 본 채로 잃는 게 최악이다."""
    entry = _archive_entry(root, archive)
    if entry is None:
        return False
    text = str(status)
    if text not in _ROOM_ATTENTION_OR_DONE:
        return False
    if entry["mark"] is None:
        # 접을 때 무엇이었는지 못 적었다(옛 기록이거나 계산 실패). 그때는 **부르는 것만** 편다 —
        # 완료까지 펴면 "접었는데 바로 튀어나온다"가 된다.
        return text in _ROOM_ATTENTION
    return str(mark) != entry["mark"]


def is_source_root(root: Path) -> bool:
    """원본(main) 체크아웃인가 — 지울 수 없는 자리다."""
    try:
        from marina_registry import is_source_checkout, project_for

        project = project_for(root)
        return bool((project and project["root"].resolve() == root.resolve()) or is_source_checkout(root))
    except Exception:
        return True     # 모르면 못 지우는 쪽으로 — 되돌릴 수 없는 동작이다


def canonical_room_agents(root: Path, refresh: bool = False,
                          hide: set[str] | None = None) -> list[dict[str, Any]]:
    """**기준 방**을 이루는 세션들 — 방의 상태·지문은 언제나 이 집합으로 정한다.

    정의를 한 곳에 못 박는 이유: 방 상태를 재는 자리가 둘(목록 조립, 접을 때 기록)인데 서로
    다른 조건으로 재는 실수가 반복됐다. 한쪽은 숨김을 빼고 한쪽은 안 뺐고, 그다음엔 한쪽만
    '7일 넘은 세션까지'를 봤다. 그때마다 증상은 같다 — 접기 버튼이 안 먹는다.

    기준은 **전체보기 아님 + 숨김 제외**다. 전체보기는 더 보여주기만 할 뿐, 무엇이 형을
    부르는지를 바꾸지 않는다."""
    hidden = set(mobile_hidden()) if hide is None else hide
    # 지운 대화는 **기준에서도** 뺀다. 여기 남으면 방 상태·접기 지문이 지운 것에 끌려가고,
    # 전체보기 경로가 이 함수를 다시 부르기 때문에 지운 대화가 탭으로 되살아난다(실측 지적).
    gone = set(forgotten_chats())
    return [item for item in agents_payload(root, refresh, False, limit=0)
            if f"{item.get('source')}:{item.get('sid')}" not in hidden
            and f"{item.get('source')}:{item.get('sid')}" not in gone]


def current_room_mark(root: Path) -> str | None:
    """이 워크트리가 **지금 무엇으로 형을 부르고 있나** — 접을 때 그걸 적어둬야 나중에
    "같은 것"과 "새로 온 것"을 구별한다.

    방 하나만 조립하므로 목록 전체를 만드는 것보다 훨씬 싸다(실측 warm 1ms). 숨김은 항상
    적용한다 — 목록 쪽 계산과 잣대가 같아야 전체보기에서 접은 방이 바로 펴지지 않는다.

    실패하면 None: "모른다"는 뜻이고, 그때는 부르는 상태(질문·실패)에만 펴진다 — 완료로 접은
    방이 바로 튀어나오는 쪽보다, 부르는 방이 한 번 더 보이는 쪽으로 틀린다."""
    try:
        agents = canonical_room_agents(root)
        changed = (any(str(a.get("status") or "") == "completed" for a in agents)
                   and room_has_changes(root))
        return str(build_room(root, worktree_labels(root), agents, has_changes=changed,
                              questions=mobile_pending_question).get("mark") or "")
    except Exception:
        return None


def mobile_set_archived(body: dict[str, Any]) -> dict[str, Any]:
    """방을 접거나 편다. 펼 때는 기록을 지운다 — 남겨두면 왜 안 보이는지 알 수 없다.

    접을 때의 상태를 같이 적는다. "완료인 채로 접었다"와 "접어둔 뒤에 완료가 됐다"를
    구별해야 하기 때문이다(전자는 계속 접힌 채, 후자는 펴진다)."""
    root = safe_root(str(body.get("root") or ""))
    archived = bool(body.get("archived"))
    # 상태는 **서버가 직접 잰다.** 폰이 보낸 값을 믿으면 규칙 전체가 클라이언트 손에 넘어간다 —
    # 안 보내면 ""가 되어 완료로 접은 방이 다음 폴에 바로 펴지고, "완료"를 보내면 영원히
    # 안 펴지는 방을 만들 수 있다. 서버는 이 순간 그 방의 상태를 계산할 수 있다.
    value = {"at": time.time(), "mark": current_room_mark(root)} if archived else None
    _settings_file_update(ARCHIVE_FILE, str(root), value)
    return {"ok": True, "archived": archived, "root": str(root)}


_RELOGIN_STEP_TIMEOUT_S = 12.0     # 브라우저를 열어보고 URL 을 그리기까지 — 실측 5~8초


def mobile_relogin(body: dict[str, Any]) -> dict[str, Any]:
    """폰에서 클로드 로그인을 끝낸다.

    예전엔 로그인이 풀리면 맥에 가야만 했다 — 모바일에 터미널 화면이 없어서 CLI 가 띄우는
    로그인 URL 을 볼 방법이 아예 없었기 때문이다. 여기서 그 화면을 대신 읽어 URL 만 건네주면,
    형은 폰에서 링크를 열고 받은 코드를 입력창에 붙여넣으면 된다.

    step="start" → /login 을 치고 방식을 고른 뒤 URL 을 돌려준다.
    step="code"  → 형이 받은 코드를 그 화면에 넣는다.

    **화면을 보고 넘어간다**(고정 sleep 이 아니라) — 느린 화면에서 어긋나면 엉뚱한 키가
    엉뚱한 자리에 들어간다. 질문 응답 경로에서 같은 실수를 이미 했다."""
    root = safe_root(str(body.get("root") or ""))
    source = str(body.get("source") or "claude")
    sid = str(body.get("sid") or "")
    step = str(body.get("step") or "start")
    if source != "claude":
        raise ValueError("클로드 세션만 지원해요")
    tid = _live_agent_tid(root, source, sid)
    if not tid:
        # 마리나가 쥔 PTY 가 없으면 화면을 못 읽는다 — 손으로 띄운 세션이 그렇다.
        raise ValueError("이 대화는 마리나가 쥐고 있지 않아 폰에서 로그인할 수 없어요")
    # **일하는 중이면 안 친다.** 그 입력은 프롬프트가 아니라 진행 중인 대화에 들어가서
    # 그대로 제출된다. 화면만으로는 판단이 안 선다(평범한 작업 화면은 아무 표식이 없다) —
    # 세션 상태를 본다.
    if step == "start":
        상태 = next((str(item.get("status") or "")
                     for item in agents_payload(root, False, False, limit=0)
                     if str(item.get("sid") or "") == sid), "")
        if 상태 == "working":
            raise ValueError("그 대화가 일하는 중이에요 — 끝나면 다시 해주세요")

    def 화면() -> str:
        return term_tail(tid)

    def 기다린다(원하는: tuple[str, ...]) -> str:
        마감 = time.time() + _RELOGIN_STEP_TIMEOUT_S
        상태 = ""
        while time.time() < 마감:
            상태 = login_stage(화면())
            if 상태 in 원하는:
                return 상태
            time.sleep(0.4)
        return 상태

    if step == "code":
        code = " ".join(str(body.get("code") or "").split())
        if not code:
            raise ValueError("코드를 넣어주세요")
        term_input(tid, code + "\r")
        상태 = 기다린다(("done", "logged_out", ""))
        return {"ok": True, "stage": 상태 or "unknown"}

    term_input(tid, "/login\r")
    상태 = 기다린다(("method", "url"))
    if 상태 == "method":
        # 기본 선택이 1번(구독 계정)이다 — 실측으로 ❯ 가 거기 있다.
        term_input(tid, "\r")
        상태 = 기다린다(("url",))
    url = extract_login_url(화면())
    if not url:
        _room_log_once("relogin: URL 을 못 읽었다 ↓↓↓\n%s" % 화면()[-800:])
        raise ValueError("로그인 화면을 읽지 못했어요. 맥에서 /login 해주세요")
    return {"ok": True, "stage": "url", "url": url}


def mobile_rename_room(body: dict[str, Any]) -> dict[str, Any]:
    """방 이름을 바꾼다 — 저장 자리는 **워크트리 별칭**이다.

    별칭은 웹 대시보드가 이미 쓰는 자리다. 새 저장소를 만들면 같은 것이 두 군데 살고, 웹에서
    고친 이름과 폰에서 고친 이름이 갈라진다. 빈 이름은 지우기 — 자동 이름으로 돌아간다.

    돌려주는 값은 **실제로 저장된 값**이다(write_meta 가 길이를 자른다). 입력을 그대로
    돌려주면 폰에는 긴 이름이 떴다가 다음 폴에 짧게 바뀌어, 안 먹은 것처럼 보인다."""
    root = safe_root(str(body.get("root") or ""))
    # 폰 자판에서 공백이 잘 딸려 온다 — 가운데 중복 공백까지 한 번에 다듬는다.
    name = " ".join(str(body.get("name") or "").split())
    saved = write_meta(root, {"alias": name})
    return {"ok": True, "root": str(root), "name": str(saved.get("alias") or "")}


# 대화 삭제 = **마리나에서만 치우기**. 원본은 그대로 둔다(스펙 §7) — 마리나가 남의 도구
# 데이터를 지우면 사용량·재개·감사 근거가 통째로 없어진다. CLI 로 resume 하면 그대로 이어진다.
#
# 함정: 마리나는 세션을 **파일 스캔으로 발견한다**. 그래서 "목록에서 뺀다"는 잊는 걸로는 안 되고
# **묘비를 저장해야** 한다 — 안 그러면 다음 폴에 되살아난다.
FORGOTTEN_FILE = MARINA_HOME / "forgotten-chats.json"


def forgotten_chats() -> list[str]:
    """지운 대화 키("source:sid"). 서버 저장 — 폰에서 지운 게 웹에도 반영돼야 한다."""
    raw = _read_json(FORGOTTEN_FILE)
    keys = raw.get("keys") if isinstance(raw, dict) else None
    return [str(item) for item in keys or [] if isinstance(item, str) and item.strip()]


def mobile_remove_room(body: dict[str, Any]) -> dict[str, Any]:
    """방을 지운다 — **먼저 보관하고** 지운다(스펙 §7, 형 결정 "1. 따로 빼 2. 지웠다고 해").

    막지 않는 이유: 차단은 사람의 주의력에 기대는 설계라, 형이 안 보면 그 방은 영영 안 치워진다.
    목표는 삭제를 막는 게 아니라 **작업을 잃지 않는 것**이다.

    돌려주는 말에 보관 얘기는 **안 담는다**(형 결정). 멤버는 git 을 모르므로 "따로 저장해뒀어요"
    는 안심이 아니라 물음표를 남긴다 — 보관 사실은 wip/ 브랜치와 감사 로그에서 드러난다."""
    from marina_lifecycle import remove_worktree, stash_before_delete

    from marina_registry import is_source_checkout, project_for

    root = safe_root(str(body.get("root") or ""))
    # **원본(main) 검사를 보관보다 먼저** 한다. 예전엔 보관을 먼저 하고 remove_worktree 가
    # 뒤늦게 거절해서, 형의 미커밋 작업이 wip 브랜치로 커밋되고 워킹트리가 깨끗해진 채
    # "지우기 실패" 만 떴다 — 형 눈엔 하던 작업이 통째로 증발한 것으로 보인다.
    project = project_for(root)
    if (project and project["root"].resolve() == root.resolve()) or is_source_checkout(root):
        raise ValueError("원본은 지울 수 없어요")
    name = str(body.get("name") or "")
    보관 = {"branch": "", "saved": False}
    try:
        보관 = stash_before_delete(root, name)
    except Exception as exc:
        # 보관에 실패하면 **지우지 않는다.** 여기서 밀고 나가면 작업이 사라진다.
        raise ValueError(f"보관하지 못해 지우지 않았어요 · {exc}")
    remove_worktree(root, force=True)   # 보관했으므로 폐기해도 잃을 게 없다
    return {"ok": True, "root": str(root), "stashed": 보관.get("branch") or ""}


def mobile_close_chat(body: dict[str, Any]) -> dict[str, Any]:
    """돌고 있는 대화 프로세스를 끈다 — 폰에서 띄웠으면 폰에서 끌 수 있어야 한다.

    정지(interrupt)는 Esc 한 번이라 붙잡힌 CLI 에는 안 먹는다. 이건 PTY 자체를 닫는다.
    대화 기록은 그대로다 — 다시 열면 이어서 할 수 있다."""
    root = safe_root(str(body.get("root") or ""))
    source = str(body.get("source") or "")
    sid = str(body.get("sid") or "")
    tid = _live_agent_tid(root, source, sid)
    if not tid:
        return {"ok": True, "closed": False}     # 이미 안 돈다 — 오류로 만들면 형이 헷갈린다
    term_kill(tid)
    return {"ok": True, "closed": True}


def mobile_forget_chat(body: dict[str, Any]) -> dict[str, Any]:
    """대화를 마리나에서 치운다. **되돌릴 수 있다**(forget=false) — 원본이 남아 있으므로
    실수로 지웠을 때 되살릴 길이 있어야 한다."""
    source = str(body.get("source") or "")
    sid = str(body.get("sid") or "")
    if source not in ("claude", "codex") or not sid:
        raise ValueError("source/sid 필요")
    key = f"{source}:{sid}"
    forget = body.get("forget")
    keys = [item for item in forgotten_chats() if item != key]
    if forget is None or bool(forget):
        keys.insert(0, key)
    _settings_file_update(FORGOTTEN_FILE, "keys", keys[:1000])
    return {"ok": True, "keys": keys[:1000]}


HIDDEN_FILE = MARINA_HOME / "hidden-sessions.json"


def mobile_hidden() -> list[str]:
    """숨긴 세션 키 목록("source:sid"). 핀과 같은 이유로 **서버 저장** — 기기마다 다르면 정리가 안 된다."""
    try:
        data = json.loads(HIDDEN_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    keys = data.get("keys") if isinstance(data, dict) else None
    if not isinstance(keys, list):
        return []
    return [str(item) for item in keys if isinstance(item, str) and item.strip()]


def mobile_set_hidden(body: dict[str, Any]) -> dict[str, Any]:
    source = str(body.get("source") or "")
    sid = str(body.get("sid") or "")
    if source not in ("claude", "codex") or not sid:
        raise ValueError("source/sid 필요")
    key = f"{source}:{sid}"
    hidden = bool(body.get("hidden"))
    keys = [item for item in mobile_hidden() if item != key]
    if hidden:
        keys.insert(0, key)
    HIDDEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = HIDDEN_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps({"keys": keys[:500]}, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, HIDDEN_FILE)
    return {"ok": True, "keys": keys[:500]}


def mobile_watch_state(refresh: bool = False) -> dict[str, Any]:
    """변화 감지 전용 상태 — **git 을 부르지 않는다.**

    감지 루프는 0.3초마다 돈다. 화면용 mobile_state 를 그대로 쓰면 worktree_info 가 딸려오고,
    그 캐시는 15초 TTL 이라 매번 백그라운드 갱신이 걸린다. 실측: 워크트리 28개 기준
    **초당 git 40회**가 쉬지 않고 돌았다(배포 전에 재서 잡았다).

    감지에 필요한 건 세션의 상태·질문·마지막 활동뿐이다. 워크트리 별칭·브랜치·ahead 배지는
    화면이 그릴 때만 있으면 된다."""
    sessions: list[dict[str, Any]] = []
    for root in discover_all_roots(refresh):
        try:
            for agent in agents_payload(root, refresh, False):
                source = str(agent.get("source") or "")
                sid = str(agent.get("sid") or "")
                question = mobile_pending_question(source, sid)
                sessions.append({
                    "kind": "agent",
                    "key": f"agent:{source}:{sid}:{root}",
                    "root": str(root), "source": source, "sid": sid,
                    "title": agent.get("title") or sid or source,
                    "status": "blocked" if question else (agent.get("status") or "idle"),
                    "ts": agent.get("ts") or 0,
                    "pendingQuestion": question,
                })
        except Exception:
            continue          # 워크트리 하나가 망가져도 나머지 감지는 계속된다
    return {"sessions": sessions}


def mobile_state(refresh: bool = False, include_all: bool = False) -> dict[str, Any]:
    worktrees: list[dict[str, Any]] = []
    sessions: list[dict[str, Any]] = []
    rooms: list[dict[str, Any]] = []
    terms = term_list().get("sessions", [])
    live_cwds = _live_agent_cwds(refresh)   # S1 — root 별 externalActive 판정(ps command= 파싱 없음)
    # 숨긴 세션은 **방에서도** 빠진다. 안 그러면 목록에서 지운 세션이 방 상태를 계속 지배한다
    # (숨긴 failed 세션 하나 때문에 방이 영원히 "문제"로 남고, 방 화면에선 뺄 방법이 없다).
    hidden = mobile_hidden()
    hide = set(hidden)
    # 지운 대화는 **전체보기에서도** 안 나온다 — 숨김("잠깐 접어둠")과 뜻이 다르다.
    # 전체보기에서 되살아나면 지운 의미가 없다.
    gone = set(forgotten_chats())
    # 질문 상태는 한 폴 안에서 **한 번만** 읽는다. 방 조립과 세션 목록이 따로 읽으면 워크트리
    # 28개 × 에이전트 수만큼 파일 열기가 두 배가 된다 — git 은 아끼면서 이걸 늘릴 이유가 없다.
    question_cache: dict[tuple[str, str], Any] = {}

    def pending_question(source: str, sid: str) -> Any:
        key = (source, sid)
        if key not in question_cache:
            question_cache[key] = mobile_pending_question(source, sid)
        return question_cache[key]

    for root in discover_all_roots(refresh):
        try:
            # 이름표만 있으면 된다 — git 배지(브랜치·dirty·ahead)는 '깃' 탭이 따로 가져간다.
            # 예전엔 worktree_info() 를 불러 6개 필드만 꺼내 썼는데, 그 함수는 워크트리마다
            # git 을 ~24번 돌린다(형: "깃을 안보고있는데 깃을 부를 필요가 있나?").
            info = worktree_labels(root)
            root_terms = [t for t in terms if str(t.get("root") or "") == str(root)]
            agent_terms = {
                (str(t["agent"].get("source") or ""), str(t["agent"].get("sid") or "")): t
                for t in root_terms if isinstance(t.get("agent"), dict) and bool(t.get("alive", True))
            }
            # **한 번만** 부른다. 방은 전부 필요하고(탭을 안 자른다) 카드는 상위 3개만 쓰므로,
            # 상한 없이 한 번 받아 잘라 쓴다. 두 번 부르면 세션 JSONL tail 파싱이 통째로 두 배다.
            # 지운 대화는 여기서 통째로 뺀다 — 방 탭에도, 세션 목록에도, 전체보기에도 안 나온다.
            raw_agents = agents_payload(root, refresh, include_all, limit=0)
            # 지운 대화는 기본 화면에서 빠지고, **전체보기에서만** 되살리라고 보인다.
            # 아예 안 보여주면 실수로 지웠을 때 폰에서 되돌릴 길이 없다.
            all_agents = [item for item in raw_agents
                          if include_all
                          or f"{item.get('source')}:{item.get('sid')}" not in gone]
            agents = all_agents[:AGENTS_MAX_PER_ROOT]   # status/reachable/승격 다 resolve_session_liveness 경유
            title = info.get("sessionTitle") or info.get("headSubject") or ""
            label = " · ".join(str(x) for x in (info.get("alias"), title, info.get("projectLabel"), info.get("id")) if x)
            # **방**(스펙 §1) — 워크트리 하나 + 그 안의 세션들이 탭. 같은 자료에서 조립하므로
            # 상태 판정이 두 벌로 갈라지지 않는다. 여기서 터져도 세션 목록은 살아야 한다 —
            # 방은 아직 부가정보고, 목록이 안 뜨면 형은 아무것도 못 한다.
            try:
                # 방은 탭을 **안 자른다**. 카드는 좁아 3개로 끊지만, 방에서 자르면 4번째
                # 대화에 도달할 방법이 없고 잘린 탭의 failed/blocked 가 방 상태에서 사라진다.
                #
                # 상태·지문은 **기준 방**(전체보기 아님 + 숨김 제외)으로만 정한다 —
                # canonical_room_agents 가 그 정의고, 접을 때 기록하는 쪽도 같은 함수를 쓴다.
                # 보는 화면에 따라 달라지면 기록은 한 벌인데 잣대가 두 벌이 되어, 전체보기에서
                # 접은 방이 다음 폴에 바로 펴진다.
                room_agents = (canonical_room_agents(root, refresh, hide) if include_all else
                               [item for item in all_agents
                                if f"{item.get('source')}:{item.get('sid')}" not in hide
                                and f"{item.get('source')}:{item.get('sid')}" not in gone])
                # git 은 completed 가 하나라도 있을 때만 부른다. 완료/대기를 가르는 데만
                # 쓰이는 값이라, 나머지 워크트리에서 git 을 돌리는 건 순수한 낭비다.
                changed = (any(str(a.get("status") or "") == "completed" for a in room_agents)
                           and room_has_changes(root))
                room = build_room(root, info, room_agents, has_changes=changed,
                                  questions=pending_question)
                # 손대야 낫는 사유(로그인 만료·한도)는 방까지 올린다 — 방 목록이 첫 화면이라
                # 여기서 안 보이면 형은 대화를 열어보기 전엔 이유를 모른다.
                막힌사유 = ""
                for agent in room_agents:
                    사유 = str(agent.get("statusReason") or "")
                    if 사유 in ("needs_login", "needs_credit"):
                        막힌사유 = 사유
                        break
                room["blockedReason"] = 막힌사유
                # 원본(main)은 지울 수 없다 — 버튼을 아예 안 그린다. 누를 수 있게 두면
                # 눌러보고 나서야 거절당하고, 그 사이 보관이 형 작업을 커밋해 버린다.
                room["removable"] = not is_source_root(root)
                # 완료 카드 재료 — **끝난 방에만** 싣는다. 아직 도는 방에 "끝났어요"가 붙으면
                # 카드 자체를 못 믿게 된다(스펙 §4 가 completed 오탐을 막으려던 것과 같은 이유).
                # git 은 새로 안 부른다: 완료 판정이 방금 부른 출력에서 뽑아둔 요약을 쓴다.
                if room.get("status") == "완료":
                    room["done"] = change_summary(root)
                if include_all:
                    # 전체보기에서는 나머지도 **보여만 준다**(꺼내서 정리하라고). hidden 표시가
                    # 붙으므로 finalize_room 이 상태·지문·시각 계산에서 알아서 뺀다.
                    shown = {(t["source"], t["sid"]) for t in room["tabs"]}
                    rest = [a for a in all_agents
                            if (str(a.get("source") or ""), str(a.get("sid") or "")) not in shown]
                    if rest:
                        extra = build_room(root, info, rest, has_changes=changed,
                                           questions=pending_question)["tabs"]
                        for tab in extra:
                            # 왜 밖에 있었는지를 **구별해서** 적는다. 형이 숨긴 것은 해제할 수
                            # 있지만, 오래돼서 기준 밖인 것은 해제할 대상이 아니다 — 뭉쳐 놓으면
                            # 숨긴 적 없는 대화에 "숨김" 배지가 붙고 눌러도 안 없어진다.
                            key = f"{tab.get('source')}:{tab.get('sid')}"
                            tab["hidden"] = key in hide
                            tab["stale"] = key not in hide
                            tab["primary"] = False
                        room["tabs"] = room["tabs"] + extra
                        finalize_room(room)     # 탭을 건드렸으면 부른다(값 셋이 같이 움직인다)
                rooms.append(room)
            except Exception as exc:
                # 조용히 넘기면 방이 **영원히 안 보이는데 이유를 알 수 없다**(오타 하나로 전
                # 워크트리가 실패해도 화면은 멀쩡해 보인다). 같은 오류는 한 번만 남긴다 —
                # 폴마다 찍으면 로그가 못 쓰게 된다.
                _room_log_once(f"{type(exc).__name__}: {exc}")
            worktrees.append({
                "id": info.get("id"),
                "alias": info.get("alias") or "",
                "root": str(root),
                "projectId": info.get("projectId"),
                "projectLabel": info.get("projectLabel"),
                "source": info.get("source"),
                "sessionTitle": title,
                "agents": agents,
            })
            # **all_agents** 를 쓴다(카드용 상위 3개가 아니라). 방의 4번째 탭을 눌렀을 때
            # chooseSession 이 이 목록에서 세션을 못 찾으면 아무 일도 안 일어난다 —
            # 탭은 안 잘랐는데 갈 방법이 없었다. 카드 목록은 worktrees[].agents(상위 3개)를 쓴다.
            for agent in all_agents:
                source = str(agent.get("source") or "")
                sid = str(agent.get("sid") or "")
                preview = str(agent.get("preview") or "")
                question = pending_question(source, sid)
                # pending 질문 = 에이전트가 '작업 실행 중'이 아니라 '답을 기다리는 중' → blocked(응답 필요)로 표시(형 지적).
                status = "blocked" if question else (agent.get("status") or "idle")
                agent_term = agent_terms.get((source, sid)) or {}
                # detached(재시작 후 디스크에서 복원된) PTY 는 tid 는 있어도 fd 가 없어 term_input 이 400 —
                # 버튼이 눌리는 것처럼 보이면 안 되니 controllable 은 "살아있는 non-detached tid" 만 True.
                agent_tid = str(agent_term.get("tid") or "")
                controllable = bool(agent_tid) and not bool(agent_term.get("detached"))
                sessions.append({
                    "key": f"agent:{source}:{sid}:{root}",
                    "kind": "agent",
                    "root": str(root),
                    "title": agent.get("title") or sid or source,
                    "subtitle": f"{source} · {label or root.name}",
                    "preview": preview,
                    "source": source,
                    "sid": sid,
                    "target": {"type": "agent", "source": source, "sid": sid},
                    "ts": agent.get("ts") or 0,
                    "status": status,
                    "statusTs": agent.get("statusTs") or agent.get("ts") or 0,
                    "statusReason": "pending_question" if question else (agent.get("statusReason") or ""),
                    "tid": agent_tid,
                    "controllable": controllable,
                    "externalActive": _root_has_live_agent(root, live_cwds),
                    "settings": {
                        "current": mobile_current_session_settings(root, source, sid),
                        "pending": mobile_pending_session_settings(root, source, sid),
                    },
                    "pendingQuestion": question,
                })
            for term in root_terms:
                tid = str(term.get("tid") or "")
                agent_target = term.get("agent") if isinstance(term.get("agent"), dict) else None
                # sid 가 있어야만 대응하는 에이전트 카드가 존재한다 — 그때만 중복이라 뺀다.
                # 직접 launch 한 PTY 는 훅이 뜨기 전까지 sid 가 없다(입양 전). 그걸 여기서 빼버리면
                # 어느 카드에도 안 잡혀 방금 띄운 세션을 열 방법이 사라진다.
                if agent_target and str(agent_target.get("sid") or ""):
                    continue
                target = {"type": "term", "tid": tid}
                # 에이전트로 띄웠지만 아직 sid 가 안 붙은 PTY = **승격 대기**. sid 는 시작 시점에
                # 알 수 없고(훅이 {sid,pid} 를 남겨야 입양된다), 그 전까지 마리나엔 그냥 터미널로
                # 보인다. 그래서 "Claude 대화 열기"를 눌렀는데 제목이 tid 해시고 본문이 CLI 부팅
                # 찌꺼기(`●high·/effort`)로 나왔다 — 고장인 줄 알 수밖에 없다(형 지적).
                # 고장이 아니라 시작 중이라는 걸 말해준다. 첫 메시지를 보내면 승격된다.
                pending_agent = str((term.get("agent") or {}).get("source") or "")
                sessions.append({
                    "key": f"term:{tid}",
                    "kind": "term",
                    "root": str(root),
                    "title": ("새 대화 (시작 중…)" if pending_agent
                              else term.get("fg") or term.get("cmd") or tid),
                    "subtitle": (f"{pending_agent} · {label or root.name}" if pending_agent
                                 else f"터미널 · {label or root.name}"),
                    "preview": ("첫 메시지를 보내면 시작돼요." if pending_agent
                                else term.get("preview") or ""),
                    "tid": tid,
                    "target": target,
                    "turns": [],
                    "ts": term.get("created") or 0,
                })
            if not agents and not root_terms:
                # 세션이 하나도 없는 워크트리의 **자리표시자**. 예전엔 title 이 label 이라
                # "alias · 커밋제목 · 프로젝트 · id" 가 통째로 찍혀, 방금 만든 워크트리가 마치 그
                # 커밋 작업을 하던 세션처럼 보였다(형 지적). alias 는 그룹 헤더에, 프로젝트는 탭에
                # 이미 있으니 제목은 이 카드가 실제로 뭔지만 말한다. 커밋 제목은 브랜치 맥락이라
                # 부제로 남긴다 — 있으면 유용하고, 없어도 그만이다.
                sessions.append({
                    "key": f"shell:{root}",
                    "kind": "shell",
                    "root": str(root),
                    "title": "새 셸 열기",
                    "subtitle": title or root.name,
                    "preview": "",
                    "target": {"type": "shell"},
                    "turns": [],
                    "ts": 0,
                })
        except Exception as exc:
            # 워크트리 하나가 깨져도 나머지는 보여준다. 다만 **말은 하고 넘어간다** —
            # 예전엔 조용히 삼켜서, 이름 하나 잘못 쓴 것 때문에 방이 전부 사라졌는데도
            # 화면은 멀쩡해 보였다(테스트가 아니었으면 못 찾았다).
            _room_log_once(f"{root.name} 조립 실패 {type(exc).__name__}: {exc}")
            worktrees.append({"root": str(root), "error": str(exc), "agents": []})
    sessions.sort(key=lambda s: int(float(s.get("ts") or 0)), reverse=True)
    if not include_all:      # 전체보기가 아니면 숨긴 세션은 목록에서 뺀다
        sessions = [s for s in sessions
                    if f"{s.get('source')}:{s.get('sid')}" not in hide or s.get("kind") != "agent"]
    archive = room_archive()
    for room in rooms:
        root_text = str(room["root"])
        entry = _archive_entry(Path(root_text), archive)
        if entry is None:
            room["archived"] = False
            continue
        if not room_unarchives(Path(root_text), archive, str(room.get("status") or ""),
                               str(room.get("mark") or "")):
            room["archived"] = True
            continue
        # **끈적한 복귀** — 기록을 지운다. 상태가 잠깐 형을 부르다 내려가도(질문은 15분 뒤
        # 만료된다) 방이 슬그머니 다시 접히면 형은 그걸 못 본 채로 잃는다.
        room["archived"] = False
        try:
            # 저장된 키를 **둘 다** 지운다(원본/resolve 두 모양이 다 들어 있을 수 있다).
            # 한쪽만 지우면 다음 폴에 나머지가 잡혀 방이 도로 접힌다 — 끈적함이 깨진다.
            for key in {root_text, str(Path(root_text).resolve())} & set(archive):
                _settings_file_update(ARCHIVE_FILE, key, None)
        except Exception as exc:
            # 기록 청소 실패가 **목록 전체를 죽이면 안 된다.** 바로 위 방 조립이 정확히 이
            # 이유로 감싸여 있다 — 디스크가 차거나 권한이 바뀌었다고 화면이 통째로 비면
            # 형은 아무것도 못 한다. 화면상 펴진 것은 이미 정해졌고, 다음 폴에 다시 지운다.
            _room_log_once(f"아카이브 청소 실패 {type(exc).__name__}: {exc}")
    rooms.sort(key=lambda item: float(item.get("lastAt") or 0), reverse=True)
    return {"worktrees": worktrees, "terms": terms, "sessions": sessions, "rooms": rooms,
            "pins": mobile_pins(),
            "hidden": hidden, "includeAll": bool(include_all),
            "agentOptions": mobile_agent_options(), "uploads": upload_usage(),
            "serverInstance": _SERVER_INSTANCE}


def _input_payload(text: str) -> str:
    if not text:
        raise ValueError("text 필요")
    if text.endswith("\r"):
        return text
    if text.endswith("\n"):
        return text[:-1] + "\r"
    return text + "\r"


def _term_root(tid: str) -> Path | None:
    for item in term_list().get("sessions", []):
        if str(item.get("tid") or "") == tid:
            root = str(item.get("root") or "")
            return Path(root).resolve() if root else None
    return None


def _live_agent_tid(root: Path, source: str, sid: str) -> str:
    """조작 가능한 PTY 의 tid. detached(marina 재시작으로 master fd 를 잃은) term 은 제외한다 —
    tid 를 돌려줘 봐야 term_input 이 거부하므로, 호출자가 인수인계 경로로 내려가게 둔다.

    한 세션에 term 이 **여럿** 붙어 있으면 가장 최근 것을 쓴다. 예전엔 먼저 걸리는 걸 그냥
    돌려줬는데, 그러다 이런 일이 났다: 조회가 잠깐 빈손이면 호출자가 인수인계 경로로 내려가
    같은 세션을 한 번 더 resume 하고, 그 결과 claude 프로세스가 둘이 된다. 그 뒤 조회가 **옛
    프로세스**를 집으면 형이 보낸 메시지가 이미 버려진 대화로 타이핑돼 영영 안 온다
    (형: "왜 너만 모바일로 메세지를 안먹냐" — 실측: 15:59 것과 16:06 것이 동시에 살아 있었고
    실제 대화는 16:06 쪽이었다). 새 resume 이 곧 현재 대화이므로 최신이 이긴다.
    """
    resolved = root.resolve()
    matches = [
        item for item in term_list().get("sessions", [])
        if bool(item.get("alive", True))
        and not bool(item.get("detached"))
        and str(item.get("root") or "") == str(resolved)
        and str((item.get("agent") or {}).get("source") or "") == source
        and str((item.get("agent") or {}).get("sid") or "") == sid
    ]
    if not matches:
        return ""
    matches.sort(key=lambda item: float(item.get("created") or 0.0), reverse=True)
    return str(matches[0].get("tid") or "")


def _detached_agent_pid(root: Path, source: str, sid: str) -> int:
    """detached term 이 쥐고 있는 에이전트 프로세스 pid — 인수인계 대상."""
    resolved = str(root.resolve())
    for item in term_list().get("sessions", []):
        agent = item.get("agent") if isinstance(item.get("agent"), dict) else {}
        if (
            bool(item.get("alive", True))
            and bool(item.get("detached"))
            and str(item.get("root") or "") == resolved
            and str(agent.get("source") or "") == source
            and str(agent.get("sid") or "") == sid
        ):
            try:
                return int(item.get("pid") or 0)
            except (TypeError, ValueError):
                return 0
    return 0


def _agent_holder_pid(root: Path, source: str, sid: str) -> int:
    """이 세션을 붙들고 있지만 marina 가 입력을 넣을 수 없는 프로세스의 pid (없으면 0).

    두 출처 모두 sid 단위로 정확하다 — 훅 등록부(손으로 띄운 세션)와 detached term(marina 가
    띄웠지만 재시작으로 fd 를 잃은 세션). 데스크톱 앱처럼 둘 다 없는 경우는 0 이고, 그때는
    종전대로 차단한다(정확히 누구를 끊어야 할지 모르는 채로 죽이지 않는다)."""
    try:
        import marina_agent_procs

        record = marina_agent_procs.lookup(source, sid)
        if record:
            return int(record.get("pid") or 0)
    except Exception:
        pass
    return _detached_agent_pid(root, source, sid)


OUTBOX_DIR = MARINA_HOME / "mobile-outbox"
# 보류 메시지 수명 — 이보다 오래된 건 버린다(며칠 뒤 유령 전달 방지).
OUTBOX_MAX_AGE_S = float(os.environ.get("MARINA_OUTBOX_MAX_AGE_S", str(24 * 3600)))
_OUTBOX_LOCK = threading.Lock()


def _outbox_path(source: str, sid: str) -> Path:
    return OUTBOX_DIR / f"{source}-{sid}.json"


def mobile_outbox_put(root: Path, source: str, sid: str, text: str,
                      model: str = "", effort: str = "",
                      extra: dict[str, Any] | None = None) -> dict[str, Any]:
    """세션으로 못 간 메시지를 보류함에 넣는다 — 작업 중(끼어들지 않는다)이거나,
    전달 확인 실패(입력을 삼키는 세션)일 때. 유휴·회복되는 순간 드레이너가 전달한다.

    extra: 전달 실패 경로의 상태(compactingSince·compactOffset 등). 기존 항목의 그 상태는
    새 메시지를 얹어도 유지된다 — 안 그러면 압축 대기 중 재전송이 대기 표식을 지워버린다."""
    with _OUTBOX_LOCK:
        OUTBOX_DIR.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(OUTBOX_DIR, 0o700)
        except OSError:
            pass
        path = _outbox_path(source, sid)
        try:
            previous = json.loads(path.read_text(encoding="utf-8"))
            previous = previous if isinstance(previous, dict) else {}
        except (OSError, ValueError):
            previous = {}
        messages = list(previous.get("messages") or [])
        messages.append(text)
        carried = {key: previous[key]
                   for key in ("attempts", "lastAttempt", "compactingSince", "compactOffset")
                   if key in previous}
        record = {
            "source": source, "sid": sid, "root": str(root.resolve()),
            "messages": messages, "model": model, "effort": effort, "ts": time.time(),
            **carried, **(extra or {}),
        }
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, path)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        return {"queued": len(messages)}


def mobile_outbox_pending(root: Path, source: str, sid: str) -> list[str]:
    try:
        record = json.loads(_outbox_path(source, sid).read_text(encoding="utf-8"))
        if str(record.get("root") or "") != str(root.resolve()):
            return []
        return [str(m) for m in (record.get("messages") or [])]
    except (OSError, ValueError, TypeError):
        return []


def _outbox_record(source: str, sid: str) -> dict[str, Any]:
    try:
        record = json.loads(_outbox_path(source, sid).read_text(encoding="utf-8"))
        return record if isinstance(record, dict) else {}
    except (OSError, ValueError):
        return {}


def _outbox_note_failure(source: str, sid: str) -> None:
    """전달 실패를 항목에 새긴다 — 드레이너가 백오프한다(안 받는 세션에 3초마다 타이핑 금지)."""
    with _OUTBOX_LOCK:
        path = _outbox_path(source, sid)
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        if not isinstance(record, dict):
            return
        record["attempts"] = int(record.get("attempts") or 0) + 1
        record["lastAttempt"] = time.time()
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, path)


_SETTINGS_RETRY_MAX = 5


def _recover_pending_settings(root: Path, source: str, sid: str, tid: str) -> str:
    """예약된 모델·강도를 살아있는 PTY 에 회수 시도한다.

    반환: applied(먹였고 확인됨) · busy(작업 중 — 기다린다) · failed(쳤는데 확인 안 됨,
    attempts+1) · capped(재시도 상한 도달 — 다음 resume 인자로만 남긴다) · none(예약 없음).
    실패를 세는 이유: 확인 안 되는 적용을 무한 반복하면 3초마다 남의 입력창에 슬래시를
    치는 꼴이 된다. 상한 뒤엔 접고, 예약 자체는 남아 다음 실행 인자로는 확실히 먹는다."""
    key = _session_settings_key(root, source, sid)
    record = _read_json(PENDING_SETTINGS_FILE).get(key)
    if not isinstance(record, dict):
        return "none"
    model, effort = str(record.get("model") or ""), str(record.get("effort") or "")
    if not (model or effort):
        _settings_file_update(PENDING_SETTINGS_FILE, key, None)
        return "none"
    # 예약해 둔 사이 트랜스크립트가 따라잡았을 수 있다(CLI 에서 직접 바꿨거나 이미 그 값) —
    # 수렴한 항목은 다시 치지 않는다. 전부 수렴했으면 예약은 끝난 것이다.
    wanted = _diff_against_current(root, source, sid, {"model": model, "effort": effort})
    model, effort = wanted["model"], wanted["effort"]
    if not (model or effort):
        _settings_file_update(PENDING_SETTINGS_FILE, key, None)
        return "applied"
    attempts = int(record.get("attempts") or 0)
    if attempts >= _SETTINGS_RETRY_MAX:
        return "capped"
    if not tid:
        return "none"
    if _native_agent_active(root, source, sid):
        return "busy"
    if _apply_live_agent_settings(root, source, sid, tid, model, effort):
        _settings_file_update(PENDING_SETTINGS_FILE, key, None)
        return "applied"
    _settings_file_update(PENDING_SETTINGS_FILE, key,
                          {"model": model, "effort": effort, "attempts": attempts + 1})
    return "failed"


def mobile_settings_drain() -> int:
    """작업 중이라 미뤄둔 모델·강도 예약을 세션이 유휴가 되는 순간 적용한다(보류 메시지와 같은 장치).

    이게 없으면 예약은 **다음 메시지를 보낼 때까지** 회수되지 않아 "→ 다음 X" 배지가 하염없이
    남는다(형이 본 그 화면). PTY 가 없는 예약(detached)은 그대로 둔다 — 다음 실행 인자로 먹는다."""
    applied = 0
    for key, record in list(_read_json(PENDING_SETTINGS_FILE).items()):
        parts = key.split("\n")
        if len(parts) != 3 or not isinstance(record, dict):
            continue
        root = Path(parts[0])
        if not root.is_dir():
            _settings_file_update(PENDING_SETTINGS_FILE, key, None)
            continue
        with _AGENT_SEND_LOCK:
            try:
                tid = _live_agent_tid(root, parts[1], parts[2])
                if tid and _recover_pending_settings(root, parts[1], parts[2], tid) == "applied":
                    applied += 1
            except (OSError, ValueError):
                continue                      # 한 건이 실패해도 나머지는 계속
    return applied


def mobile_outbox_drain() -> int:
    """유휴가 된 세션에 보류 메시지를 전달한다. 전달한 세션 수를 돌려준다(fail-open)."""
    delivered = 0
    try:
        entries = sorted(OUTBOX_DIR.iterdir())
    except OSError:
        return 0
    for entry in entries:
        if entry.suffix != ".json":
            continue
        try:
            record = json.loads(entry.read_text(encoding="utf-8"))
            source, sid = str(record.get("source") or ""), str(record.get("sid") or "")
            messages = [str(m) for m in (record.get("messages") or []) if str(m)]
            root = Path(str(record.get("root") or ""))
            if not source or not sid or not messages or not root.is_dir():
                entry.unlink(missing_ok=True)
                continue
            if time.time() - float(record.get("ts") or 0) > OUTBOX_MAX_AGE_S:
                entry.unlink(missing_ok=True)
                continue
            if _native_agent_active(root, source, sid):
                continue                      # 아직 작업 중 — 기다린다(끊지 않는다)
            since = float(record.get("compactingSince") or 0)
            if since and time.time() - since < _COMPACT_WAIT_MAX_S:
                # /compact 회복 대기 중 — 끝났는지 트랜스크립트로만 확인하고, 그 전엔 타이핑하지
                # 않는다(압축 중 재타이핑은 같은 메시지를 여러 벌 쌓는다).
                try:
                    transcript = agent_transcript_path(root, source, sid)
                    done = _await_transcript_markers(
                        transcript, int(record.get("compactOffset") or 0),
                        _COMPACT_DONE_MARKERS, timeout=0.0, any_of=True)
                except (OSError, ValueError):
                    done = True
                if not done:
                    continue
            attempts = int(record.get("attempts") or 0)
            if attempts and time.time() - float(record.get("lastAttempt") or 0) < min(900, 30 * attempts):
                continue                      # 백오프 — 실패가 쌓일수록 드물게 재시도
            text = "\n\n".join(messages)
            body = {"root": str(root), "target": {"type": "agent", "source": source, "sid": sid},
                    "text": text, "_from_outbox": True}
            if record.get("model"):
                body["model"] = str(record["model"])
            if record.get("effort"):
                body["effort"] = str(record["effort"])
            try:
                mobile_send(body)
            except ValueError:
                _outbox_note_failure(source, sid)   # 전달 확인 실패 — 보류 유지 + 백오프
                continue
            entry.unlink(missing_ok=True)
            delivered += 1
        except Exception:
            continue                          # 한 건이 실패해도 나머지는 계속
    return delivered


def _takeover_agent(source: str, sid: str, pid: int) -> bool:
    """붙들고 있는 프로세스를 정중히 끊고(SIGTERM) 세션을 넘겨받는다.

    SIGKILL 로 시작하지 않는 이유: CLI 가 트랜스크립트를 flush 할 틈을 줘야 resume 이 깨끗하다.
    죽지 않으면 마지막에만 SIGKILL."""
    if pid <= 1:
        return False
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return False
    deadline = time.time() + TAKEOVER_TIMEOUT_S
    while time.time() < deadline:
        time.sleep(0.05)
        try:
            os.kill(pid, 0)
        except OSError:
            break
    else:
        try:
            os.kill(pid, signal.SIGKILL)
            time.sleep(0.1)
        except OSError:
            pass
    try:
        import marina_agent_procs

        marina_agent_procs.forget(source, sid)   # 넘겨받았으니 옛 기록으로 다시 입양되면 안 된다
    except Exception:
        pass
    return True


def _native_agent_active(root: Path, source: str, sid: str) -> bool:
    """이 세션 **하나**가 지금 작업 중인가.

    예전엔 agents_payload(refresh=True) 를 불렀다 — claude·codex 전체 세션 재발견 + ps + lsof,
    실측 2.2초. 이 판정을 보내기·설정 변경이 _AGENT_SEND_LOCK 을 쥔 채 기다리고 드레이너가
    3초마다 되풀이해서, 마리나 전체가 굼떠 보였다(형: "적용 자체도 엄청 느리네").
    답에 필요한 건 그 세션의 트랜스크립트·훅·프로세스 신호뿐이다(~10ms). 판정 규칙은
    agents_payload 와 같은 캐논 하나(resolve_session_liveness)라 결과도 달라지지 않는다."""
    try:
        path = agent_transcript_path(root, source, sid)
    except ValueError:
        return False          # 트랜스크립트가 없다 = 아직 시작 전이거나 만료 — 작업 중일 수 없다
    canonical = root.resolve()
    resolved = resolve_session_liveness(
        source, sid, canonical,
        native=_native_agent_status(path, source),
        event=latest_agent_event(source, sid, canonical),
        live_cwds=_live_agent_cwds(False),
        live_tids=_live_agent_tids(False),
    )
    return str(resolved.get("status") or "") == "working"


def _agent_input_pause() -> None:
    # Codex treats Enter inside its 120ms paste window as a newline.
    time.sleep(AGENT_INPUT_SETTLE_S)


def _agent_delivery(source: str, requested: str = "") -> str:
    requested = requested.strip().lower()
    if source == "codex":
        if requested not in ("", "steer", "queue"):
            raise ValueError("Codex delivery는 steer 또는 queue여야 합니다")
        return requested or "steer"
    if source == "claude":
        if requested not in ("", "queue"):
            raise ValueError("Claude 실행 중 메시지는 queue로 전달됩니다")
        return "queue"
    raise ValueError("unknown agent source")


def _deliver_agent_input(tid: str, source: str, text: str, requested: str = "") -> str:
    if not text:
        raise ValueError("text 필요")
    delivery = _agent_delivery(source, requested)
    term_input(tid, text)
    _agent_input_pause()
    term_input(tid, "\t" if source == "codex" and delivery == "queue" else "\r")
    return delivery


_SLASH_CONFIRM_TIMEOUT_S = 3.0


def _await_transcript_markers(transcript: Path, offset: int, markers: list[str],
                              timeout: float, any_of: bool = False) -> bool:
    """offset 이후 append 된 바이트에 마커가 나타날 때까지 폴링한다 — 입력이 진짜 도착했는지의
    유일한 물증. 쳤다고 믿지 말 것: 실측에서 유휴 TUI 에 친 입력이 2시간 반 동안 전부(메시지·
    슬래시 모두) 흔적 없이 사라진 적이 있다(컨텍스트 만료 상태의 CLI 가 삼킴, 2026-08-16)."""
    deadline = time.time() + timeout
    while True:
        try:
            with transcript.open("rb") as handle:
                handle.seek(offset)
                appended = handle.read().decode("utf-8", errors="ignore")
        except OSError:
            appended = ""
        found = (any if any_of else all)(marker in appended for marker in markers)
        if found:
            return True
        if time.time() >= deadline:
            return False
        time.sleep(0.3)


def _confirm_slash_commands(transcript: Path, offset: int, arguments: list[str],
                            timeout: float | None = None) -> bool:
    """슬래시 명령이 진짜 실행됐는지 확인한다 — 실행된 명령은 즉시 `<command-args>…</command-args>`
    행을 남긴다(질문 캡처 훅의 settled 와 같은 패턴)."""
    wanted = [f"<command-args>{argument}</command-args>" for argument in arguments]
    return _await_transcript_markers(
        transcript, offset, wanted, _SLASH_CONFIRM_TIMEOUT_S if timeout is None else timeout)


def _delivery_marker(text: str) -> str:
    """메시지 전달 확인용 마커 — 원문에서 JSON 이스케이프에 안 걸리는(따옴표·역슬래시·제어문자
    없는) 조각을 고른다. 트랜스크립트는 UTF-8 원문 그대로라 이 조각은 바이트로 그대로 나타난다."""
    runs = re.findall(r'[^"\\\x00-\x1f]{6,}', text)
    return max(runs, key=len) if runs else ""


_DELIVERY_CONFIRM_TIMEOUT_S = 4.0


def _confirm_text_delivery(transcript: Path, offset: int, text: str,
                           timeout: float | None = None) -> bool:
    """유휴 세션에 친 메시지가 트랜스크립트에 user 행으로 남았는지 확인한다.

    마커를 못 뽑는 텍스트(전부 특수문자 등)는 확인 불가 — 그때만 성공으로 간주한다."""
    marker = _delivery_marker(text)
    if not marker:
        return True
    return _await_transcript_markers(
        transcript, offset, [marker], _DELIVERY_CONFIRM_TIMEOUT_S if timeout is None else timeout)


# 컨텍스트 만료로 삼킨 세션의 회복. 실측(2026-08-16): 컨텍스트가 꽉 찬 유휴 claude TUI 는
# 메시지도 슬래시 명령도 흔적 없이 버린다. 형이 실제로 뚫은 순서를 그대로 자동화한다 —
# 새 PTY 로 resume → /compact → 압축이 끝나면 전달(압축 중 타이핑은 큐에 남아 안전함이 실측됨).
_CONTEXT_COMPACT_PERCENT = 80.0
_COMPACT_CONFIRM_ROW = "<command-name>/compact</command-name>"
_COMPACT_DONE_MARKERS = ['"isCompactSummary":true', "Compacted (ctrl+o"]
_COMPACT_WAIT_MAX_S = 15 * 60


def _compact_wedged_claude(root: Path, sid: str, tid: str, transcript: Path) -> bool:
    """입력을 삼키는 유휴 claude PTY 에 /compact 를 먹인다. 반환: 압축이 시작됐는지(명령 행 확인).

    ① 그 자리에서 /compact — 명령 행이 남으면 성공. ② 안 남으면 그 TUI 는 명령도 삼키는
    상태(모달 등)다: PTY 를 접고 새 resume 에서 /compact(새 TUI 는 명령을 받는 것이 실측됨).
    유휴일 때만 불린다 — 작업 중인 턴을 죽이는 일은 없다."""

    def compact_into(target_tid: str, timeout: float) -> bool:
        offset = transcript.stat().st_size
        term_input(target_tid, "/compact")
        _agent_input_pause()
        term_input(target_tid, "\r")
        return _await_transcript_markers(transcript, offset, [_COMPACT_CONFIRM_ROW], timeout)

    try:
        if compact_into(tid, 2.0):
            return True
        term_kill(tid)                       # 명령까지 삼킨다 — 유휴이므로 접어도 잃을 턴이 없다
        reopened = term_open(root, agent_source="claude", agent_sid=sid)
        # 새 TUI 부팅 전에 타이핑해도 PTY 가 버퍼링한다 — 확인 타임아웃만 넉넉히 준다.
        return compact_into(str(reopened["tid"]), 8.0)
    except (OSError, ValueError):
        return False


def _deliver_to_live_agent(root: Path, source: str, sid: str, tid: str, text: str,
                           requested: str, from_outbox: bool) -> dict[str, Any]:
    """살아있는 PTY 로의 전달. **유휴 claude 는 도착을 트랜스크립트로 확인한다** — 실측에서
    컨텍스트 만료된 CLI 가 형 메시지를 2시간 반 동안 소리 없이 버렸고, marina 는 그동안
    "보냈다"고 보고했다(2026-08-16). 확인 실패면 보류함에 보존하고, 컨텍스트가 가득이면
    /compact 회복을 시작한다. 성공을 지어내지 않는다.

    busy claude(queue 전달)와 codex 는 종전대로 — 확인 행이 응답 종료 전엔 안 나타난다."""
    transcript: Path | None = None
    if source == "claude" and not _native_agent_active(root, source, sid):
        try:
            candidate = agent_transcript_path(root, source, sid)
            transcript = candidate if candidate.is_file() else None
        except (OSError, ValueError):
            transcript = None
    if transcript is None:
        delivery = _deliver_agent_input(tid, source, text, requested)
        return {"ok": True, "tid": tid, "opened": False, "delivery": delivery}
    offset = transcript.stat().st_size
    delivery = _deliver_agent_input(tid, source, text, requested)
    if _confirm_text_delivery(transcript, offset, text):
        # 여기까지 왔다 = 한가한 세션에 넣고 도착까지 확인했다. 그런데 claude 의 전달 방식은
        # 언제나 "queue" 라, 화면이 놀고 있던 세션에도 "작업 끝나면 전달돼요 · 대기열"을 띄웠다
        # (형: "바로바로 접수된거로 표현"). 줄을 선 것과 바로 받은 것은 다른 사실이다.
        return {"ok": True, "tid": tid, "opened": False, "delivery": "accepted"}
    if from_outbox:
        raise ValueError("전달 확인 실패 — 보류 유지")
    since = float(_outbox_record(source, sid).get("compactingSince") or 0)
    compacting = 0 < time.time() - since < _COMPACT_WAIT_MAX_S   # 이미 압축 중 — 또 손대지 않는다
    extra: dict[str, Any] = {}
    if not compacting:
        percent = agent_usage_from_path(transcript, "claude").get("contextPercent")
        if isinstance(percent, (int, float)) and percent >= _CONTEXT_COMPACT_PERCENT:
            compacting = _compact_wedged_claude(root, sid, tid, transcript)
            if compacting:
                extra = {"compactingSince": time.time(),
                         "compactOffset": transcript.stat().st_size}
    queued = mobile_outbox_put(root, source, sid, text, extra=extra)
    return {"ok": True, "tid": tid, "opened": False, "delivery": "held",
            "compacting": compacting, **queued}


def _apply_live_claude_settings(tid: str, model: str, effort: str,
                                transcript: Path | None = None) -> bool:
    """Claude Code 의 슬래시 명령에 **인자를 실어** 보낸다 — `/model <name>`·`/effort <level>`.

    codex 처럼 목록을 열고 화살표를 세어 내려갈 필요가 없다(그 방식은 목록이 하나만 바뀌어도
    엉뚱한 걸 고른다). 값 검증은 CLI 인자를 만들 때와 **같은 규칙**을 재사용한다 — 두 경로가
    서로 다른 걸 허용하면 한쪽에서만 통과하는 값이 생기다. transcript 를 주면 실행 여부를
    행으로 확인하고, 확인 못 하면 False — 성공을 지어내지 않는다."""
    if not (model or effort):
        return False
    _agent_cli("claude", "", model=model, effort=effort)   # 규칙 위반이면 여기서 ValueError
    offset = -1
    if transcript is not None:
        try:
            offset = transcript.stat().st_size
        except OSError:
            offset = -1
    for command, argument in (("/model", model), ("/effort", effort)):
        if not argument:
            continue
        term_input(tid, f"{command} {argument}")
        _agent_input_pause()
        term_input(tid, "\r")
        _agent_input_pause()
    if offset < 0:
        return True
    return _confirm_slash_commands(transcript, offset, [a for a in (model, effort) if a])


def _apply_live_agent_settings(root: Path, source: str, sid: str, tid: str,
                               model: str, effort: str) -> bool:
    """살아있는 marina 소유 PTY 에 모델·추론강도를 **지금** 먹인다.

    **작업 중이면 하지 않는다.** 응답 중에 슬래시를 치면 명령이 아니라 메시지로 큐에 들어간다.
    그땐 예약으로 남고, 다음 유휴 전송 때 회수된다(mobile_send)."""
    if not tid or not (model or effort):
        return False
    if _native_agent_active(root, source, sid):
        return False
    transcript: Path | None = None
    if source == "claude":
        try:
            transcript = agent_transcript_path(root, source, sid)
        except ValueError:
            transcript = None      # 트랜스크립트가 아직 없으면 확인 없이 친다(새 세션 직후)
    applied = (_apply_live_codex_settings(tid, model, effort) if source == "codex"
               else _apply_live_claude_settings(tid, model, effort, transcript) if source == "claude"
               else False)
    if applied:
        # current 는 트랜스크립트에서 읽는데 다음 응답 전엔 새 행이 없다 — 그 공백 동안
        # 화면이 옛 모델로 되돌아가지 않게 적용 사실을 기억해 둔다.
        _record_applied_session_settings(root, source, sid, model, effort)
    return applied


def _apply_live_codex_settings(tid: str, model: str, effort: str) -> bool:
    """Drive Codex's native /model picker in its Marina-owned PTY."""
    models = (mobile_agent_options().get("codex") or {}).get("models") or []
    model_index = next((index for index, item in enumerate(models)
                        if isinstance(item, dict) and item.get("value") == model), None)
    if model_index is None:
        return False
    model_item = models[model_index]
    efforts = [str(value) for value in (model_item.get("efforts") or [])]
    if effort and effort not in efforts:
        return False

    term_input(tid, "/model")
    _agent_input_pause()
    term_input(tid, "\r")
    _agent_input_pause()
    term_input(tid, "\x1b[A" * (len(models) + 2) + "\x1b[B" * model_index + "\r")
    _agent_input_pause()
    if effort:
        effort_index = efforts.index(effort)
        term_input(tid, "\x1b[A" * (len(efforts) + 2) + "\x1b[B" * effort_index + "\r")
    else:
        term_input(tid, "\r")
    _agent_input_pause()
    return True


MOBILE_UPLOADS_DIR = MARINA_HOME / "mobile-uploads"


def upload_usage() -> dict[str, int]:
    """폰에서 보낸 사진이 얼마나 쌓였나. 숫자 없이 "정리할까요?" 는 무서워서 못 누른다."""
    files = 0
    total = 0
    try:
        for item in MOBILE_UPLOADS_DIR.iterdir():
            if item.is_file():
                files += 1
                total += item.stat().st_size
    except OSError:
        pass
    return {"files": files, "bytes": total}


def mobile_clear_uploads(body: dict[str, Any]) -> dict[str, Any]:
    """폰에서 보낸 사진을 정리한다 — 폰에서 만들 수 있는데 지울 길이 없던 것(형 지적).

    기본은 **오래된 것만**이다. 최근 사진은 대화에 붙어 있어서 지우면 그 메시지의 그림이
    깨진다 — 전부 지우는 건 형이 명시할 때만.

    업로드 폴더 밖은 절대 안 건드린다. 경로가 새면 정리가 무기가 된다."""
    # 기본값은 **보수적으로** 30일이다. 예전엔 값이 없거나 깨지면 0(=전부 삭제)이었다 —
    # 되돌릴 수 없는 동작의 기본이 "전부"면 안 된다.
    raw = body.get("olderThanDays")
    try:
        days = 30 if raw is None else max(0, int(raw))
    except (TypeError, ValueError):
        days = 30
    cutoff = time.time() - days * 24 * 3600 if days else None
    removed = 0
    freed = 0
    try:
        base = MOBILE_UPLOADS_DIR.resolve()
    except OSError:
        return {"ok": True, "removed": 0, "freed": 0}
    for item in list(MOBILE_UPLOADS_DIR.glob("*")) if MOBILE_UPLOADS_DIR.is_dir() else []:
        try:
            if not item.is_file() or item.resolve().parent != base:
                continue        # 심링크로 밖을 가리키는 것도 여기서 걸린다
            stat = item.stat()
            if cutoff is not None and stat.st_mtime > cutoff:
                continue
            item.unlink()
            removed += 1
            freed += stat.st_size
        except OSError:
            continue
    return {"ok": True, "removed": removed, "freed": freed}
_IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic", ".svg"}
_UPLOAD_CONTENT_TYPES = {
    ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
    ".webp": "image/webp", ".bmp": "image/bmp", ".heic": "image/heic", ".svg": "image/svg+xml",
    ".pdf": "application/pdf", ".txt": "text/plain; charset=utf-8",
}
_UPLOAD_MAX_BYTES = 20 * 1024 * 1024   # 20MB


def _safe_upload_name(filename: str) -> str:
    base = os.path.basename(str(filename or "").replace("\\", "/")).strip()
    base = re.sub(r"[^A-Za-z0-9._-]", "_", base) or "file"
    return base[:120]


def mobile_upload(root: Path, filename: str, data: bytes) -> dict[str, Any]:
    # 모바일 첨부: 파일을 MARINA_HOME/mobile-uploads 에 저장하고, 에이전트가 읽을 절대경로 + 썸네일 서빙 URL 을 돌려준다.
    # PTY 는 텍스트만 전달 가능하므로 send 시 이 절대경로를 프롬프트에 실어 보낸다(에이전트가 경로로 파일을 읽음).
    if not data:
        raise ValueError("빈 파일")
    if len(data) > _UPLOAD_MAX_BYTES:
        raise ValueError("파일이 너무 큽니다(최대 20MB)")
    safe = _safe_upload_name(filename)
    ext = os.path.splitext(safe)[1].lower()
    MOBILE_UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
    try:
        MOBILE_UPLOADS_DIR.chmod(0o700)
    except OSError:
        pass
    stored = f"{secrets.token_hex(8)}-{safe}"
    dest = MOBILE_UPLOADS_DIR / stored
    dest.write_bytes(data)
    try:
        dest.chmod(0o600)
    except OSError:
        pass
    token = mobile_token()
    url = f"/mobile/api/file?name={urllib.parse.quote(stored)}"
    if token:
        url += f"&token={urllib.parse.quote(token)}"
    return {"ok": True, "name": safe, "stored": stored, "path": str(dest), "url": url,
            "isImage": ext in _IMAGE_EXTS}


def mobile_upload_file(name: str) -> tuple[bytes, str]:
    # 서빙: 저장된 첨부 파일을 스트림. 경로탈출 방어 — MOBILE_UPLOADS_DIR 밖은 거부.
    safe = _safe_upload_name(name)
    dest = (MOBILE_UPLOADS_DIR / safe).resolve()
    root = MOBILE_UPLOADS_DIR.resolve()
    if root not in dest.parents or not dest.is_file():
        raise FileNotFoundError(name)
    ext = dest.suffix.lower()
    content_type = _UPLOAD_CONTENT_TYPES.get(ext, "application/octet-stream")
    return dest.read_bytes(), content_type


def mobile_uploads_path_prefix() -> str:
    return str(MOBILE_UPLOADS_DIR.resolve())


def mobile_send(body: dict[str, Any]) -> dict[str, Any]:
    root = safe_root(str(body.get("root", "")))
    target = body.get("target") if isinstance(body.get("target"), dict) else {}
    text = str(body.get("text") or "")
    target_type = str(target.get("type") or "shell")
    opened = False
    prompt_submitted = False
    took_over = False       # 붙들고 있던 프로세스를 끊고 넘겨받았는지 — 응답에 실어 UI 가 알린다
    if target_type == "term":
        tid = str(target.get("tid") or "")
        if not tid:
            raise ValueError("tid 필요")
        term_root = _term_root(tid)
        if term_root is None:
            raise ValueError("터미널 세션이 없어요")
        if term_root != root.resolve():
            raise ValueError("선택한 터미널이 worktree와 맞지 않습니다")
    elif target_type == "agent":
        source = str(target.get("source") or "")
        sid = str(target.get("sid") or "")
        with _AGENT_SEND_LOCK:
            tid = _live_agent_tid(root, source, sid)
            if tid:
                # 예약해 둔 설정의 **회수 지점**이다. 예전엔 codex 만 여기서 적용하고 claude 는
                # 읽어놓고 아무것도 안 했다 — 그래서 살아있는 세션에선 바꾼 모델이 영영 안 먹고
                # 예약 배지만 남았다(형: "클로드는 펜딩이 아니라 그냥 안먹는거같은데").
                if (_recover_pending_settings(root, source, sid, tid) == "failed"
                        and source == "codex"):
                    raise ValueError("예약한 모델 설정을 현재 CLI에 적용할 수 없어요. 세션을 다시 열어주세요")
                return _deliver_to_live_agent(root, source, sid, tid, text,
                                              str(body.get("delivery") or ""),
                                              from_outbox=bool(body.get("_from_outbox")))
            # 여기까지 왔다 = 조작 가능한 PTY 가 없다. 이중 실행 판정은 **세션(sid) 단위**다
            # (워크트리 단위로 보면 같은 워크트리의 다른 세션까지 통째로 막힌다 — 워크트리 하나에
            # 터미널·데스크톱·모바일 세션이 공존하므로 "워크트리=세션 1:1" 은 전송 타게팅엔 안 맞는다).
            #
            # **작업 중인 세션은 절대 끊지 않는다** — 몇 시간짜리 진행을 끼어들기로 날릴 수 없다.
            # 보류함에 넣고, 유휴가 되는 순간 드레이너가 인수인계 후 전달한다(그땐 잃을 게 없다).
            if _native_agent_active(root, source, sid):
                if body.get("_from_outbox"):
                    # 드레이너가 유휴를 보고 들어왔는데 그새 작업이 다시 시작됐다 — 보류를 유지한다.
                    raise ValueError("세션이 다시 작업 중입니다 — 보류 유지")
                queued = mobile_outbox_put(root, source, sid, text,
                                           str(body.get("model") or ""), str(body.get("effort") or ""))
                return {"ok": True, "tid": "", "opened": False, "delivery": "queue", **queued}
            # 여기부터는 유휴 세션이다. 붙들고 있는 프로세스를 지목할 수 있으면 끊고 넘겨받는다.
            # 지목 못 해도(데스크톱 앱처럼 pid 를 모르는 경우) resume 으로 이어받는다 — 유휴 상태라
            # 진행 중인 작업이 없고, "다른 앱에서 하던 걸 모바일로 잇는다"가 이 기능의 목적이다.
            holder = _agent_holder_pid(root, source, sid)
            if holder:
                took_over = _takeover_agent(source, sid, holder)
            saved = mobile_pending_session_settings(root, source, sid)
            model = str(body.get("model") if "model" in body else saved["model"])
            effort = str(body.get("effort") if "effort" in body else saved["effort"])
            options = {
                "agent_source": source,
                "agent_sid": sid,
                "agent_prompt": text,
            }
            if model:
                options["agent_model"] = model
            if effort:
                options["agent_effort"] = effort
            result = term_open(root, int(body.get("cols") or 80), int(body.get("rows") or 24), **options)
            tid = str(result["tid"])
            opened = not bool(result.get("reused"))
            # 새로 띄웠으면 프롬프트가 CLI 인자로 이미 실려 갔다. **재사용**이면 그 PTY 는 이미 돌고
            # 있어서 인자를 다시 줄 수 없다 — 아래에서 타이핑으로 넣어야 한다. 예전엔 무조건
            # 넣은 걸로 쳐서, 재사용 분기에 걸리면 형 메시지가 조용히 사라졌다.
            prompt_submitted = opened
            _clear_pending_session_settings(root, source, sid)
    else:
        result = term_open(root, int(body.get("cols") or 80), int(body.get("rows") or 24))
        tid = str(result["tid"])
        opened = True
    if not prompt_submitted:
        term_input(tid, _input_payload(text))
    result = {"ok": True, "tid": tid, "opened": opened}
    if took_over:
        result["takeover"] = True
    return result


def mobile_launch(body: dict[str, Any]) -> dict[str, Any]:
    """이 워크트리에서 에이전트 **새 세션**을 띄운다(resume 아님).

    sid 는 시작 시점에 알 수 없다 — 훅이 남기는 {sid, pid} 를 marina 가 입양(adopt_agent_terms)할 때
    이 PTY 에 붙는다. 그전까지는 터미널 세션으로 보이고, 첫 프롬프트를 보내면 에이전트로 승격된다."""
    root = safe_root(str(body.get("root", "")))
    source = str(body.get("source") or "")
    if source not in ("claude", "codex"):
        raise ValueError("source 는 claude 또는 codex")
    # **첫 메시지를 같이 넘긴다.** 안 넘기면 빈 세션만 뜨고 아무 일도 안 한다 — 새 일감이
    # "무슨 일을 할까요?"를 물어놓고 그 말을 버리는 셈이었다(term_open 은 원래 받는다).
    result = term_open(root, int(body.get("cols") or 80), int(body.get("rows") or 24),
                       agent_source=source, agent_sid="",
                       agent_prompt=str(body.get("prompt") or ""),
                       agent_model=str(body.get("model") or ""),
                       agent_effort=str(body.get("effort") or ""))
    return {"ok": True, "tid": str(result.get("tid") or ""), "source": source}


# PostToolUse 훅이 상태파일을 지울 때까지 기다리는 상한. **질문 수에 비례해야 한다** —
# 질문이 여러 개면 셀렉터를 순서대로 확정하느라 그만큼 오래 걸린다. 고정 3.5초로 두었더니
# 질문 3개짜리 폼이 첫 시도에서 settled=False 로 떨어졌다(실측 2026-08-17 13:52:58, 형이 본
# 그 오류). 두 번째 시도는 같은 답으로 성공했다 — 실패가 아니라 **성급한 판정**이었다.
_ANSWER_CONFIRM_BASE_S = 3.5
_ANSWER_CONFIRM_PER_QUESTION_S = 2.0
_ANSWER_CONFIRM_POLL_S = 0.15
# 질문 사이는 **자지 않고** 화면이 다시 그려지길 기다린다(term_await_redraw).
_ANSWER_REDRAW_TIMEOUT_S = 3.0     # 다음 질문이 그려지길 기다리는 상한


def _answer_confirm_timeout(questions: int) -> float:
    return _ANSWER_CONFIRM_BASE_S + _ANSWER_CONFIRM_PER_QUESTION_S * max(0, int(questions) - 1)
_ANSWER_LOG = MARINA_HOME / "answer-debug.log"


def _answer_log(message: str) -> None:
    """질문 응답 경로 계측(임시). 다중선택 전달 실패의 원인을 좁히면 걷어낸다.

    데몬 로그(dashboard.log)는 접근 로그로 넘쳐서 묻힌다 — 전용 파일로 남긴다."""
    try:
        with _ANSWER_LOG.open("a", encoding="utf-8") as handle:
            handle.write(f"{time.strftime('%H:%M:%S')} {message}\n")
    except OSError:
        pass


def _await_answer_settled(sid: str, before: str, questions: int = 1) -> bool:
    """답이 실제로 셀렉터에 먹혔는지 확인. before 는 주입 직전의 상태파일 토큰.

    토큰이 사라지거나 바뀌면 그 AskUserQuestion 은 끝난 것(= 먹혔다). 상한까지 그대로면 안 먹힌
    것으로 보고한다 — 호출자(모바일)가 카드를 되살려 형이 다시 누를 수 있게."""
    if not before:
        return True     # 애초에 pending 질문이 없었다 — 확인할 근거가 없으니 판정하지 않는다
    deadline = time.monotonic() + _answer_confirm_timeout(questions)
    while time.monotonic() < deadline:
        time.sleep(_ANSWER_CONFIRM_POLL_S)
        if _question_state_token(sid) != before:
            return True
    return False


def _parse_answers(body: dict[str, Any]) -> list[list[int]]:
    """질문별 선택지. 질문 하나당 **여러 개**일 수 있다(multiSelect).

    받는 형태 셋 — 새 것부터: answers=[[0,2],[1]] · optionIndexes=[0,1] · optionIndex=0.
    """
    raw = body.get("answers")
    if raw is None:
        legacy = body.get("optionIndexes")
        if legacy is None:
            legacy = [body.get("optionIndex", 0)]
        raw = [[value] for value in legacy] if isinstance(legacy, list) else None
    if not isinstance(raw, list) or not raw:
        raise ValueError("optionIndex 필요")
    if len(raw) > 20:
        raise ValueError("질문이 너무 많아요")
    answers: list[list[int]] = []
    for entry in raw:
        values = entry if isinstance(entry, list) else [entry]
        if not values:
            raise ValueError("질문마다 최소 하나는 골라야 해요")
        if len(values) > 50:
            raise ValueError("선택이 너무 많아요")
        picked: list[int] = []
        for value in values:
            try:
                index = int(value)
            except (TypeError, ValueError):
                raise ValueError("optionIndex 필요")
            if index < 0 or index > 50:
                raise ValueError("optionIndex 범위")
            if index not in picked:
                picked.append(index)
        answers.append(sorted(picked))
    return answers


def _drive_selector(tid: str, picks: list[int], multi_select: bool) -> None:
    """셀렉터 한 개를 구동한다. 커서는 첫 옵션에서 시작한다고 가정.

    단일선택: 아래로 N칸 → Enter.

    다중선택: 각 항목으로 이동해 **Enter 로 토글** → 마지막에 **→(오른쪽)** 로 Submit 창으로 옮겨
    Enter 로 제출. 실제 셀렉터를 PTY 로 띄워 확인한 계약이다:

        ←  ☐ 선택   ✔ Submit  →
        ❯ 1. [ ] 가A
          2. [ ] 나B
        Enter to select · ↑/↓ to navigate · Esc to cancel

    예전엔 스페이스로 토글하고 Enter 로 확정한다고 봤는데 둘 다 틀렸다. 스페이스는 아예 무시되고
    Enter 는 '확정'이 아니라 '토글'이라, 마리나가 보낸 Space+Enter 는 **1번 항목만 체크해놓고
    제출은 하지 않았다** — 형이 본 "첫 항목만 선택된 채 안 감"이 정확히 이 상태다(로그에도
    settled=False 로 남았다). 제출은 목록 안이 아니라 **오른쪽 Submit 창**에 있다.
    """
    if not multi_select:
        target = picks[0] if picks else 0
        if target:
            term_input(tid, "\x1b[B" * target)
            _agent_input_pause()
        term_input(tid, "\r")
        return
    cursor = 0
    for target in picks:
        if target > cursor:
            term_input(tid, "\x1b[B" * (target - cursor))
            _agent_input_pause()
            cursor = target
        term_input(tid, "\r")         # 토글 — 스페이스가 아니다
        _agent_input_pause()
    term_input(tid, "\x1b[C")         # → Submit 창으로
    _agent_input_pause()
    term_input(tid, "\r")             # 제출


def _answer_as_text(questions: list[Any], answers: list[list[int]]) -> str:
    """고른 선택지를 **글**로 옮긴다 — 셀렉터가 죽은 세션에 이어받아 전달할 때 쓴다.

    인덱스가 아니라 라벨을 보낸다. 이어받은 세션엔 원래 tool call 이 없으므로 숫자는 의미가 없다."""
    lines: list[str] = []
    for position, picks in enumerate(answers):
        question = questions[position] if position < len(questions) else {}
        question = question if isinstance(question, dict) else {}
        options = question.get("options") if isinstance(question.get("options"), list) else []
        labels: list[str] = []
        for index in picks:
            option = options[index] if index < len(options) else None
            if isinstance(option, dict):
                labels.append(str(option.get("label") or option.get("value") or f"옵션 {index + 1}"))
            else:
                labels.append(f"옵션 {index + 1}")
        title = str(question.get("header") or question.get("question") or f"질문 {position + 1}").strip()
        lines.append(f"{title}: {', '.join(labels)}" if labels else title)
    return "[모바일에서 선택]\n" + "\n".join(lines)


def _clear_pending_question(sid: str) -> None:
    """이어받아 답을 글로 전달했으면 그 질문은 끝난 것이다 — PostToolUse 가 올 수 없으니 직접 지운다."""
    try:
        (AGENT_QUESTIONS_DIR / f"claude-{sid}.json").unlink()
    except (OSError, FileNotFoundError):
        pass


def mobile_answer(body: dict[str, Any]) -> dict[str, Any]:
    # ① 질문 선택지 응답: AskUserQuestion 셀렉터(Claude Code 인터랙티브 목록)를 PTY 화살표+Enter 로 구동.
    # _apply_live_codex_settings 와 동일한 방식 — 커서가 첫 옵션에서 시작한다고 가정하고 아래로 N칸 이동 후 확정.
    #
    # 질문이 여러 개면 셀렉터도 여러 번 뜬다. 예전엔 첫 질문 하나만 확정하고 200 을 돌려줘서, 폼은
    # 2번째 질문에서 계속 대기 중인데 모바일은 "보냈다"고 카드를 지웠다 — 형이 겪은 "선택하는데 안
    # 가는데"의 재현 경로. 이제 전 질문을 순서대로 확정하고, 상태파일이 사라지는지로 결과를 확인한다.
    root = safe_root(str(body.get("root", "")))
    target = body.get("target") if isinstance(body.get("target"), dict) else {}
    if str(target.get("type") or "") != "agent":
        raise ValueError("에이전트 세션만 응답할 수 있어요")
    source = str(target.get("source") or "")
    sid = str(target.get("sid") or "")
    if source != "claude":
        raise ValueError("이 질문 응답은 Claude 세션만 지원해요")
    answer_text = str(body.get("text") or "")
    tid = _live_agent_tid(root, source, sid)
    if not tid:
        # 셀렉터를 쥔 PTY 가 없다 = 그 프로세스는 죽었거나 marina 밖에서 돈다. 예전엔 여기서 막았는데,
        # 전송은 이미 인수인계(--resume)로 뚫으면서 응답만 막는 건 일관성이 없다(형 지적).
        # 원래 tool call 은 프로세스와 함께 죽었으니 **고른 내용을 글로** 실어 세션을 이어받는다.
        # 작업 중이면 mobile_send 가 알아서 보류함에 넣고 유휴가 될 때 전달한다.
        pending = mobile_pending_question(source, sid) or {}
        questions = pending.get("questions") or []
        text = answer_text or _answer_as_text(questions, _parse_answers(body))
        _answer_log("no-tid: 세션을 이어받아 글로 전달 text=%r" % text[:120])
        result = mobile_send({"root": str(root), "target": {"type": "agent", "source": source, "sid": sid},
                              "text": text})
        _clear_pending_question(sid)
        return {**result, "viaResume": True, "settled": True,
                "delivery": result.get("delivery") or "resume"}
    before = _question_state_token(sid)
    if answer_text:
        # 기타(직접 입력): 셀렉터에 텍스트를 타이핑 후 확정 — best-effort(실 셀렉터 동작 검증 필요).
        term_input(tid, answer_text[:2000])
        _agent_input_pause()
        term_input(tid, "\r")
        settled = _await_answer_settled(sid, before)
        return {"ok": True, "tid": tid, "text": True, "settled": settled}
    answers = _parse_answers(body)
    # multiSelect 는 **훅이 잡아둔 질문 원본**에서 읽는다 — 클라이언트 주장을 믿지 않는다.
    pending = mobile_pending_question(source, sid) or {}
    questions = pending.get("questions") or []
    # 계측: 다중선택이 "답이 아예 안 감" 으로 실패하는데 키·간격·정렬·훅데이터가 전부 정상으로 확인됐다.
    # 남은 미지는 구동 직전/직후의 실제 상태뿐이라, 어느 분기를 어떤 입력으로 탔는지 남긴다.
    mark = term_output_mark(tid)      # -1 이면 관찰 불가 — 기다림 없이 진행한다(fail-open)
    _answer_log("drive: tid=%s answers=%r multi=%r before=%r" % (
        tid, answers, [bool(q.get("multiSelect")) if isinstance(q, dict) else None for q in questions], before))
    for position, picks in enumerate(answers):
        if position:
            # **시계가 아니라 화면을 본다.** 답을 하나 확정하면 CLI 가 다음 질문을 새로 그린다 —
            # 그 출력이 오고 잠잠해지는 것이 "그렸다"는 증거다. 고정 시간으로 자면 느린 순간엔
            # 그리기 전에 키가 들어가 어긋나고(형이 본 그 오류), 빠른 순간엔 쓸데없이 기다린다.
            # 못 기다려도 진행은 한다 — 여기서 멈추면 남은 질문에 아예 답을 못 한다.
            term_await_redraw(tid, mark, timeout=_ANSWER_REDRAW_TIMEOUT_S)
        mark = term_output_mark(tid)
        question = questions[position] if position < len(questions) else {}
        multi_select = bool(isinstance(question, dict) and question.get("multiSelect"))
        _drive_selector(tid, picks, multi_select)
    # **여러 질문 폼은 마지막에 제출 화면이 따로 뜬다.** 실측으로 확인한 화면(2026-08-17):
    #
    #     ← ☒방향  ☒범위  ✔ Submit →
    #     Review your answers
    #     ● 어떤 방향으로 진행할까요? → 옵션 A
    #     ● 작업 범위는 어떻게 잡을까요? → 최소 범위
    #     Ready to submit your answers?
    #     ❯ 1. Submit answers
    #
    # 질문은 위쪽 **탭**이고 맨 끝에 Submit 탭이 있다. 질문마다 답만 넣고 끝내면 폼이 제출되지
    # 않아 영영 안 먹는다 — 그게 "질문 2~3개짜리만 실패"의 정체였다(단일 질문은 Enter 하나로
    # 선택과 제출이 같이 되므로 이 단계가 없어 8/8 성공했다).
    #
    # 마지막 질문을 확정하면 포커스가 "Submit answers" 에 가 있으므로 Enter 한 번이면 된다
    # (재시도가 1초 만에 성공하던 것도 이것 때문이다 — 그 Enter 가 Submit 을 눌렀다).
    if len(answers) > 1:
        term_await_redraw(tid, mark, timeout=_ANSWER_REDRAW_TIMEOUT_S)
        mark = term_output_mark(tid)
        term_input(tid, "\r")

    settled = _await_answer_settled(sid, before, len(answers) or 1)
    _answer_log("drive done: settled=%r after=%r" % (settled, _question_state_token(sid)))
    if not settled:
        # **화면을 남긴다.** 질문 여러 개짜리 폼이 계속 실패하는데(단일 질문은 8/8 성공) 셀렉터가
        # 어떻게 생겼는지 본 적이 없어 고치려면 추측이 된다. 실패했을 때만 남긴다 — 성공 경로에
        # 큰 로그를 쌓을 이유가 없다.
        _answer_log("실패 시점 화면 ↓↓↓\n%s\n↑↑↑ 화면 끝" % term_tail(tid))
    return {"ok": True, "tid": tid, "answers": answers,
            "optionIndex": answers[0][0], "settled": settled}


def mobile_interrupt(body: dict[str, Any]) -> dict[str, Any]:
    root = safe_root(str(body.get("root", "")))
    target = body.get("target") if isinstance(body.get("target"), dict) else {}
    if str(target.get("type") or "") != "agent":
        raise ValueError("에이전트 세션만 중단할 수 있어요")
    tid = _live_agent_tid(root, str(target.get("source") or ""), str(target.get("sid") or ""))
    if not tid:
        raise ValueError("실행 중인 에이전트가 없어요")
    term_input(tid, "\x03")
    return {"ok": True, "tid": tid, "interrupted": True}


def render_mobile_html(auth_enabled: bool = False) -> str:
    return _MOBILE_HTML.replace("__MARINA_AUTH_ENABLED__", "true" if auth_enabled else "false")


_MOBILE_HTML = r"""<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8" />
  <!-- viewport-fit=cover 가 없으면 env(safe-area-inset-*) 이 전부 0 이다. 브라우저 탭에선 티가
       안 나지만 홈 화면 앱으로 열면 노치와 홈바 밑으로 내용이 깔린다 — 이미 CSS 는 그 값을
       쓰고 있었으므로 여기 한 줄이 빠져 있던 것이 곧 버그였다. -->
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
  <title>Marina Mobile</title>
  <!-- 아이콘을 선언하지 않으면 브라우저가 /favicon.ico 를 찾는데 마리나는 그 경로를 주지 않는다
       → 탭 아이콘이 빈 채로 남는다(웹·로그인 화면엔 있었는데 모바일만 빠져 있었다).
       /web/ 은 PUBLIC_PREFIXES 라 로그인 전에도 받아진다. -->
  <link rel="icon" type="image/png" href="/web/favicon.png" media="(prefers-color-scheme: light)" />
  <link rel="icon" type="image/png" href="/web/favicon-dark.png" media="(prefers-color-scheme: dark)" />
  <!-- 홈 화면에 추가해야 아이폰에서 알림을 받을 수 있다(사파리 탭에서는 원천적으로 불가).
       매니페스트·아이콘이 없으면 '추가'해도 웹 클립일 뿐이라 푸시 권한이 안 생긴다. -->
  <link rel="manifest" href="/mobile/manifest.webmanifest" />
  <meta name="apple-mobile-web-app-capable" content="yes" />
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent" />
  <meta name="apple-mobile-web-app-title" content="marina" />
  <link rel="apple-touch-icon" href="/mobile/icon.png" />
  <!-- media 를 못 읽는 브라우저용 폴백은 **진한 쪽**이어야 한다(흰 아이콘은 밝은 탭에서 묻힌다).
       apple-touch-icon 은 위의 512px 하나만 둔다 — 여기서 또 선언하면 그게 이겨서 홈 화면
       아이콘이 64px 파비콘으로 떨어진다. -->
  <link rel="icon" type="image/png" href="/web/favicon.png" />
  <style>
    /* **hidden 속성은 언제나 이긴다.** display 를 지정한 클래스(.session-list{display:flex} 등)가
       UA 의 [hidden]{display:none} 을 눌러버려서, 숨겼다고 믿은 것들이 계속 보였다 —
       방 목록 아래에 예전 세션 목록이 통째로 붙어 있었는데 아무도 몰랐다(속성만 확인했다).
       파일 곳곳에 클래스별 가드가 하나씩 붙어 있던 것도 같은 함정을 하나씩 만났다는 뜻이다. */
    [hidden] { display: none !important; }
    :root { color-scheme: light dark; font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; overflow: hidden; background: #f4f6f9; color: #17191f; }
    #mobileApp { --app-height: 100dvh; height: var(--app-height); min-height: 0; display: none; grid-template-rows: auto minmax(0, 1fr) auto; overflow: hidden; }
    #mobileLogin { min-height: 100vh; display: none; align-items: stretch; justify-content: center; flex-direction: column; padding: 24px; box-sizing: border-box; gap: 14px; }
    #mobileLogin form { display: flex; flex-direction: column; gap: 10px; }
    /* 홈 화면 앱으로 열면 주소창이 없어 화면이 상태바 밑까지 온다 — 노치를 피해 앉힌다.
       브라우저 탭에서는 inset 이 0 이라 지금과 똑같이 보인다. */
    header { position: relative; z-index: 4; display: grid; gap: 4px; padding: max(4px, env(safe-area-inset-top)) 8px 6px; box-sizing: border-box; background: #fff; border-bottom: 1px solid #dde2ea; }
    /* grid 였을 때: 자식(backBtn·chatNavTitle)이 뷰에 따라 display:none 이 되면 그리드 흐름에서 빠져
       **칼럼 배정이 밀린다** — 목록 뷰에서 프로젝트 스트립이 36px 칸에 들어가고 액션이 1fr 을 차지했다
       (실측 390px 기준 strip 36px / acts 나머지 전부. "서버 버튼이 스크롤 폭을 먹는" 증상의 진짜 원인).
       flex 는 남은 자식만으로 나누므로 숨김 여부에 흔들리지 않는다. */
    /* min-width:0 은 필수다. .shellRow 는 header(grid)의 아이템이라 기본값 min-width:auto 면
       자동 최소 크기 = min-content 가 되고, 제목이 긴 URL(안 쪼개지는 문자열)이면 그 폭이
       그대로 하한이 된다 → 헤더 열이 뷰포트보다 넓어지고 #mobileApp 열까지 끌려가
       main·작성기까지 늘어나 페이지 전체가 가로로 오버플로한다(형: "제목 섹션 때문에 전체 늘어져").
       자식(chatNavTitle)의 ellipsis 는 이게 없으면 무력하다 — 줄어들 기회 자체가 없어서. */
    .shellRow { display: flex; gap: 5px; align-items: center; min-height: 38px; min-width: 0; }
    .shellRow > .backBtn { flex: 0 0 auto; }
    .shellRow > .project-strip, .shellRow > .chatNavTitle { flex: 1 1 auto; min-width: 0; }
    h2 { margin: 0; font-size: 22px; }
    p { margin: 0; color: #596070; line-height: 1.45; }
    main { display: flex; min-height: 0; flex-direction: column; gap: 10px; overflow: hidden; padding: 10px 12px; }
    label { display: flex; flex-direction: column; gap: 6px; font-size: 12px; font-weight: 700; color: #596070; }
    select, textarea, input, button { width: 100%; box-sizing: border-box; border: 1px solid #ccd3dd; border-radius: 8px; background: #fff; color: #17191f; font: inherit; }
    input { min-height: 42px; padding: 0 11px; }
    select, button { min-height: 42px; padding: 0 11px; }
    textarea { min-height: 92px; padding: 11px; resize: vertical; line-height: 1.45; }
    button { font-weight: 800; color: #0b63ce; }
    button.primary { background: #0b63ce; border-color: #0b63ce; color: white; }
    button:focus-visible, input:focus-visible, textarea:focus-visible { outline: 2px solid #0b63ce; outline-offset: 2px; }
    .iconBtn { width: 36px; height: 36px; min-height: 36px; padding: 0; border-color: transparent; background: transparent; color: #303846; font-size: 19px; line-height: 1; }
    .backBtn { grid-column: 1; }
    #listView { display: flex; min-height: 0; flex-direction: column; gap: 10px; overflow-y: auto; overscroll-behavior: contain; }
    #chatView { position: relative; display: none; min-height: 0; grid-template-rows: auto minmax(0, 1fr); gap: 5px; overflow: hidden; }
    .hiddenSelect { display: none !important; }
    .project-strip { display: flex; min-width: 0; gap: 5px; padding: 1px 0; overflow-x: auto; scrollbar-width: none; }
    .project-strip::-webkit-scrollbar { display: none; }
    .project-chip { flex: 0 0 auto; width: auto; max-width: 150px; min-height: 32px; padding: 0 10px; border-radius: 8px; color: #596070; font-size: 11px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .project-chip.active { background: #17191f; border-color: #17191f; color: #fff; }
    .project-count { margin-left: 5px; opacity: .7; font-variant-numeric: tabular-nums; }
    .source-tabs { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 3px; padding: 3px; background: #e8ecf2; border-radius: 8px; }
    .source-tab { min-width: 0; min-height: 30px; padding: 0 4px; border: 0; background: transparent; color: #596070; font-size: 10px; }
    .source-tab.active { background: #fff; color: #17191f; box-shadow: 0 1px 3px rgb(23 25 31 / 10%); }
    /* 상한 92px — 세 자릿수(999/999)까지 tabular-nums 로 들어가고, 그 이상은 말줄임으로 흡수해
       스트립을 더 잠식하지 않는다. */
    .shellActions { display: flex; flex: none; min-width: 0; align-items: center; gap: 3px; }
    .chatNavTitle { display: none; min-width: 0; overflow: hidden; font-size: 13px; font-weight: 900; text-overflow: ellipsis; white-space: nowrap; }
    .usageBtn { display: none; width: 32px; min-width: 32px; height: 32px; min-height: 32px; padding: 0; border-color: transparent; background: transparent; color: #4d5665; font-size: 18px; }
    #mobileApp[data-view="chat"] header { gap: 0; padding-bottom: 4px; }
    #mobileApp[data-view="chat"] .shellRow { grid-template-columns: 32px minmax(0, 1fr) 32px; min-height: 34px; }
    /* projectTabs·sourceTabs 는 #listView(=드로어) 안에 있다 — 채팅 중에도 닿아야 한다.
       서비스는 워크트리 소속이라 그룹 헤더의 "서버" 칩에서 연다. */
    /* 목록 뷰에선 헤더 가운데가 비므로 액션을 오른쪽에 붙인다(탭이 헤더에서 빠졌다). */
    #mobileApp[data-view="list"] .shellActions { margin-left: auto; }
    /* 드로어는 좁다 — 프로젝트 칩은 가로 스크롤(기본), 종류 탭은 줄바꿈 없이 4칸 유지. */
    #mobileApp[data-view="chat"] #listView .project-strip { flex: none; }
    #mobileApp[data-view="chat"] .chatNavTitle { display: block; }
    #mobileApp[data-view="chat"] .usageBtn.available { display: inline-flex; align-items: center; justify-content: center; }
    #mobileApp[data-view="chat"] main { padding: 6px 10px; }
    .search-input { min-height: 40px; }
    /* 좌측 패널 — 목록 뷰에선 전체 화면 그대로, 채팅 뷰에선 오프캔버스 드로어(같은 #listView 재사용). */
    #mobileApp[data-view="chat"] #listView {
      position: fixed; z-index: 9; top: 0; bottom: 0; left: 0;
      width: min(86vw, 340px);
      margin: 0; padding: max(10px, env(safe-area-inset-top)) 10px calc(10px + env(safe-area-inset-bottom));
      background: #fff; border-right: 1px solid #d5dbe4; box-shadow: 2px 0 18px rgb(10 14 20 / 20%);
      transform: translateX(-100%); transition: transform .22s ease;
      pointer-events: none;
    }
    #mobileApp[data-view="chat"][data-drawer="open"] #listView { transform: translateX(0); pointer-events: auto; }
    .drawerBackdrop { position: fixed; inset: 0; z-index: 8; display: none; background: rgb(10 14 20 / 38%); }
    #mobileApp[data-view="chat"][data-drawer="open"] .drawerBackdrop { display: block; }
    @media (prefers-reduced-motion: reduce) { #mobileApp[data-view="chat"] #listView { transition: none; } }
    .listTools { display: flex; flex: none; gap: 5px; align-items: center; }
    .listTools .search-input { flex: 1; min-width: 0; }
    .session-card.hidden-session { opacity: .45; }
    .session-list:not(.show-all) .session-card.hidden-session { display: none; }
    .listToolBtn.on { color: #0b63ce; background: #e3efff; }
    .listToolBtn { width: auto; flex: none; min-width: 40px; min-height: 40px; padding: 0 9px; font-size: 11px; font-weight: 900; white-space: nowrap; }
    .newWtBtn { color: #0b63ce; }
    /* 밀도 — 간단(기본)에선 부제/미리보기를 CSS 로만 가린다. 토글이 재렌더를 안 부르니 스크롤이 안 튄다. */
    .session-list .session-subtitle, .session-list .session-preview { display: none; }
    .session-list.density-detail .session-subtitle, .session-list.density-detail .session-preview { display: block; }
    /* 간단 모드의 타입 스케일 — 한 줄 카드인데 본문 폰트를 그대로 쓰면 뭐가 뭔지 안 보인다(형 지적). */
    .wt-group-body { display: flex; flex-direction: column; gap: 4px; margin-top: 5px; }
    .session-list { gap: 9px; }
    .session-list .session-card { min-height: 0; padding: 7px 9px; }
    .session-list .session-card-top { gap: 6px; }
    .session-list .session-title { font-size: 12px; font-weight: 800; }
    .session-list .session-status-label { display: none; }
    .session-list .session-status.notable .session-status-label { display: inline; color: #4d5665; font-size: 10px; font-weight: 800; }
    .session-list .source-badge { min-height: 16px; padding: 0 4px; font-size: 8px; }
    .session-list .session-group-title { font-size: 10px; }
    .session-list.density-detail .session-card { min-height: 88px; padding: 10px 11px; }
    .session-list.density-detail .session-title { font-size: 13px; }
    .session-list.density-detail .session-status-label { display: inline; }
    .session-list.density-detail .source-badge { min-height: 20px; padding: 0 6px; font-size: 9px; }
    .session-when { flex: none; margin-left: auto; color: #747d8b; font-size: 10px; font-weight: 800; white-space: nowrap; }
    .session-when.asking { padding: 1px 6px; border-radius: 999px; background: #fff0e0; color: #a8571a; font-weight: 900; }
    .wt-pin:empty { display: none; }
    .wt-pin { flex: none; font-size: 11px; }
    .wt-label { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .wt-group-flags { display: inline-flex; gap: 3px; }
    .wt-flag { padding: 0 5px; border-radius: 999px; font-size: 9px; font-weight: 900; }
    .wt-flag.asking { background: #e3efff; color: #0b63ce; }
    .wt-flag.busy { background: #e6efe8; color: #2f6b45; }
    .session-group.pinned > .wt-group-head { background: rgba(11, 99, 206, .06); border-radius: 7px; }
    .session-list { display: flex; flex-direction: column; gap: 12px; }

    /* 방 목록 — 첫 화면. 카드는 손가락으로 누르는 것이라 세로로 넉넉히 잡는다. */
    .room-list { display: flex; flex-direction: column; }
    .roomCard { display: flex; gap: 10px; align-items: center; width: 100%; text-align: left;
                padding: 14px 12px; border: 0; border-bottom: 1px solid var(--line);
                background: transparent; color: inherit; font: inherit; cursor: pointer; }
    .roomCard:active { background: var(--panel); }
    .roomIcon { width: 22px; flex: 0 0 22px; text-align: center; font-weight: 700; }
    .roomBody { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
    /* 이름은 한 줄 — 넘치면 말줄임. 서버가 이미 줄이지만 화면 폭은 기기마다 다르다. */
    .roomName { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .roomMeta { font-size: 12px; opacity: .7; }
    /* 상태는 글자로도 말하지만, 색이 있어야 목록을 훑을 때 급한 것이 먼저 눈에 걸린다. */
    .roomRow { display: flex; align-items: stretch; border-bottom: 1px solid var(--line); }
    .roomRow .roomCard { border-bottom: 0; flex: 1 1 auto; min-width: 0; }
    .roomMore { flex: 0 0 44px; border: 0; background: transparent; color: inherit;
                font-size: 18px; opacity: .6; cursor: pointer; }
    .roomRow.st-문제 .roomIcon { color: #e5534b; }
    .roomRow.st-응답필요 .roomIcon { color: #d29922; }
    .roomRow.st-작업중 .roomIcon { color: #2f81f7; }
    .roomRow.st-완료 .roomIcon { color: #3fb950; }
    /* 방 안 — 목록 위에 얹는다. 화면을 갈아끼우지 않으므로 닫으면 보던 자리로 돌아온다. */
    .room-open { border: 1px solid var(--line); border-radius: 10px; margin: 8px 0 12px;
                 background: var(--panel); }
    .roomHead { display: flex; align-items: center; gap: 6px; padding: 10px 8px 10px 12px; }
    .roomOpenTitle { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis;
                     white-space: nowrap; font-weight: 600; }
    .roomTabs { display: flex; flex-direction: column; padding: 0 8px 8px; gap: 6px; }
    .roomTab { text-align: left; padding: 10px 12px; border: 1px solid var(--line);
               border-radius: 8px; background: transparent; color: inherit; font: inherit;
               overflow: hidden; text-overflow: ellipsis; white-space: nowrap; cursor: pointer; }
    .roomTab.current { border-color: #2f81f7; }
    .roomTabRow { display: flex; gap: 6px; align-items: stretch; }
    .roomTabRow .roomTab { flex: 1 1 auto; min-width: 0; }
    .roomTab.off, .roomTab.stale { opacity: .55; }
    .iconBtn.danger { color: #e5534b; }
    .roomTabUnhide { flex: 0 0 auto; padding: 0 10px; border: 1px solid var(--line);
                     border-radius: 8px; background: transparent; color: inherit;
                     font: inherit; font-size: 12px; cursor: pointer; }
    .roomTabNote { flex: 0 0 auto; align-self: center; font-size: 11px; opacity: .6; }
    .doneCard { margin: 8px 12px; padding: 12px; border: 1px solid #3fb950; border-radius: 10px;
                display: flex; flex-direction: column; gap: 6px; }
    .doneTitle { font-weight: 600; }
    .doneNames { font-size: 12px; opacity: .75; overflow-wrap: anywhere; }
    .doneOpen { align-self: flex-start; padding: 8px 14px; border: 1px solid var(--line);
                border-radius: 8px; background: transparent; color: inherit; font: inherit; cursor: pointer; }
    .roomBlocked { margin: 0 8px 8px; padding: 10px 12px; border: 1px solid #d29922;
                   border-radius: 8px; display: flex; flex-direction: column; gap: 8px; }
    .reloginLink { color: #2f81f7; word-break: break-all; }
    .reloginHint { font-size: 12px; opacity: .75; }
    .reloginRow { display: flex; gap: 6px; }
    .reloginCode { flex: 1 1 auto; min-width: 0; padding: 8px; border: 1px solid var(--line);
                   border-radius: 8px; background: transparent; color: inherit; font: inherit; }
    .roomStartRow { display: flex; gap: 8px; padding: 0 8px 10px; }
    .roomStart { flex: 1 1 0; padding: 10px; border: 1px dashed var(--line); border-radius: 8px;
                 background: transparent; color: inherit; font: inherit; cursor: pointer; }
    .roomRow.archived { opacity: .55; }
    .listUtilities { display: flex; gap: 8px; padding: 8px 12px 4px; }
    .listUtilities button { flex: 1 1 0; padding: 8px; border: 1px solid var(--line);
                            border-radius: 8px; background: transparent; color: inherit;
                            font: inherit; font-size: 12px; cursor: pointer; }
    .roomEmpty { padding: 32px 16px; text-align: center; opacity: .7; line-height: 1.6; }
    .session-group { display: flex; flex-direction: column; gap: 6px; }
    /* 워크트리 = 단위. 헤더에서 바로 새 에이전트를 띄운다(웹 카드의 ＋CC/＋CX 와 같은 멘탈모델). */
    .wt-group { display: block; }
    .wt-group > .session-card { margin-top: 6px; }
    .wt-group-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; cursor: pointer; list-style: none; }
    .wt-group-head::-webkit-details-marker { display: none; }
    .wt-group-name { display: inline-flex; min-width: 0; align-items: center; gap: 5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .wt-group-acts { display: inline-flex; flex: none; align-items: center; gap: 4px; }
    .wt-group-count { min-width: 16px; text-align: right; }
    /* 전역 button 이 width:100% 라 이걸 안 덮으면 좁은 컨테이너(드로어)에서 눌려 ＋CC 가 두 줄로 접힌다. */
    .wtMoreBtn { color: #4d5665; font-size: 15px; line-height: 1; }
    .wtActions { flex: 1; min-height: 0; display: flex; flex-direction: column; overflow-y: auto; padding: 6px 12px calc(14px + env(safe-area-inset-bottom)); }
    .wtAction { display: flex; align-items: center; gap: 10px; width: 100%; min-height: 48px; padding: 0 10px; border: 0; border-radius: 8px; background: none; text-align: left; font-size: 13px; font-weight: 700; color: #17191f; }
    .wtAction:disabled { opacity: .5; }
    .wtActionNote { margin-left: auto; color: #63708a; font-size: 11px; font-weight: 700; }
    .wtLaunchBtn { width: auto; flex: none; min-width: 34px; min-height: 26px; padding: 0 5px; border-radius: 7px; font-size: 10px; font-weight: 900; white-space: nowrap; }
    .session-group-title { display: flex; align-items: center; justify-content: space-between; padding: 0 2px; color: #596070; font-size: 11px; font-weight: 900; text-transform: uppercase; }
    .session-card { display: block; min-height: 88px; height: auto; padding: 10px 11px; text-align: left; color: inherit; border-color: #d8dee7; overflow: hidden; }
    .session-card.active { border-color: #0b63ce; box-shadow: 0 0 0 1px #0b63ce inset; }
    .session-card-top { display: flex; align-items: center; gap: 7px; min-width: 0; }
    .session-title { display: block; min-width: 0; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 850; line-height: 1.25; }
    :root { --st-run: #1f9d6b; --st-boot: #c07f14; --st-err: #d13438; --st-stop: #8a8f98; --st-ask: #0b63ce; }
    .session-status { flex: 0 0 auto; display: inline-flex; align-items: center; gap: 4px; }
    .session-status-label { font-size: 10px; font-weight: 850; color: #747d8b; white-space: nowrap; }
    .wt-dot { flex: none; width: 13px; height: 13px; border-radius: 50%; display: inline-flex; align-items: center; justify-content: center; font-size: 8px; line-height: 1; box-sizing: border-box; }
    .wt-dot.run { border: 1.5px solid var(--st-run); color: var(--st-run); }
    .wt-dot.run::after { content: "✓"; }
    .wt-dot.boot { border: 1.5px solid var(--st-boot); border-left-color: transparent; color: var(--st-boot); animation: liveActionSpin 1.3s linear infinite; }
    .wt-dot.part { border: 1.5px solid var(--st-boot); color: var(--st-boot); }
    .wt-dot.part::after { content: "◐"; font-size: 10px; }
    /* 응답 필요는 **오류가 아니다** — "형 차례"다. 빨강 ✕(실패)와 색·기호를 둘 다 다르게 둔다.
       색만 다르면 색각 차이나 작은 화면에서 구분이 안 되니 기호까지 같이 바꾼다. */
    .wt-dot.ask { border: 1.5px solid var(--st-ask); color: var(--st-ask); }
    .wt-dot.ask::after { content: "?"; font-weight: 900; }
    .wt-dot.bad { border: 1.5px solid var(--st-err); color: var(--st-err); }
    .wt-dot.bad::after { content: "✕"; }
    .wt-dot.stop { border: 1.5px solid var(--st-stop); color: var(--st-stop); }
    .wt-dot.stop::after { content: "■"; font-size: 6px; }
    .source-badge { flex: 0 0 auto; display: inline-flex; align-items: center; min-height: 20px; padding: 0 6px; border-radius: 4px; background: #e9edf3; color: #4d5665; font-size: 9px; font-weight: 900; line-height: 1; text-transform: uppercase; }
    .source-badge.codex { background: #e6f5ec; color: #17643a; }
    .source-badge.claude { background: #fff0e8; color: #9a421d; }
    .session-subtitle { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #596070; font-size: 12px; line-height: 1.25; margin-top: 3px; }
    .session-preview { display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; color: #303846; font-size: 12px; line-height: 1.3; margin-top: 6px; }
    .empty-state { padding: 28px 12px; color: #747d8b; text-align: center; font-size: 13px; line-height: 1.45; }
    .usagePanel { position: absolute; top: 42px; right: 8px; z-index: 7; display: none; width: min(250px, calc(100vw - 16px)); padding: 10px; box-sizing: border-box; border: 1px solid #ccd3dd; border-radius: 8px; background: #fff; box-shadow: 0 8px 24px rgb(23 25 31 / 16%); font-variant-numeric: tabular-nums; }
    .usagePanel.open { display: block; }
    .usageSection + .usageSection { margin-top: 10px; padding-top: 9px; border-top: 1px solid #e4e8ee; }
    .usageSectionTitle { margin-bottom: 5px; color: #747d8b; font-size: 9px; font-weight: 900; letter-spacing: .02em; }
    .usageAccountRows { display: grid; gap: 5px; }
    .usageAccountRow { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 5px 8px; align-items: baseline; }
    .usageAccountLabel { min-width: 0; overflow: hidden; color: #303846; font-size: 11px; font-weight: 800; text-overflow: ellipsis; white-space: nowrap; }
    .usageAccountValue { color: #303846; font-size: 11px; font-weight: 900; }
    .usageAccountReset { grid-column: 1 / -1; margin-top: -4px; color: #8992a0; font-size: 9px; }
    .usageAccountTrack { grid-column: 1 / -1; height: 3px; overflow: hidden; border-radius: 2px; background: #dfe5ec; }
    .usageAccountFill { display: block; width: 0; height: 100%; background: #26845b; transition: width .18s ease; }
    .usageAccountRow[data-level="warn"] .usageAccountFill { background: #bd7418; }
    .usageAccountRow[data-level="critical"] .usageAccountFill { background: #c43d3d; }
    .usageAccountRow.unavailable .usageAccountFill { background: transparent; }
    .usageUnavailable { color: #8992a0; font-size: 10px; }
    .usageMetrics { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 4px 10px; }
    .usageMetric { min-width: 0; }
    .usageLabel { display: block; color: #747d8b; font-size: 9px; font-weight: 800; }
    .usageValue { display: block; margin-top: 1px; overflow: hidden; color: #303846; font-size: 12px; font-weight: 900; text-overflow: ellipsis; white-space: nowrap; }
    .usageTrack { grid-column: 1 / -1; height: 3px; margin-top: 6px; overflow: hidden; border-radius: 2px; background: #dfe5ec; }
    .usageFill { display: block; width: 0; height: 100%; background: #26845b; transition: width .18s ease; }
    .usagePanel[data-level="warn"] .usageFill { background: #bd7418; }
    .usagePanel[data-level="critical"] .usageFill { background: #c43d3d; }
    .historyStatus { display: none; min-height: 24px; align-items: center; justify-content: center; color: #747d8b; font-size: 10px; }
    .turns { display: flex; min-height: 0; flex-direction: column; justify-content: flex-start; gap: 9px; overflow-y: auto; overscroll-behavior: contain; padding: 2px 1px 8px; }
    .turns > *, .conversationSequence, .activityGroup, .turn { flex: 0 0 auto; }
    .conversationSequence { display: flex; align-self: stretch; flex-direction: column; gap: 8px; }
    .turn { align-self: flex-start; max-width: 88%; padding: 9px 11px; border-radius: 8px; background: #eef2f7; font-size: 13px; line-height: 1.5; overflow-wrap: anywhere; }
    .turn.user { align-self: flex-end; background: #dcecff; }
    .turn.output { width: 100%; max-width: none; background: #111827; color: #e5e7eb; font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; }
    .turn.pending { opacity: .82; }
    .turnState { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; margin-top: 5px; color: #687083; font-size: 10px; font-weight: 750; }
    .turnState.failed { color: #c43d3d; cursor: pointer; text-decoration: underline; text-underline-offset: 2px; }
    .pendingActions { display: inline-flex; gap: 5px; }
    .pendingActionBtn { display: inline-flex; align-items: center; width: auto; min-height: 19px; padding: 1px 7px; border: 1px solid #c8d1dc; border-radius: 999px; background: #fff; color: #526176; font-size: 9px; font-weight: 800; line-height: 1.6; text-decoration: none; cursor: pointer; }
    .pendingActionBtn[data-pending-cancel] { border-color: #e3b8b8; color: #a22b2b; }
    .queuedTag { display: inline-block; margin-bottom: 4px; padding: 1px 6px; border-radius: 6px; background: rgba(11, 99, 206, .12); color: #0b63ce; font-size: 9px; font-weight: 850; }
    .queuedTag.consumed { background: rgba(107, 114, 128, .14); color: #6b7280; }
    .queuedTag.steered { background: rgba(47, 107, 69, .14); color: #2f6b45; }
    .turnMeta { align-self: flex-start; margin-top: -3px; color: #747d8b; font-size: 9px; font-weight: 800; }
    .turnMeta.right { align-self: flex-end; }
    .liveAction { display: grid; grid-template-columns: 8px minmax(0, 1fr) auto; gap: 7px; align-items: center; width: 100%; min-height: 34px; padding: 0 8px; border: 0; border-radius: 0; background: transparent; color: #303846; text-align: left; }
    .liveActionDot { width: 7px; height: 7px; border: 2px solid #c8d1dc; border-top-color: #0b63ce; border-radius: 50%; animation: liveActionSpin .8s linear infinite; }
    .liveActionLabel { min-width: 0; overflow: hidden; font-size: 11px; font-weight: 850; text-overflow: ellipsis; white-space: nowrap; }
    .liveActionMeta { color: #747d8b; font-size: 9px; font-weight: 800; white-space: nowrap; }
    @keyframes liveActionSpin { to { transform: rotate(360deg); } }
    .turn a, .subagent-turn a { color: #0969da; text-decoration: underline; text-underline-offset: 2px; }
    .turn code, .subagent-turn code { padding: 1px 4px; border-radius: 4px; background: rgba(127, 127, 127, .14); font: .92em/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; }
    .activityGroup { align-self: stretch; overflow: hidden; border: 1px solid #d8dee7; border-radius: 8px; background: #f8f9fb; }
    .activityGroup > summary { min-height: 38px; padding: 0 10px; color: #526176; font-size: 11px; font-weight: 850; line-height: 38px; cursor: pointer; list-style-position: inside; }
    .activityGroup[open] > summary { border-bottom: 1px solid #e2e6ec; }
    .activityList { display: flex; flex-direction: column; max-height: 320px; overflow-y: auto; overscroll-behavior: contain; padding: 3px 9px 7px; }
    .activityItem { border-bottom: 1px solid #e5e8ed; }
    .activityItem:last-child { border-bottom: 0; }
    .activityItem > summary { display: grid; grid-template-columns: 8px minmax(0, 1fr) auto; gap: 7px; align-items: center; min-height: 34px; color: #303846; font-size: 11px; cursor: pointer; list-style: none; }
    .activityItem > summary::-webkit-details-marker { display: none; }
    .activityDot { width: 6px; height: 6px; border-radius: 50%; background: #26845b; }
    .activityItem.running .activityDot { background: #bd7418; }
    .activityItem.failed .activityDot { background: #c43d3d; }
    .activityLabel { min-width: 0; overflow: hidden; font-weight: 800; text-overflow: ellipsis; white-space: nowrap; }
    .activityType { color: #747d8b; font-size: 9px; font-weight: 800; text-transform: uppercase; }
    .activityBody { display: grid; gap: 6px; padding: 0 0 8px 15px; }
    .activityBodyLabel { color: #747d8b; font-size: 9px; font-weight: 800; }
    .activityCode { max-height: 220px; margin: 0; overflow: auto; padding: 7px 8px; border-radius: 6px; background: #111827; color: #e5e7eb; font: 10px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; overflow-wrap: anywhere; }
    .activityCode .diffAdd { display: inline-block; width: 100%; color: #86efac; background: rgba(34, 197, 94, .14); }
    .activityCode .diffDel { display: inline-block; width: 100%; color: #fca5a5; background: rgba(239, 68, 68, .14); }
    .activityCode .diffHunk { display: inline-block; width: 100%; color: #a5b4fc; }
    .newMessagesBtn { position: absolute; left: 50%; bottom: 8px; z-index: 3; display: none; width: auto; min-height: 34px; padding: 0 12px; transform: translateX(-50%); border-color: #b9c6d8; background: #fff; box-shadow: 0 4px 14px rgb(23 25 31 / 14%); font-size: 12px; }
    /* CLI(claude/codex) 자체 버전 배너 — 위 updateBanner(데몬 재시작 감지)와는 다른 것이다. */
    .cliUpdateBanner { position: fixed; left: 50%; top: 8px; z-index: 19; width: auto; min-height: 30px; padding: 0 12px; transform: translateX(-50%); border: 1px solid #d9c48a; border-radius: 8px; background: #8a6d1f; color: #fff; box-shadow: 0 4px 14px rgb(23 25 31 / 20%); font-size: 12px; font-weight: 700; }
    .cliUpdateBanner[hidden] { display: none; }
    /* 로그·깃 시트 (읽기 전용) */
    .sheetTools { display: flex; gap: 6px; padding: 8px 12px; border-bottom: 1px solid #e3e7ee; }
    .sheetTools select, .sheetTools input { flex: 1 1 auto; min-width: 0; padding: 6px 8px; border: 1px solid #ccd3dd; border-radius: 7px; font-size: 12px; }
    .sheetTools button { flex: 0 0 auto; padding: 6px 10px; border: 1px solid #ccd3dd; border-radius: 7px; background: #fff; font-size: 12px; }
    .sheetTools button.on { border-color: #b03030; color: #b03030; }
    .logsBody { max-height: 62vh; overflow: auto; padding: 8px 12px; font: 11px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; overflow-wrap: anywhere; }
    .logsBody .lgErr { color: #c03434; }
    .gitStatus { padding: 8px 12px; border-bottom: 1px solid #e3e7ee; font-size: 12px; color: #495468; }
    .gitBody { max-height: 62vh; overflow: auto; padding: 8px 12px; font-size: 12px; }
    .gitRow { display: flex; gap: 8px; align-items: baseline; padding: 6px 0; border-bottom: 1px solid #eef1f5; }
    .gitRow .nm { flex: 1 1 auto; overflow-wrap: anywhere; }
    .gitRow .st { flex: 0 0 auto; color: #7a8496; font: 11px ui-monospace, Menlo, monospace; }
    .gitSect { margin-top: 10px; color: #7a8496; font-size: 11px; font-weight: 700; }
    .gitDiff { margin: 4px 0 8px; padding: 6px 8px; border-radius: 6px; background: #12151c; color: #cbd3e1; font: 11px/1.45 ui-monospace, Menlo, monospace; white-space: pre; overflow-x: auto; }
    .gitDiff .add { color: #7ee2a8; } .gitDiff .del { color: #f6a6a6; } .gitDiff .hunk { color: #a5b4fc; }
    .updateBanner { position: fixed; left: 50%; top: 8px; z-index: 20; display: none; width: auto; min-height: 32px; padding: 0 14px; transform: translateX(-50%); border: 1px solid #b9d4f2; border-radius: 8px; background: #0b63ce; color: #fff; box-shadow: 0 4px 14px rgb(23 25 31 / 20%); font-size: 12px; font-weight: 800; }
    .chatComposer { z-index: 3; display: flex; min-width: 0; flex-direction: column; gap: 6px; padding: 7px 10px max(8px, env(safe-area-inset-bottom)); background: #fff; border-top: 1px solid #dde2ea; box-sizing: border-box; }
    .composerRow { display: grid; grid-template-columns: 44px minmax(0, 1fr) 44px; gap: 7px; align-items: end; }
    .chatComposer textarea { min-height: 44px; max-height: 132px; padding: 10px 11px; resize: none; overflow-y: auto; }
    .sendBtn { width: 44px; height: 44px; min-height: 44px; padding: 0; font-size: 20px; }
    .attachBtn { width: 44px; height: 44px; min-height: 44px; padding: 0; border-color: #cdd6e2; background: #eef2f7; color: #4d5665; font-size: 18px; }
    .attachStrip { display: flex; flex-wrap: wrap; gap: 6px; }
    .attachStrip:empty { display: none; }
    .attachChip { display: inline-flex; align-items: center; gap: 5px; max-width: 100%; padding: 3px 4px 3px 6px; border: 1px solid #cdd6e2; border-radius: 8px; background: #f4f7fb; font-size: 10px; color: #3b4351; }
    .attachChip img { width: 30px; height: 30px; border-radius: 4px; object-fit: cover; }
    .attachChip .attachName { max-width: 120px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .attachChip.uploading { opacity: .6; }
    .attachChip .attachDel { width: 20px; height: 20px; min-height: 20px; padding: 0; border: 0; border-radius: 5px; background: transparent; color: #a22b2b; font-size: 14px; line-height: 1; }
    /* 말풍선 안 블록 요소 — 좁은 화면이라 넘치는 것(다이어그램·표)은 제 컨테이너 안에서만 가로 스크롤한다.
       본문이 통째로 옆으로 밀리면 읽기가 더 나빠지므로 바깥은 절대 안 밀리게. */
    .turnBody > :first-child { margin-top: 0; }
    .turnBody > :last-child { margin-bottom: 0; }
    .mdP { margin: 6px 0; }
    .mdH { margin: 10px 0 5px; font-weight: 850; line-height: 1.35; }
    .mdH1 { font-size: 15px; } .mdH2 { font-size: 14px; } .mdH3 { font-size: 13px; }
    .mdH4, .mdH5, .mdH6 { font-size: 12px; color: #4d5665; }
    .mdList { margin: 5px 0; padding-left: 19px; }
    .mdList li { margin: 2px 0; }
    .mdList .mdList { margin: 2px 0; }
    .mdHr { margin: 9px 0; border: 0; border-top: 1px solid #d5dbe4; }
    .mdQuote { margin: 6px 0; padding: 2px 0 2px 9px; border-left: 3px solid #c8d1dc; color: #4d5665; }
    .mdCode { position: relative; margin: 6px 0; border: 1px solid #d5dbe4; border-radius: 7px; background: #f7f8fa; overflow: hidden; }
    .mdCode pre { margin: 0; padding: 8px 10px; overflow-x: auto; }
    .mdCode code { display: block; white-space: pre; font: 11px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; background: none; padding: 0; }
    .mdCodeLang { display: block; padding: 3px 10px; border-bottom: 1px solid #e3e7ee; color: #63708a; font-size: 9px; font-weight: 800; text-transform: uppercase; letter-spacing: .04em; }
    .mdTableWrap { margin: 6px 0; overflow-x: auto; border: 1px solid #d5dbe4; border-radius: 7px; }
    .mdTable { border-collapse: collapse; width: 100%; font-size: 11px; }
    .mdTable th, .mdTable td { padding: 5px 8px; border-bottom: 1px solid #e3e7ee; border-right: 1px solid #e3e7ee; text-align: left; vertical-align: top; }
    .mdTable th:last-child, .mdTable td:last-child { border-right: 0; }
    .mdTable tbody tr:last-child td { border-bottom: 0; }
    .mdTable th { background: #f2f4f8; font-weight: 800; white-space: nowrap; }
    .trimNotice { display: none; margin: 0 0 6px; padding: 6px 9px; border-radius: 7px; background: #fff6e5; color: #8a5a12; font-size: 10px; line-height: 1.45; }
    .turnAttachments { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 6px; }
    .turnAttachments img { max-width: 180px; max-height: 180px; border-radius: 6px; object-fit: cover; }
    .turnAttachments a { font-size: 11px; }
    .turnImageBtn { width: auto; min-height: 0; padding: 0; border: 1px solid #d5dbe4; border-radius: 6px; background: none; overflow: hidden; line-height: 0; }
    .turnImageBtn img { display: block; max-width: 180px; max-height: 180px; object-fit: cover; }
    .activityImages { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 6px; }
    /* 접힘 밖으로 끌어올린 결과 그림 — 대화를 그냥 읽어도 보여야 한다(형 요청) */
    .activityImages.hoisted { margin: 6px 0 2px; }
    .activityOpen { flex: none; margin-left: 6px; padding: 1px 7px; border: 1px solid #ccd3dd; border-radius: 999px; background: transparent; color: #5b6678; font-size: 10.5px; }
    .galleryBody { flex: 1; min-height: 0; display: flex; flex-direction: column; gap: 8px; padding: 10px 12px calc(14px + env(safe-area-inset-bottom)); overflow-y: auto; overscroll-behavior: contain; }
    .galleryStatus { color: #63708a; font-size: 11px; }
    .galleryGrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(96px, 1fr)); gap: 6px; }
    .galleryCell { width: 100%; min-height: 0; padding: 0; aspect-ratio: 1; border: 1px solid #d5dbe4; border-radius: 7px; background: #f0f2f6; overflow: hidden; line-height: 0; }
    .galleryCell img { width: 100%; height: 100%; object-fit: cover; }
    .galleryTabs { display: flex; gap: 4px; padding: 6px 12px 0; }
    .galleryTab { width: auto; min-height: 32px; padding: 0 11px; border-radius: 7px 7px 0 0; border-bottom-color: transparent; background: none; color: #63708a; font-size: 11px; font-weight: 800; }
    .galleryTab.active { background: var(--sheet-active, #eef2f8); color: #1f2733; }
    .fileList { display: flex; flex-direction: column; gap: 5px; }
    .fileRow { display: flex; align-items: center; gap: 8px; width: 100%; min-height: 42px; padding: 7px 9px; border: 1px solid #d5dbe4; border-radius: 7px; background: #fff; text-align: left; }
    .fileRow:disabled { opacity: .55; }
    .fileThumb { flex: none; width: 30px; height: 30px; border-radius: 5px; object-fit: cover; background: #f0f2f6; }
    .fileIcon { flex: none; width: 30px; height: 30px; border-radius: 5px; background: #f0f2f6; color: #63708a; font-size: 9px; font-weight: 800; display: flex; align-items: center; justify-content: center; }
    .fileMeta { min-width: 0; display: flex; flex-direction: column; gap: 1px; }
    .fileName { font-size: 12px; font-weight: 700; overflow-wrap: anywhere; }
    .fileSub { color: #63708a; font-size: 10px; overflow-wrap: anywhere; }
    .fileBadge { flex: none; margin-left: auto; padding: 1px 6px; border-radius: 999px; background: #e6efe8; color: #2f6b45; font-size: 9px; font-weight: 800; }
    .fileBadge.edited { background: #eef2f8; color: #4d5665; }
    /* 앱 안 뷰어 — 이미지도 텍스트 파일도 여기서 본다(새 탭을 띄우지 않는다). */
    .imageViewer { position: fixed; inset: 0; z-index: 30; display: none; flex-direction: column; background: rgb(8 10 14 / 94%); }
    .imageViewer.open { display: flex; }
    .viewerBar { display: flex; flex: none; align-items: center; gap: 8px; padding: max(8px, env(safe-area-inset-top)) 10px 8px; }
    .viewerCount { flex: none; color: #9fb0c6; font: 11px/1 ui-monospace, Menlo, monospace; font-variant-numeric: tabular-nums; }
    .viewerNav { position: absolute; top: 50%; z-index: 2; width: 40px; height: 56px; transform: translateY(-50%); border: 1px solid rgb(255 255 255 / 18%); border-radius: 9px; background: rgb(0 0 0 / 34%); color: #fff; font-size: 20px; line-height: 1; }
    .viewerNav.prev { left: 10px; } .viewerNav.next { right: 10px; }
    .viewerNav[disabled] { opacity: .25; }
    .viewerDead { display: none; padding: 0 24px; color: #e8b96b; font-size: 13px; line-height: 1.6; text-align: center; }
    .viewerName { flex: 1; min-width: 0; color: #e8edf4; font-size: 11px; font-weight: 700; overflow-wrap: anywhere; }
    .imageViewer img { flex: 1; min-height: 0; max-width: 100%; margin: 0 auto; padding: 0 12px 12px; object-fit: contain; }
    .viewerText { flex: 1; min-height: 0; margin: 0; padding: 0 12px calc(12px + env(safe-area-inset-bottom)); overflow: auto; color: #e8edf4; font: 11px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre; }
    .imageViewerClose { width: 34px; min-height: 34px; flex: none; padding: 0; border-radius: 17px; background: rgb(255 255 255 / 14%); color: #fff; border-color: transparent; font-size: 19px; }
    /* 세션 탭 — 가로 스크롤 한 줄. 목록 뷰에선 숨긴다(거기선 목록 자체가 탐색이다). */
    .sessionTabs:empty { display: none; }
    .sessionTabs { display: none; gap: 4px; overflow-x: auto; overscroll-behavior-x: contain;
                   scrollbar-width: none; padding: 2px 0 1px; }
    .sessionTabs::-webkit-scrollbar { display: none; }
    #mobileApp[data-view="chat"] .sessionTabs { display: flex; }
    .sessionTab { display: inline-flex; flex: 0 0 auto; align-items: center; gap: 4px; max-width: 46vw;
                  padding: 3px 6px 3px 7px; border: 1px solid #dde2ea; border-radius: 999px;
                  background: #f4f6f9; color: #596070; font-size: 11px; font-weight: 700; line-height: 1.3; }
    .sessionTab.active { background: #fff; border-color: #9db2d4; color: #17191f; }
    .sessionTabLabel { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
    .sessionTabX { flex: 0 0 auto; padding: 0 1px; color: #98a1b3; font-size: 10px; font-weight: 900; }
    .liveQuestion:empty { display: none; }
    /* 높이 상한이 필수다. 선택지가 많거나 설명이 길면 카드가 무한히 자라 **위 대화를 통째로 덮어**
       형이 질문 맥락을 못 읽는다(형: "질문 길어지면 위에 대화내용 못읽게 되는것도 문제야").
       화면의 45%까지만 쓰고 그 안에서 스크롤한다 — 작업 블록에서 쓴 것과 같은 처방. */
    .liveQuestion { margin-bottom: 2px; max-height: 45dvh; overflow-y: auto; overscroll-behavior: contain; }
    .questionCard { align-self: stretch; max-width: 100%; min-width: 0; overflow-wrap: anywhere; display: flex; flex-direction: column; gap: 8px; padding: 11px 12px; border: 1px solid #b9d4f2; border-radius: 10px; background: #f2f8ff; }
    .questionHeader { color: #0b63ce; font-size: 9px; font-weight: 850; text-transform: uppercase; letter-spacing: .04em; }
    .questionText { min-width: 0; overflow-wrap: anywhere; font-size: 13px; font-weight: 650; line-height: 1.45; }
    .questionOpts { display: flex; min-width: 0; flex-direction: column; gap: 6px; }
    .questionOpt { display: flex; flex-direction: column; align-items: flex-start; gap: 2px; width: 100%; max-width: 100%; min-width: 0; box-sizing: border-box; overflow-wrap: anywhere; white-space: normal; min-height: 40px; padding: 8px 11px; border: 1px solid #b9c6d8; border-radius: 8px; background: #fff; text-align: left; }
    .questionOpt:disabled { opacity: .45; background: #f2f4f8; cursor: not-allowed; }
    /* 우상단 사용량 게이지 — conic-gradient 로 채운 링. 안에 숫자를 겹쳐 한눈에 읽히게 한다.
       예전 아이콘은 고정 문자(◔)라 값이 안 변해 장식일 뿐이었다. */
    .usageRing { position: relative; display: inline-flex; width: 26px; height: 26px; align-items: center; justify-content: center;
                 border-radius: 50%; background: conic-gradient(var(--ring, #4d5665) calc(var(--pct, 0) * 1%), #e3e7ee 0); }
    .usageRing::after { content: ""; position: absolute; inset: 3px; border-radius: 50%; background: #fff; }
    .usageRing[data-level="warn"] { --ring: #d08321; }
    .usageRing[data-level="critical"] { --ring: #c0392b; }
    .usageRingNum { position: relative; z-index: 1; font-size: 9px; font-weight: 900; color: #4d5665; line-height: 1; }
    .usageRing[data-level="warn"] .usageRingNum { color: #a8571a; }
    .usageRing[data-level="critical"] .usageRingNum { color: #a02222; }
    .questionBlocked { padding: 7px 9px; border-radius: 7px; background: #f2f4f8; color: #4d5665; font-size: 11px; line-height: 1.45; }
    .questionOptLabel { max-width: 100%; overflow-wrap: anywhere; font-size: 12px; font-weight: 800; color: #1f2733; }
    .questionOptDesc { max-width: 100%; overflow-wrap: anywhere; font-size: 10px; color: #63708a; line-height: 1.4; }
    .questionMore { color: #63708a; font-size: 10px; }
    .questionBlock { display: flex; flex-direction: column; gap: 8px; }
    .questionBlock + .questionBlock { padding-top: 9px; border-top: 1px solid #cfe0f3; }
    .questionStep { color: #63708a; font-size: 9px; font-weight: 800; letter-spacing: .04em; }
    .questionOpt.chosen { border-color: #0b63ce; background: #e3efff; box-shadow: inset 0 0 0 1px #0b63ce; }
    /* 이미 답한 질문 = 기록이다. 누를 수 없다는 게 보여야 하고(커서·최소높이 없음), 대화 흐름을
       끊지 않게 라이브 카드보다 조용해야 한다. */
    /* 생각 중 — 답변 쪽(왼쪽)에 붙여 "여기 답이 나온다"를 암시한다. */
    /* #chatView 는 행 두 개짜리 그리드다. 평범한 자식으로 넣으면 암묵 행으로 밀려 overflow:hidden
       에 잘려 아예 안 보인다(실측 2026-08-17: 형 "생각중 안뜨고"). 대화 목록 안에 넣는 것도 안 된다
       — 재조정기가 모르는 자식을 지운다. 그래서 **떠 있게** 두고, 가릴 만큼만 아래 여백을 준다. */
    #thinkingSlot { position: absolute; left: 9px; bottom: 6px; z-index: 2; }
    #thinkingSlot[hidden] { display: none; }
    #chatView.thinking .turns { padding-bottom: 42px; }
    /* 완료 카드도 같은 함정에 걸린다 — 평범한 자식으로 넣으면 암묵 행으로 밀려 잘린다.
       실측: 카드가 그려졌는데 offsetHeight 0 이었다(생각중 표시가 겪은 것과 같은 자리). */
    #doneSlot { position: absolute; left: 9px; right: 9px; bottom: 6px; z-index: 2; }
    #doneSlot[hidden] { display: none; }
    #chatView.hasDone .turns { padding-bottom: 96px; }
    .thinkingBubble { display: inline-flex; gap: 8px; align-items: center; padding: 8px 11px; border: 1px solid #dde2ea; border-radius: 12px 12px 12px 3px; background: #fff; color: #5b6472; font-size: 12px; }
    .thinkingDots { display: inline-flex; gap: 3px; }
    .thinkingDots i { width: 5px; height: 5px; border-radius: 50%; background: #8b95a5; animation: thinkingPulse 1.2s ease-in-out infinite; }
    .thinkingDots i:nth-child(2) { animation-delay: .15s; }
    .thinkingDots i:nth-child(3) { animation-delay: .3s; }
    @keyframes thinkingPulse { 0%, 80%, 100% { opacity: .28; transform: translateY(0); } 40% { opacity: 1; transform: translateY(-2px); } }
    @media (prefers-reduced-motion: reduce) { .thinkingDots i { animation: none; opacity: .6; } }
    .installHint { position: fixed; left: 8px; right: 8px; bottom: max(10px, env(safe-area-inset-bottom)); z-index: 21; display: flex; gap: 8px; align-items: center; padding: 9px 10px; border: 1px solid #b9d4f2; border-radius: 9px; background: #0b63ce; color: #fff; box-shadow: 0 6px 20px rgb(23 25 31 / 22%); font-size: 12px; line-height: 1.45; }
    .installHint[hidden] { display: none; }
    .installHintClose { flex: none; width: 26px; height: 26px; padding: 0; border: 0; border-radius: 6px; background: rgb(255 255 255 / 18%); color: #fff; font-size: 16px; line-height: 1; }
    /* 실시간 연결 표시 — 켜져 있으면 은은히 맥박, 끊기면 회색. 형이 "멈춘 것 같다"고 느낀 자리다. */
    /* 알림 토글은 **어느 화면에서든** 보여야 한다. .usageBtn 은 기본이 숨김이고 대화 화면에서
       .available 이 붙을 때만 뜨는 규칙이라, 그 클래스만 주면 영영 안 보인다(형: "모아보기랑
       초록색 동그라미 밖에 안보이는데"). 모양은 물려받고 표시 규칙만 따로 쓴다. */
    .usageBtn.notifyBtn { display: inline-flex; align-items: center; justify-content: center; }
    .usageBtn.notifyBtn.active { color: #26845b; }
    .liveDot { width: 7px; height: 7px; margin-right: 2px; border-radius: 50%; background: #b6bec9; flex: none; align-self: center; }
    body[data-live="on"] .liveDot { background: #26845b; animation: livePulse 2.4s ease-in-out infinite; }
    @keyframes livePulse { 0%, 100% { opacity: 1; } 50% { opacity: .35; } }
    @media (prefers-reduced-motion: reduce) { body[data-live="on"] .liveDot { animation: none; } }
    .questionCard.answered { background: transparent; border-style: dashed; }
    /* 보냈지만 서버가 아직 안 내린 카드 — 눌리지 않는다는 걸 눈으로도 알려준다. */
    .questionCard.submitted { opacity: .62; border-style: dashed; }
    .questionOpt.answered { min-height: 0; cursor: default; }
    .questionSubmitRow { display: flex; }
    .questionSubmit { width: 100%; min-height: 40px; }
    .questionFailed { padding: 7px 9px; border-radius: 7px; background: #fdecec; color: #a02222; font-size: 11px; line-height: 1.45; }
    .questionOther { color: #4d5665; font-weight: 700; }
    /* 기타 입력은 **그 줄에서** 한다 — 아래에 줄을 더 만들지 않는다(형 요청). */
    .questionOtherRow { display: flex; gap: 6px; align-items: center; }
    .questionOtherInput { flex: 1; min-width: 0; min-height: 40px; padding: 0 10px; }
    .questionOtherSend { width: auto; min-width: 0; min-height: 38px; padding: 0 14px; }
    .sessionControls { display: flex; min-height: 30px; align-items: center; gap: 5px; }
    .sessionControlBtn { width: auto; min-width: 0; min-height: 28px; padding: 0 8px; border-color: transparent; background: #eef2f7; color: #4d5665; font-size: 10px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .sessionControls .status { min-width: 0; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .stopBtn { display: none; width: 30px; min-width: 30px; min-height: 28px; padding: 0; border-color: #df9b9b; color: #a22b2b; font-size: 13px; }
    .composerMeta { display: flex; min-height: 18px; align-items: center; gap: 8px; }
    .composerMeta .status { flex: 1; }
    .retryBtn { display: none; width: auto; min-height: 28px; padding: 0 8px; border: 0; font-size: 12px; }
    .suggestions { display: none; max-height: min(42vh, 280px); overflow-y: auto; border: 1px solid #d8dee7; border-radius: 8px; background: #fff; box-shadow: 0 -8px 24px rgb(23 25 31 / 10%); }
    .suggestions.open { display: block; }
    .suggestion { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 8px; width: 100%; min-height: 42px; padding: 7px 10px; border: 0; border-radius: 0; text-align: left; color: inherit; }
    .suggestion + .suggestion { border-top: 1px solid #edf0f4; }
    .suggestion-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 800; }
    .suggestion-description { overflow: hidden; color: #747d8b; font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }
    .suggestion-kind { color: #747d8b; font-size: 10px; text-transform: uppercase; }
    .sheetBackdrop { position: fixed; inset: 0; z-index: 12; display: none; align-items: flex-end; background: rgb(10 14 20 / 38%); }
    .sheetBackdrop.open { display: flex; }
    /* flex 컬럼이라야 본문이 남는 높이를 먹고 스크롤한다. 예전엔 블록 + overflow:hidden 이라
       본문에 overflow-y:auto 를 줘도 그냥 잘렸다(형: "모아보기 스크롤 안된다"). */
    .bottomSheet { display: flex; flex-direction: column; width: 100%; max-height: 78vh; overflow: hidden; border-radius: 8px 8px 0 0; background: #fff; box-shadow: 0 -12px 34px rgb(0 0 0 / 18%); }
    .bottomSheet > .sheetHeader, .bottomSheet > .galleryTabs { flex: none; }
    .sheetHeader { display: grid; grid-template-columns: 40px minmax(0, 1fr) 40px; align-items: center; min-height: 48px; padding: 0 8px; border-bottom: 1px solid #dde2ea; }
    .sheetHeader strong { grid-column: 2; text-align: center; }
    .sheetClose { grid-column: 3; }
    .subagentList { max-height: calc(78vh - 49px); overflow-y: auto; padding: 6px 12px max(14px, env(safe-area-inset-bottom)); }
    .serviceList, .settingsBody { max-height: calc(78vh - 49px); overflow-y: auto; padding: 8px 12px max(14px, env(safe-area-inset-bottom)); }
    .serviceItem { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 8px; align-items: center; min-height: 54px; border-bottom: 1px solid #e3e7ed; }
    .serviceName { min-width: 0; font-size: 13px; font-weight: 850; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .serviceState { margin-top: 2px; color: #747d8b; font-size: 10px; }
    .serviceActions { display: flex; gap: 4px; }
    .serviceActions button { width: 32px; min-height: 32px; padding: 0; font-size: 14px; }
    .serviceUtilities { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 5px; padding-top: 10px; }
    .serviceUtilities button { min-width: 0; min-height: 34px; padding: 0 5px; font-size: 10px; }
    .settingsBody { display: flex; flex-direction: column; gap: 12px; }
    .settingsBody select, .settingsBody input { min-height: 40px; }
    .inboxList { max-height: calc(78vh - 49px); overflow-y: auto; padding-bottom: max(14px, env(safe-area-inset-bottom)); }
    .inboxGroup { position: sticky; top: 0; z-index: 1; padding: 8px 12px 6px; border-bottom: 1px solid #e3e7ed; background: #fff; color: #747d8b; font-size: 10px; font-weight: 900; text-transform: uppercase; }
    .inboxItem { display: grid; grid-template-columns: auto minmax(0, 1fr) auto; gap: 9px; align-items: center; min-height: 62px; padding: 9px 12px; border: 0; border-bottom: 1px solid #e3e7ed; border-radius: 0; color: inherit; text-align: left; }
    .inboxItem.read { opacity: .62; }
    .inboxItemCopy { min-width: 0; }
    .inboxItemCopy strong, .inboxItemCopy small { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .inboxItemCopy strong { font-size: 13px; }
    .inboxItemCopy small { margin-top: 3px; color: #596070; font-size: 11px; }
    .inboxState { color: #596070; font-size: 10px; white-space: nowrap; }
    .subagentItem { border-bottom: 1px solid #e3e7ed; }
    .subagentItem summary { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 8px; padding: 12px 2px; cursor: pointer; list-style: none; }
    .subagentItem summary::-webkit-details-marker { display: none; }
    .subagentTitle { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 850; }
    .subagentStatus { color: #596070; font-size: 11px; }
    .subagentPreview { padding: 0 2px 10px; color: #596070; font-size: 12px; line-height: 1.45; white-space: pre-wrap; overflow-wrap: anywhere; }
    .subagentTurns { display: flex; flex-direction: column; gap: 6px; padding: 0 2px 12px; }
    .subagent-turn { padding: 8px; border-left: 2px solid #c8d1dc; font-size: 12px; line-height: 1.45; overflow-wrap: anywhere; }
    .status { font-size: 12px; color: #596070; min-height: 18px; }
    .toast { position: fixed; left: 50%; bottom: max(18px, env(safe-area-inset-bottom)); z-index: 20; display: none; width: max-content; max-width: calc(100vw - 32px); padding: 9px 12px; transform: translateX(-50%); border-radius: 8px; background: #17191f; color: #fff; font-size: 12px; box-shadow: 0 8px 24px rgb(0 0 0 / 24%); }
    .toast.show { display: block; }
    @media (prefers-color-scheme: dark) {
      :root { --st-run: #34c98e; --st-boot: #f0a132; --st-err: #e5484d; --st-stop: #5a5f6a; }
      body { background: #11151c; color: #f4f6f9; }
      header, select, textarea, input, button { background: #171d27; color: #f4f6f9; border-color: #303846; }
      label, p, .status { color: #a5adba; }
      .chatComposer { background: #171d27; border-color: #303846; }
      .attachBtn { background: #222c3a; color: #c4ccd8; border-color: #3a4453; }
      .attachChip { background: #1c2431; border-color: #343f4e; color: #c4ccd8; }
      .thinkingBubble { background: #171c24; border-color: #2b3340; color: #9aa5b4; }
      .questionCard { background: #16202e; border-color: #2c4a6b; }
      .questionText { color: #e8edf4; }
      .questionOpt { background: #1c2431; border-color: #3a4453; }
      .questionOptLabel { color: #e8edf4; }
      .questionBlock + .questionBlock { border-color: #2c4a6b; }
      .questionOpt.chosen { background: #1b3350; border-color: #4b8fe0; box-shadow: inset 0 0 0 1px #4b8fe0; }
      .questionFailed { background: #3a1c1c; color: #f0a3a3; }
      .questionBlocked { background: #1c2431; color: #a5adba; }
      .wt-flag.asking { background: #16233a; color: #7fb0ff; }
      .questionOpt:disabled { background: #161c26; }
      .galleryTab.active { background: #1c2431; color: #e8edf4; }
      .fileRow { background: #171d27; border-color: #303846; }
      .wtAction { color: #e8edf4; }
      .fileThumb, .fileIcon { background: #222c3a; }
      .fileBadge { background: #1e3a2a; color: #7fd6a2; }
      .fileBadge.edited { background: #222c3a; color: #a5adba; }
      .trimNotice { background: #3a2f16; color: #e8c78a; }
      #mobileApp[data-view="chat"] #listView { background: #11151c; border-color: #303846; }
      .mdCode { background: #141a23; border-color: #303846; }
      .mdCodeLang { border-color: #262e3a; color: #8b96a8; }
      .mdTableWrap, .mdHr { border-color: #303846; }
      .mdTable th, .mdTable td { border-color: #262e3a; }
      .mdTable th { background: #1c2431; }
      .mdQuote { border-color: #3a4453; color: #a5adba; }
      .mdH4, .mdH5, .mdH6 { color: #a5adba; }
      .turnImageBtn, .galleryCell { border-color: #343f4e; }
      .galleryCell { background: #1c2431; }
      .session-card { border-color: #303846; }
      .session-subtitle, .usageLabel { color: #a5adba; }
      .usagePanel { border-color: #303846; background: #171d27; }
      .usageSection + .usageSection { border-color: #303846; }
      .usageAccountLabel, .usageAccountValue { color: #e3e7ed; }
      .usageAccountReset, .usageUnavailable, .usageSectionTitle { color: #a5adba; }
      .usageValue { color: #e3e7ed; }
      .usageTrack, .usageAccountTrack { background: #303846; }
      .activityGroup { border-color: #303846; background: #171d27; }
      .activityGroup > summary { color: #b9c1ce; }
      .activityGroup[open] > summary, .activityItem { border-color: #303846; }
      .activityItem > summary { color: #e3e7ed; }
      .turnMeta, .liveActionMeta { color: #a5adba; }
      .pendingActionBtn { background: #1c2431; border-color: #3a4453; color: #c4ccd8; }
      .pendingActionBtn[data-pending-cancel] { border-color: #5a3535; color: #e39a9a; }
      .liveAction { color: #e3e7ed; }
      .session-preview { color: #d6dbe4; }
      .iconBtn { color: #d6dbe4; }
      .project-chip { color: #a5adba; }
      .project-chip.active { background: #f4f6f9; border-color: #f4f6f9; color: #17191f; }
      .source-tabs { background: #0d1117; }
      .source-tab { color: #a5adba; }
      .source-tab.active { background: #283142; color: #f4f6f9; box-shadow: none; }
      .source-badge { background: #2b3443; color: #c4cad4; }
      .source-badge.codex { background: #173d2a; color: #8ed1a8; }
      .source-badge.claude { background: #4b2b1e; color: #ffc09f; }
      .turn { background: #202838; }
      .turn.user { background: #182f4f; }
      .turn.output { background: #080c12; }
      .turn a, .subagent-turn a { color: #78aaff; }
      .newMessagesBtn, .suggestions, .bottomSheet, .inboxGroup, .sessionControlBtn { background: #171d27; border-color: #303846; }
      .suggestion + .suggestion, .sheetHeader, .subagentItem, .inboxItem, .serviceItem { border-color: #303846; }
      .suggestion-description, .suggestion-kind, .subagentStatus, .subagentPreview, .inboxItemCopy small, .inboxState { color: #a5adba; }
      button { color: #78aaff; }
      button.primary { background: #2f7eea; border-color: #2f7eea; color: white; }
    }
  </style>
</head>
<body>
  <section id="mobileLogin">
    <h2>Marina Mobile</h2>
    <p>처음 한 번만 mobile token으로 로그인하면 이 폰에 저장됩니다. 다음부터는 이 주소만 열면 됩니다.</p>
    <form id="loginForm">
      <label>Mobile token<input id="tokenInput" autocomplete="current-password" autocapitalize="none" spellcheck="false" /></label>
      <button class="primary" type="submit">로그인</button>
    </form>
    <div class="status" id="loginStatus"></div>
  </section>
  <div id="mobileApp">
    <header>
      <div class="shellRow">
        <button class="iconBtn backBtn" id="backBtn" type="button" title="세션 목록 열기/닫기" aria-label="세션 목록 열기/닫기" aria-expanded="false" style="display:none">&#9776;</button>
        <div class="chatNavTitle" id="chatNavTitle"></div>
        <div class="shellActions">
          <!-- 살아있음 표시. 폴링이 조용히 돌던 시절엔 화면이 멈춘 건지 알 길이 없었다
               (형: "폴링중인게 보이지도 않으니 멈춘 것 같고"). 점 하나로 연결 상태를 늘 보여준다. -->
          <span class="liveDot" id="liveDot" title="실시간 연결" aria-hidden="true"></span>
          <button class="usageBtn notifyBtn" id="notifyBtn" type="button" title="알림" aria-label="알림">&#128276;</button>
          <button class="usageBtn" id="galleryBtn" type="button" title="이미지 모아보기" aria-label="이미지 모아보기" style="display:none">&#9635;</button>
          <button class="usageBtn" id="usageBtn" type="button" title="토큰 사용량" aria-label="토큰 사용량"><span class="usageRing" id="usageRing"><span class="usageRingNum" id="usageRingNum"></span></span></button>
        </div>
      </div>
      <!-- 세션 탭 — shellRow 와 **별도 줄**이다(그 줄은 뒤로가기·제목·액션이 이미 꽉 찼다).
           헤더 안에 둬서 대화를 스크롤해도 붙어 있어야 "클릭 많이 안 하고 옮겨다니기"가 성립한다. -->
      <div class="sessionTabs" id="sessionTabs" role="tablist" aria-label="열린 세션"></div>
      <div class="usagePanel" id="usagePanel" aria-label="사용량" aria-hidden="true">
        <div class="usageSection">
          <div class="usageSectionTitle">계정 한도</div>
          <div class="usageAccountRows" id="usageAccountRows"><span class="usageUnavailable">확인 안 됨</span></div>
        </div>
        <div class="usageSection">
          <div class="usageSectionTitle">현재 세션 컨텍스트</div>
          <div class="usageMetrics">
          <div class="usageMetric"><span class="usageLabel">컨텍스트</span><span class="usageValue" id="usagePercent">-</span></div>
          <div class="usageMetric"><span class="usageLabel">사용</span><span class="usageValue" id="usageUsed">-</span></div>
          <div class="usageMetric"><span class="usageLabel">남음</span><span class="usageValue" id="usageRemaining">-</span></div>
        </div>
        <div class="usageTrack"><span class="usageFill" id="usageFill"></span></div>
      </div>
    </header>
    <main>
      <div class="drawerBackdrop" id="drawerBackdrop"></div>
      <section id="listView">
        <!-- 프로젝트/종류 탭은 목록 **안**에 둔다. 헤더에 두면 채팅 뷰에서 숨겨져서, 드로어를 열어도
             현재 프로젝트 세션만 보이고 다른 프로젝트로 갈 방법이 없었다(형 지적). -->
        <div class="project-strip" id="projectTabs" aria-label="프로젝트"></div>
        <div class="source-tabs" id="sourceTabs" aria-label="세션 종류"></div>
        <div class="listTools">
          <input class="search-input" id="sessionSearch" aria-label="세션 검색" placeholder="세션 검색" />
          <button class="iconBtn listToolBtn" id="densityBtn" type="button">&#9776;</button>
          <button class="iconBtn listToolBtn" id="showAllBtn" type="button" title="전체보기(오래된·숨긴·접은 것 포함)" aria-label="전체보기">&#8943;</button>
          <button class="listToolBtn newWtBtn" id="newWorktreeBtn" type="button" title="새 일감 만들기" aria-label="새 일감 만들기">＋ 새 일감</button>
        </div>
        <!-- 방 목록이 첫 화면이다(형 결정 2026-08-18). 세션 목록은 지우지 않고 숨겨만 둔다 —
             방 화면이 이상하면 한 줄로 되돌릴 수 있어야 한다. -->
        <!-- 받은 작업·새로고침·로그아웃은 **전역** 동작인데 서비스 시트(워크트리별) 안에만
             있었다. 세션 목록이 진짜로 숨겨지자 시트로 가는 길이 끊겨 통째로 도달 불가가 됐다 —
             펀넬로 공개되는 화면에 로그아웃이 없는 건 특히 곤란하다. 목록 화면으로 꺼낸다. -->
        <div class="listUtilities">
          <button id="inboxMenuBtn" type="button">받은 작업 <span id="inboxCount">0</span></button>
          <button id="refreshBtn" type="button">새로고침</button>
          <button id="clearUploadsBtn" type="button" data-clear-uploads="1">사진 정리</button>
          <button id="logoutBtn" type="button">로그아웃</button>
        </div>
        <div class="room-open" id="roomOpen" hidden></div>
        <div class="room-list" id="roomList"></div>
        <div class="session-list" id="sessionList"></div>
      </section>
      <section id="chatView">
        <label class="hiddenSelect">워크트리<select id="rootSelect"></select></label>
        <label class="hiddenSelect">대상<select id="targetSelect"></select></label>
        <div class="historyStatus" id="historyStatus" aria-live="polite"></div>
        <div class="trimNotice" id="trimNotice"></div>
        <div class="turns" id="turns"></div>
        <!-- 답이 나올 자리에서 도는 표시. 대화 목록의 형제로 둔다 — 목록 안에 넣으면
             재조정기가 모르는 자식이라 렌더마다 지워진다. -->
        <div id="thinkingSlot" hidden></div>
        <!-- 완료 카드 — 일이 끝나면 여기 떨어진다(스펙 §3). 대화와 입력창 사이라 눈에 걸린다. -->
        <div id="doneSlot" hidden></div>
        <button class="newMessagesBtn" id="newMessagesBtn" type="button">새 메시지</button>
    <button class="updateBanner" id="updateBanner" type="button">새 버전 · 탭하여 새로고침</button>
    <button class="cliUpdateBanner" id="cliUpdateBanner" type="button" hidden></button>
    <!-- 홈 화면에 추가하면 주소창이 사라지고 알림도 켤 수 있다. 둘 다 그 한 번의 설치에 걸려
         있는데 방법을 모르면 영영 못 쓴다 — 한 번만 알려주고 닫으면 다시 안 띄운다. -->
    <div class="installHint" id="installHint" hidden>
      <span>홈 화면에 추가하면 주소창이 사라지고 알림도 받을 수 있어요 &nbsp;·&nbsp; 공유 <b>&#8593;</b> → “홈 화면에 추가”</span>
      <button class="installHintClose" id="installHintClose" type="button" aria-label="닫기">&times;</button>
    </div>
      </section>
    </main>
    <div class="chatComposer" id="chatComposer" style="display:none">
      <div class="liveQuestion" id="liveQuestion"></div>
      <div class="sessionControls">
        <button class="sessionControlBtn" id="settingsBtn" type="button">모델 · 기본값</button>
        <button class="sessionControlBtn" id="subagentSessionBtn" type="button" style="display:none">서브에이전트 <span id="subagentCount">0</span></button>
        <div class="status" id="status" aria-live="polite"></div>
        <button class="stopBtn" id="stopBtn" type="button" title="현재 응답 중단" aria-label="현재 응답 중단">&#9632;</button>
      </div>
      <div class="suggestions" id="suggestions" role="listbox"></div>
      <div class="attachStrip" id="attachStrip"></div>
      <div class="composerRow">
        <button class="attachBtn" id="attachBtn" type="button" title="파일 첨부" aria-label="파일 첨부">&#128206;</button>
        <textarea id="prompt" rows="1" placeholder="메시지 (엔터=줄바꿈, ↑ 로 전송)" enterkeyhint="enter"></textarea>
        <button class="primary sendBtn" id="sendBtn" type="button" title="보내기" aria-label="보내기">&#8593;</button>
        <input type="file" id="fileInput" multiple accept="image/*,.pdf,.txt,.md,.log,.json,.csv" style="display:none" />
      </div>
      <div class="composerMeta"><button class="retryBtn" id="retryBtn" type="button">다시 보내기</button></div>
    </div>
    <div class="sheetBackdrop" id="subagentSheet" aria-hidden="true">
      <section class="bottomSheet" role="dialog" aria-modal="true" aria-labelledby="subagentSheetTitle">
        <div class="sheetHeader"><strong id="subagentSheetTitle">서브에이전트</strong><button class="iconBtn sheetClose" id="subagentCloseBtn" type="button" title="닫기" aria-label="닫기">&#215;</button></div>
        <div class="subagentList" id="subagentList"></div>
      </section>
    </div>
    <div class="sheetBackdrop" id="inboxSheet" aria-hidden="true">
      <section class="bottomSheet" role="dialog" aria-modal="true" aria-labelledby="inboxSheetTitle">
        <div class="sheetHeader"><strong id="inboxSheetTitle">받은 작업</strong><button class="iconBtn sheetClose" id="inboxCloseBtn" type="button" title="닫기" aria-label="닫기">&#215;</button></div>
        <div class="inboxList" id="inboxList"></div>
      </section>
    </div>
    <div class="sheetBackdrop" id="servicesSheet" aria-hidden="true">
      <section class="bottomSheet" role="dialog" aria-modal="true" aria-labelledby="servicesSheetTitle">
        <div class="sheetHeader"><strong id="servicesSheetTitle">서비스</strong><button class="iconBtn sheetClose" id="servicesCloseBtn" type="button" title="닫기" aria-label="닫기">&#215;</button></div>
        <div class="serviceList"><div id="serviceList"></div></div>
      </section>
    </div>
    <!-- 로그·깃 (읽기 전용) — 밖에서 "빌드 깨졌나"를 확인하는 용도. 쓰기는 일부러 없다. -->
    <div class="sheetBackdrop" id="logsSheet" aria-hidden="true">
      <section class="bottomSheet" role="dialog" aria-modal="true" aria-labelledby="logsSheetTitle">
        <div class="sheetHeader"><strong id="logsSheetTitle">로그</strong><button class="iconBtn sheetClose" id="logsCloseBtn" type="button" title="닫기" aria-label="닫기">&#215;</button></div>
        <div class="sheetTools">
          <select id="logsService" aria-label="서비스"></select>
          <select id="logsRun" aria-label="run"></select>
          <input id="logsFilter" type="search" placeholder="필터" enterkeyhint="search" autocomplete="off" />
          <button id="logsErrOnly" type="button">에러만</button>
        </div>
        <div class="logsBody" id="logsBody"></div>
      </section>
    </div>
    <div class="sheetBackdrop" id="gitSheet" aria-hidden="true">
      <section class="bottomSheet" role="dialog" aria-modal="true" aria-labelledby="gitSheetTitle">
        <div class="sheetHeader"><strong id="gitSheetTitle">깃</strong><button class="iconBtn sheetClose" id="gitCloseBtn" type="button" title="닫기" aria-label="닫기">&#215;</button></div>
        <div class="gitStatus" id="gitStatus"></div>
        <div class="gitBody" id="gitBody"></div>
      </section>
    </div>
    <div class="sheetBackdrop" id="settingsSheet" aria-hidden="true">
      <section class="bottomSheet" role="dialog" aria-modal="true" aria-labelledby="settingsSheetTitle">
        <div class="sheetHeader"><strong id="settingsSheetTitle">세션 설정</strong><button class="iconBtn sheetClose" id="settingsCloseBtn" type="button" title="닫기" aria-label="닫기">&#215;</button></div>
        <form class="settingsBody" id="settingsForm">
          <label>모델<select id="modelSelect"></select></label>
          <label id="customModelLabel" style="display:none">모델 이름<input id="customModelInput" autocomplete="off" autocapitalize="none" spellcheck="false" /></label>
          <label>에포트<select id="effortSelect"></select></label>
          <button class="primary" type="submit">적용</button>
        </form>
      </section>
    </div>
    <div class="sheetBackdrop" id="worktreeSheet" aria-hidden="true">
      <section class="bottomSheet" role="dialog" aria-modal="true" aria-labelledby="worktreeSheetTitle">
        <div class="sheetHeader"><strong id="worktreeSheetTitle">워크트리</strong><button class="iconBtn sheetClose" id="worktreeCloseBtn" type="button" title="닫기" aria-label="닫기">&#215;</button></div>
        <div class="wtActions" id="worktreeActions"></div>
      </section>
    </div>
    <div class="sheetBackdrop" id="gallerySheet" aria-hidden="true">
      <section class="bottomSheet" role="dialog" aria-modal="true" aria-labelledby="gallerySheetTitle">
        <div class="sheetHeader"><strong id="gallerySheetTitle">모아보기</strong><button class="iconBtn sheetClose" id="galleryCloseBtn" type="button" title="닫기" aria-label="닫기">&#215;</button></div>
        <div class="galleryTabs" role="tablist">
          <button class="galleryTab active" type="button" data-gallery-tab="images" role="tab">대화 이미지</button>
          <button class="galleryTab" type="button" data-gallery-tab="files" role="tab">만든 파일</button>
        </div>
        <div class="galleryBody"><div class="galleryStatus" id="galleryStatus">불러오는 중...</div><div class="galleryGrid" id="galleryGrid"></div><div class="fileList" id="galleryFiles"></div></div>
      </section>
    </div>
    <div class="imageViewer" id="imageViewer" aria-hidden="true">
      <div class="viewerBar" id="viewerBar"><span class="viewerName" id="viewerName"></span><span class="viewerCount" id="viewerCount"></span><button class="imageViewerClose" id="imageViewerClose" type="button" aria-label="닫기">&#215;</button></div>
      <img id="imageViewerImg" alt="" />
      <pre class="viewerText" id="viewerText"></pre>
      <div class="viewerDead" id="viewerDead"></div>
      <button class="viewerNav prev" id="viewerPrev" type="button" aria-label="이전">&#8249;</button>
      <button class="viewerNav next" id="viewerNext" type="button" aria-label="다음">&#8250;</button>
    </div>
    <div class="toast" id="toast" role="status" aria-live="polite"></div>
  </div>
  <!-- 타임라인 렌더러 — 웹 대시보드와 공유한다. /web/ 은 PUBLIC_PREFIXES 라 auth 가 켜져도,
       펀넬 호스트에서도(host_guarded 는 /api/ 만 본다) 받아진다. no-store 라 stale 도 없다. -->
  <script src="/web/chat-render.js"></script>
  <script>
    const cookieAuth = __MARINA_AUTH_ENABLED__;
    const urlToken = new URL(location.href).searchParams.get("token");
    if (urlToken && !cookieAuth) {
      localStorage.setItem("marinaMobileToken", urlToken);
      history.replaceState(null, "", location.pathname);
    }
    const token = () => localStorage.getItem("marinaMobileToken") || "";
    const cookie = (name) => {
      const prefix = `${encodeURIComponent(name)}=`;
      const item = String(document.cookie || "").split(";").map(value => value.trim()).find(value => value.startsWith(prefix));
      return item ? decodeURIComponent(item.slice(prefix.length)) : "";
    };
    const headers = (json=false) => ({
      ...(json ? {"content-type":"application/json"} : {}),
      ...(!cookieAuth ? {"x-marina-mobile-token": token()} : {}),
      ...(cookieAuth && json ? {"x-marina-csrf": cookie("marina_csrf")} : {}),
    });
    async function responseError(response) {
      const raw = await response.text();
      try {
        const payload = JSON.parse(raw);
        return String(payload.message || payload.error || raw || `HTTP ${response.status}`);
      } catch (_) {
        return raw || `HTTP ${response.status}`;
      }
    }
    const catalogEndpoint = "/mobile/api/catalog";
    const usageEndpoint = "/mobile/api/usage";
    const login = document.getElementById("mobileLogin");
    const app = document.getElementById("mobileApp");
    const loginStatus = document.getElementById("loginStatus");
    const listView = document.getElementById("listView");
    const chatView = document.getElementById("chatView");
    const chatComposer = document.getElementById("chatComposer");
    const backBtn = document.getElementById("backBtn");
    const drawerBackdrop = document.getElementById("drawerBackdrop");
    const chatNavTitle = document.getElementById("chatNavTitle");
    const usageBtn = document.getElementById("usageBtn");
    const usageRing = document.getElementById("usageRing");
    const usageRingNum = document.getElementById("usageRingNum");
    const usagePanel = document.getElementById("usagePanel");
    const usagePercent = document.getElementById("usagePercent");
    const usageUsed = document.getElementById("usageUsed");
    const usageRemaining = document.getElementById("usageRemaining");
    const usageFill = document.getElementById("usageFill");
    const usageAccountRows = document.getElementById("usageAccountRows");
    const rootSelect = document.getElementById("rootSelect");
    const targetSelect = document.getElementById("targetSelect");
    const promptInput = document.getElementById("prompt");
    const sessionSearch = document.getElementById("sessionSearch");
    const sessionList = document.getElementById("sessionList");
    const roomList = document.getElementById("roomList");
    const roomOpen = document.getElementById("roomOpen");
    const projectTabs = document.getElementById("projectTabs");
    const sourceTabs = document.getElementById("sourceTabs");
    const turnsEl = document.getElementById("turns");
    const historyStatus = document.getElementById("historyStatus");
    const trimNotice = document.getElementById("trimNotice");
    const suggestionsEl = document.getElementById("suggestions");
    const newMessagesBtn = document.getElementById("newMessagesBtn");
    const updateBanner = document.getElementById("updateBanner");
    updateBanner.onclick = () => location.reload();
    const liveQuestionEl = document.getElementById("liveQuestion");
    const sessionTabsEl = document.getElementById("sessionTabs");
    // 라이브 질문 카드의 로컬 상태. **카드를 낙관적으로 지우지 않는다** — 예전엔 탭하자마자 innerHTML 을
    // 비우고 4초간 숨겼는데, 응답이 안 먹으면 카드가 그냥 사라져 "눌렀는데 아무 일도 안 남"으로 보였고
    // 되돌릴 방법도 없었다. 이제 카드는 서버 진실(pendingQuestion 소멸)로만 사라진다.
    let liveAnswer = {token: "", total: 0, choices: [], sending: false, failed: false,
                      otherOpen: false, otherText: ""};
    let liveQuestionPending = "";   // 입력 중이라 미뤄둔 카드 HTML(포커스 빠질 때 반영)
    // 라이브 카드와 대화 안 폴백 카드가 **같은 상태**를 쓴다. 폴백에 별도 구현을 두면(예전처럼
    // 탭 즉시 전송) multiSelect 가 깨지고, 막아버리면 라이브 카드가 만료된 뒤 답할 방법이 사라진다.
    // ANSWER_STATE_START  (테스트가 이 블록을 vm 에 싣는다)
    function ensureAnswerState(questions, token) {
      if (token !== liveAnswer.token) {          // 새 질문 — 이전 선택/입력/실패 표시를 물려주지 않는다
        // otherOpen/otherText 는 **질문별** 맵이다({qi: ...}) — 폼 전체에 하나면 질문이 여럿일 때
        // 어느 질문의 기타인지 못 담는다. 그 한계 때문에 예전엔 기타를 통째로 숨겼었다.
        liveAnswer = {token, total: questions.length, questions, choices: [],
                      sending: false, failed: false, submitted: false, submittedAt: 0,
                      otherOpen: {}, otherText: {}};
      }
      liveAnswer.total = questions.length;
      liveAnswer.questions = questions;
      return liveAnswer;
    }
    // 보낸 뒤에도 카드를 잠가둔다 — 서버가 그 질문을 내리기까지의 틈에 한 번 더 눌리면 같은 질문에
    // 두 번 답한다(형: "답 보낸거 바로 안사라져서 또 보낼 뻔 했다"). 실패면 잠그지 않는다.
    function markAnswerSubmitted(ok, now) {
      liveAnswer.sending = false;
      liveAnswer.submitted = Boolean(ok);
      liveAnswer.submittedAt = ok ? now : 0;
      liveAnswer.failed = !ok;
    }
    // 다만 **영원히** 잠그지는 않는다. 응답이 삼켜졌는데 카드가 잠긴 채면 답할 길이 사라진다.
    const ANSWER_LOCK_MS = 15000;
    function answerLockExpired(state, now) {
      return Boolean(state && state.submitted) && now - (state.submittedAt || 0) > ANSWER_LOCK_MS;
    }
    // ANSWER_STATE_END
    // 카드 어디서 눌렸든 같은 규칙으로 선택을 반영한다.
    function pickAnswerOption(qi, index) {
      const question = (liveAnswer.questions || [])[qi] || {};
      const current = Array.isArray(liveAnswer.choices[qi]) ? liveAnswer.choices[qi] : [];
      if (question.multiSelect) {
        liveAnswer.choices[qi] = current.includes(index)
          ? current.filter(value => value !== index)
          : [...current, index].sort((a, b) => a - b);
      } else {
        liveAnswer.choices[qi] = [index];
      }
      liveAnswer.failed = false;
      // 질문 하나 + 단일선택이면 바로 보낸다. 그 외엔 다 고른 뒤 "보내기".
      return liveAnswer.total <= 1 && !(liveAnswer.questions || []).some(q => q && q.multiSelect);
    }
    // pending AskUserQuestion(훅이 잡은 라이브 소스)을 입력창 위에 카드로. 트랜스크립트엔 답 전까지 없으므로 이게 유일한 라이브 표시.
    function renderLiveQuestion(session) {
      const pq = session && session.pendingQuestion;
      if (!pq || !Array.isArray(pq.questions) || !pq.questions.length) {
        if (liveQuestionEl.innerHTML) liveQuestionEl.innerHTML = "";
        liveAnswer = {token: "", total: 0, choices: [], sending: false, failed: false,
                      otherOpen: {}, otherText: {}};
        return;
      }
      ensureAnswerState(pq.questions, String(pq.token || pq.toolUseId || ""));
      if (answerLockExpired(liveAnswer, Date.now())) {
        // 보냈는데 서버가 계속 이 질문을 들고 있다 = 반영이 안 됐다. 잠금을 풀고 사실대로 말한다.
        liveAnswer.submitted = false;
        liveAnswer.submittedAt = 0;
        liveAnswer.failed = true;
      }
      // PTY 를 쥐고 있지 않아도 고를 수 있다 — 서버가 세션을 이어받아(--resume) 고른 내용을 글로 전달한다.
      // 전송은 원래 그렇게 뚫고 있었는데 응답만 막아둘 이유가 없다(형 지적).
      const canAnswer = session.kind === "agent" && sessionSource(session) === "claude";
      liveAnswer.reason = canAnswer ? ""
        : sessionSource(session) !== "claude" ? "Claude 세션만 여기서 답할 수 있어요"
        : "에이전트 세션이 아니에요";
      // 셀렉터가 살아 있지 않으면 선택이 '키 입력'이 아니라 '이어받아 글로 전달'이 된다 — 미리 알린다.
      liveAnswer.viaResume = canAnswer && !session.controllable;
      const item = {name: "AskUserQuestion", detail: JSON.stringify({questions: pq.questions})};
      const html = renderQuestionCard(item, canAnswer, liveAnswer);
      // 형이 **입력창에 타이핑 중**일 때만 DOM 교체를 미룬다(캐럿/값 보호). 버튼 포커스까지 막으면
      // 옵션을 눌러도 화면이 안 갈려 선택이 0/1 로 남는다 — 데스크톱은 클릭한 버튼이 activeElement 다.
      const active = document.activeElement;
      const typing = active && liveQuestionEl.contains(active)
        && (active.tagName === "INPUT" || active.tagName === "TEXTAREA");
      if (typing) {
        liveQuestionPending = html;
        return;
      }
      liveQuestionPending = "";
      if (liveQuestionEl.innerHTML !== html) liveQuestionEl.innerHTML = html;
    }
    // 닫기(✕)를 탭 전환보다 먼저 본다 — ✕ 는 탭 안에 있어서 순서가 뒤집히면 닫으려다 전환된다.
    sessionTabsEl.addEventListener("click", event => {
      const x = event.target.closest && event.target.closest("[data-tab-close]");
      if (x) { event.stopPropagation(); closeTab(x.getAttribute("data-tab-close")); return; }
      const tab = event.target.closest && event.target.closest("[data-tab-key]");
      if (tab) chooseSession(tab.getAttribute("data-tab-key"));
    });
    function repaintLiveQuestion() { renderLiveQuestion(selectedSession()); }
    // 폴백 카드는 대화 안에 있어 turns 를 다시 그려야 반영된다(렌더키가 liveAnswer 를 모르므로 강제).
    function repaintTurns() { turnsStructureKey = ""; renderTurns(selectedSession()); }
    async function submitLiveAnswer(payload) {
      if (liveAnswer.sending || liveAnswer.submitted) return;
      // **누르는 즉시** 보낸 것으로 잠근다. 예전엔 서버 확인(최대 3.5초)을 기다린 뒤에야 카드가
      // 바뀌어서, 그 사이 화면이 반응 없는 것처럼 보였다(형: "대화창에서 바로 안사라지는 느낌이
      // 없게끔"). 확인은 뒤에서 하고, **실패했을 때만** 되돌린다.
      markAnswerSubmitted(true, Date.now());
      repaintLiveQuestion();
      const body = payload || {answers: Array.from({length: liveAnswer.total}, (_, i) => liveAnswer.choices[i] || [])};
      const result = await answerQuestion(body);
      // settled === false → 상태파일이 그대로다 = 셀렉터가 안 움직였다. 카드를 되살려 다시 누르게 한다.
      if (!result || result.settled === false) {
        markAnswerSubmitted(false, Date.now());
        repaintLiveQuestion();
      }
      load({quiet: true}).catch(() => {});
    }
    liveQuestionEl.addEventListener("click", event => {
      const opt = event.target.closest && event.target.closest("[data-answer-option]");
      if (opt) {
        const index = parseInt(opt.getAttribute("data-answer-option"), 10);
        if (Number.isNaN(index)) return;
        const rawQ = parseInt(opt.getAttribute("data-answer-q") || "0", 10);
        if (pickAnswerOption(Number.isNaN(rawQ) ? 0 : rawQ, index)) submitLiveAnswer({answers: [[index]]});
        else repaintLiveQuestion();     // 다 고른 뒤 "보내기"로 한 번에
        return;
      }
      if (event.target.closest && event.target.closest("[data-answer-submit]")) {
        const chosen = Array.from({length: liveAnswer.total}, (_, i) => liveAnswer.choices[i] || []);
        if (chosen.every(list => list.length)) submitLiveAnswer();
        return;
      }
      const otherBtn = event.target.closest && event.target.closest("[data-answer-other]");
      if (otherBtn) {
        liveAnswer.otherOpen[answerQIndex(otherBtn)] = true;   // 상태로 열어서 템플릿이 그린다(imperative style 금지)
        repaintLiveQuestion();
        const input = liveQuestionEl.querySelector("[data-answer-other-input]");
        if (input) input.focus();
        return;
      }
      const otherSend = event.target.closest && event.target.closest("[data-answer-other-send]");
      if (otherSend) {
        sendLiveOther(answerQIndex(otherSend));
        return;
      }
    });
    // data-answer-q 를 숫자로. 없거나 깨졌으면 0번 질문으로 본다(질문 하나짜리가 대부분).
    function answerQIndex(el) {
      const raw = parseInt((el && el.getAttribute("data-answer-q")) || "0", 10);
      return Number.isNaN(raw) ? 0 : raw;
    }
    function sendLiveOther(qi) {
      const input = liveQuestionEl.querySelector(`[data-answer-other-input][data-answer-q="${qi}"]`)
        || liveQuestionEl.querySelector("[data-answer-other-input]");
      const text = (input ? input.value : liveAnswer.otherText[qi] || "").trim();
      if (!text) { if (input) input.focus(); return; }
      liveAnswer.otherText[qi] = text;
      // 지금 서버 계약은 자유입력을 **폼 단위 텍스트 하나**로만 받는다(_parse_answers 는 정수 배열만).
      // 그래서 여기서 질문별로 섞어 보내는 형식을 지어내면 서버가 못 읽는다 — 질문별 기타 혼합은
      // 서버 계약을 넓힌 뒤(2단계) 붙인다. 지금은 어느 질문에서 눌렀든 그 텍스트로 답한다.
      submitLiveAnswer({text});
    }
    // 입력값을 state 에 계속 보관 — 재렌더가 일어나도 값이 살아남는다.
    liveQuestionEl.addEventListener("input", event => {
      const input = event.target.closest && event.target.closest("[data-answer-other-input]");
      if (input) liveAnswer.otherText[answerQIndex(input)] = input.value;
    });
    liveQuestionEl.addEventListener("keydown", event => {
      const input = event.target.closest && event.target.closest("[data-answer-other-input]");
      if (!input || event.isComposing) return;
      if (event.key === "Enter") { event.preventDefault(); sendLiveOther(answerQIndex(input)); }
      else if (event.key === "Escape") { liveAnswer.otherOpen[answerQIndex(input)] = false; input.blur(); repaintLiveQuestion(); }
    });
    // 포커스가 카드에서 빠지면 미뤄둔 갱신을 반영한다.
    liveQuestionEl.addEventListener("focusout", () => {
      setTimeout(() => {
        if (liveQuestionEl.contains(document.activeElement)) return;   // 카드 안에서 이동한 것
        if (liveQuestionPending) repaintLiveQuestion();
      }, 0);
    });
    const galleryBtn = document.getElementById("galleryBtn");
    const densityBtn = document.getElementById("densityBtn");
    const newWorktreeBtn = document.getElementById("newWorktreeBtn");
    const showAllBtn = document.getElementById("showAllBtn");
    const gallerySheet = document.getElementById("gallerySheet");
    const galleryGrid = document.getElementById("galleryGrid");
    const galleryFiles = document.getElementById("galleryFiles");
    const galleryStatus = document.getElementById("galleryStatus");
    const galleryCloseBtn = document.getElementById("galleryCloseBtn");
    const imageViewer = document.getElementById("imageViewer");
    const imageViewerImg = document.getElementById("imageViewerImg");
    const viewerText = document.getElementById("viewerText");
    const viewerName = document.getElementById("viewerName");
    const viewerBar = document.getElementById("viewerBar");
    const imageViewerClose = document.getElementById("imageViewerClose");
    const retryBtn = document.getElementById("retryBtn");
    const sendBtn = document.getElementById("sendBtn");
    const subagentSessionBtn = document.getElementById("subagentSessionBtn");
    const subagentCount = document.getElementById("subagentCount");
    const subagentSheet = document.getElementById("subagentSheet");
    const subagentList = document.getElementById("subagentList");
    const inboxMenuBtn = document.getElementById("inboxMenuBtn");
    const inboxCount = document.getElementById("inboxCount");
    const inboxSheet = document.getElementById("inboxSheet");
    const inboxList = document.getElementById("inboxList");
    const statusEl = document.getElementById("status");
    const thinkingSlot = document.getElementById("thinkingSlot");   // chatView 는 위에서 이미 잡았다
    const doneSlot = document.getElementById("doneSlot");
    const servicesSheet = document.getElementById("servicesSheet");
    const serviceList = document.getElementById("serviceList");
    const servicesSheetTitle = document.getElementById("servicesSheetTitle");
    const worktreeSheet = document.getElementById("worktreeSheet");
    const worktreeSheetTitle = document.getElementById("worktreeSheetTitle");
    const worktreeActions = document.getElementById("worktreeActions");
    const settingsBtn = document.getElementById("settingsBtn");
    const settingsSheet = document.getElementById("settingsSheet");
    const settingsForm = document.getElementById("settingsForm");
    const modelSelect = document.getElementById("modelSelect");
    const customModelLabel = document.getElementById("customModelLabel");
    const customModelInput = document.getElementById("customModelInput");
    const effortSelect = document.getElementById("effortSelect");
    const stopBtn = document.getElementById("stopBtn");
    const toastEl = document.getElementById("toast");
    let state = {worktrees: [], terms: [], sessions: [], agentOptions: {}};
    let serverInstance = "";   // 데몬 프로세스 식별자 — 바뀌면 재시작된 것 → 자동 새로고침
    let servicesState = {root: "", running: 0, defined: 0, services: []};
    // 폴링은 이제 **안전망**이다. 평소엔 서버가 변화를 밀어주고(SSE), 그게 끊긴 동안만 자주 돈다.
    // 터널·프록시가 스트림을 접는 환경이 실제로 있어서 폴링을 없애면 그런 데서 화면이 통째로 멈춘다.
    const POLL_LIVE_MS = 15000;    // 밀어주기가 살아 있음 — 어긋남만 가끔 맞춘다
    const POLL_FALLBACK_MS = 3000; // 밀어주기가 끊김 — 예전처럼
    let autoPollMs = POLL_FALLBACK_MS;
    let loading = false;
    let sending = false;
    let optimisticWorkUntil = 0;   // send 직후 폴이 working 잡을 때까지 낙관적으로 '작업 중'+정지버튼 표시(가만있는 느낌 방지)
    let lastActivity = "";
    let sawActivity = false;
    let selectedSessionKey = localStorage.getItem("marinaMobileSession") || "";
    let selectedProjectId = localStorage.getItem("marinaMobileProject") || "";
    let sourceFilter = localStorage.getItem("marinaMobileSource") || "all";
    let pinnedRoots = new Set();
    let hiddenSessions = new Set();   // "source:sid" — 서버 저장
    let showAll = false;
    let servicesRoot = "";            // 서비스 시트가 지금 보여주는 워크트리(전역 root 가 아니다)              // 전체보기: 7일 넘은 세션 + 숨긴 세션까지   // 서버 저장(핀) — 폰에서 꽂은 게 웹에도 보여야 한다
    let listDensity = localStorage.getItem("marinaMobileDensity") === "detail" ? "detail" : "simple";
    let turnsStructureKey = "";
    let activeDraftKey = "";
    let failedSend = null;
    let suggestionRange = null;
    let fileSuggestionTimer = 0;
    let fileSuggestionKey = "";
    let fileSuggestions = [];
    let serviceLoading = false;
    let serviceLoadedAt = 0;
    let followLatest = true;
    let suppressScrollTracking = false;
    let exitArmedUntil = 0;
    let toastTimer = 0;
    const inboxReadKey = "marinaAgentInboxRead";
    let inboxRead;
    try {
      const value = JSON.parse(localStorage.getItem(inboxReadKey) || "[]");
      inboxRead = new Set(Array.isArray(value) ? value : []);
    } catch (_) { inboxRead = new Set(); }
    const pendingTurns = {};
    let pendingRecordSeq = 0;   // 대기 레코드 안정 id — 취소/재시도 대상 식별용(pendingTurns 배열 내에서 유일)
    const historyCache = {};
    const activityCache = {};
    const catalogCache = {};
    const usageCache = {};
    let historyLoading = false;
    const sourceMeta = {
      codex: {label: "Codex", badge: "CX"},
      claude: {label: "Claude", badge: "CC"},
      terminal: {label: "Terminal", badge: "TERM"},
    };
    // 웹 대시보드(app-1-core.js AGENT_STATUS_META)와 동일하게 통일 — 같은 상태를 같은 dot/라벨로.
    const AGENT_STATUS_META = {
      working:   {dot: "boot", label: "작업 중"},
      blocked:   {dot: "ask",  label: "응답 필요"},
      waiting:   {dot: "part", label: "응답 대기"},
      completed: {dot: "run",  label: "완료"},
      failed:    {dot: "bad",  label: "실패"},
      interrupted: {dot: "stop", label: "중단됨"},
      idle:      {dot: "stop", label: "유휴"},
    };
    function agentStatusMeta(status) { return AGENT_STATUS_META[status] || AGENT_STATUS_META.idle; }

    // STATUS_REASON_START  (테스트가 이 블록을 확인한다)
    // "실패" 만으로는 형이 뭘 해야 할지 알 수 없다. 잠깐 먹통(CLI 가 알아서 재시도한다)과
    // 손을 대야 낫는 것(로그인 만료·한도 소진)은 조치가 완전히 다르다 — 후자는 그냥 두면
    // 영영 안 풀리는데 화면엔 똑같이 "실패"로만 보였다(형: 왜 안 되는지 알 수가 없다).
    const STATUS_REASON_TEXT = {
      needs_login: "클로드 로그인이 풀렸어요",
      needs_credit: "클로드 사용 한도에 걸렸어요",
    };
    function statusReasonText(reason) { return STATUS_REASON_TEXT[String(reason || "")] || ""; }
    // STATUS_REASON_END
    // 이 상태들은 압축 모드에서도 **글자로** 보여준다 — 점 색만으론 놓친다.
    const NOTABLE_STATUS = new Set(["blocked", "working", "failed"]);
    function showLogin(message="") {
      app.style.display = "none";
      login.style.display = "flex";
      loginStatus.textContent = message;
    }
    function showApp() {
      login.style.display = "none";
      app.style.display = "grid";
    }
    // listView 의 표시는 **CSS 가 data-view 로** 정한다 — 인라인 display 를 쓰면 채팅 뷰에서
    // 좌측 드로어로 띄우는 규칙을 인라인이 이겨버려서 패널이 영영 안 열린다.
    function showList() {
      app.setAttribute("data-view", "list");
      closeDrawer();
      chatView.style.display = "none";
      chatComposer.style.display = "none";
      backBtn.style.display = "none";
      galleryBtn.style.display = "none";
      closeUsagePanel();
      closeSubagents();
      closeInbox();
      closeGallery();
    }
    function showChat() {
      app.setAttribute("data-view", "chat");
      chatView.style.display = "grid";
      chatComposer.style.display = "flex";
      backBtn.style.display = "inline-block";
      // 이미지 모아보기는 에이전트 대화에만 의미가 있다(터미널 세션엔 트랜스크립트가 없음).
      galleryBtn.style.display = currentTargetValue().startsWith("agent:") ? "inline-block" : "none";
    }
    // DRAWER_START
    // 좌측 패널(세션 목록) — 채팅에서 목록 화면으로 나가지 않고 세션을 바로 갈아탄다.
    // 같은 #listView 를 재사용한다(렌더 경로 하나 유지): 목록 뷰에선 전체 화면, 채팅 뷰에선 오프캔버스 드로어.
    function drawerOpen() { return app.getAttribute("data-drawer") === "open"; }
    function openDrawer() {
      if (app.getAttribute("data-view") !== "chat") return;   // 목록 뷰는 이미 전체 화면이다
      app.setAttribute("data-drawer", "open");
      listView.removeAttribute("aria-hidden");
      backBtn.setAttribute("aria-expanded", "true");
    }
    function closeDrawer() {
      app.setAttribute("data-drawer", "closed");
      if (app.getAttribute("data-view") === "chat") listView.setAttribute("aria-hidden", "true");
      else listView.removeAttribute("aria-hidden");
      backBtn.setAttribute("aria-expanded", "false");
    }
    function toggleDrawer() { drawerOpen() ? closeDrawer() : openDrawer(); }
    // 엣지 스와이프 판정 — 순수 함수라 테스트가 쉽다. 왼쪽 가장자리에서 오른쪽으로 끌면 열고,
    // 열린 상태에서 왼쪽으로 끌면 닫는다. 세로 스크롤과 싸우지 않게 가로 이동이 세로보다 커야 한다.
    const DRAWER_EDGE_PX = 28;
    const DRAWER_TRIGGER_PX = 44;
    function drawerSwipeIntent(start, current, isOpen) {
      const dx = current.x - start.x;
      const dy = Math.abs(current.y - start.y);
      if (Math.abs(dx) < DRAWER_TRIGGER_PX || Math.abs(dx) <= dy) return null;
      if (!isOpen && start.x <= DRAWER_EDGE_PX && dx > 0) return "open";
      if (isOpen && dx < 0) return "close";
      return null;
    }
    // DRAWER_END
    function closeUsagePanel() {
      usagePanel.classList.remove("open");
      usagePanel.setAttribute("aria-hidden", "true");
      usageBtn.setAttribute("aria-expanded", "false");
    }
    function closeMenu() {}
    function closeSubagents() {
      subagentSheet.classList.remove("open");
      subagentSheet.setAttribute("aria-hidden", "true");
    }
    function closeInbox() {
      inboxSheet.classList.remove("open");
      inboxSheet.setAttribute("aria-hidden", "true");
    }
    function closeServices() {
      servicesSheet.classList.remove("open");
      servicesSheet.setAttribute("aria-hidden", "true");
    }
    function closeSettings() {
      settingsSheet.classList.remove("open");
      settingsSheet.setAttribute("aria-hidden", "true");
    }
    // 워크트리 작업 시트 — 헤더에 버튼을 늘어놓으면 340px 드로어가 답답하고 터치 목표도 작아진다(형 지적).
    // 시트로 접으면 라벨을 제대로 쓸 수 있어 "＋CC 가 워크트리 만들기인 줄" 같은 오해도 사라진다.
    function closeWorktreeSheet() {
      worktreeSheet.classList.remove("open");
      worktreeSheet.setAttribute("aria-hidden", "true");
    }
    function openWorktreeSheet(root) {
      if (!root) return;
      // 어떤 CLI 가 "쓸 수 있는지"를 알 방법이 없다. 이미 쓰는 쪽을 앞에 두는 것도 고려했지만,
      // 세션이 하나도 없는 워크트리에서 **처음 띄우는 경우**가 그 논리에 걸린다(형 지적).
      // 그래서 추측하지 않고 둘 다 고정 순서로 둔다.
      const sources = [{id: "claude", label: "Claude 대화 추가"}, {id: "codex", label: "Codex 대화 추가"}];
      const pinned = pinnedRoots.has(root);
      worktreeSheetTitle.textContent = wtName(root);
      worktreeActions.innerHTML = [
        `<button class="wtAction" type="button" data-wt-act="services">서버<span class="wtActionNote">보기 · 실행</span></button>`,
        `<button class="wtAction" type="button" data-wt-act="logs">로그<span class="wtActionNote">tail · 필터 · 에러만</span></button>`,
        `<button class="wtAction" type="button" data-wt-act="git">깃<span class="wtActionNote">변경 · diff · 커밋 목록</span></button>`,
        ...sources.map(item => `<button class="wtAction" type="button" data-wt-act="launch:${item.id}">${esc(item.label)}</button>`),
        `<button class="wtAction" type="button" data-wt-act="pin">${pinned ? "고정 해제" : "맨 위에 고정"}</button>`,
      ].join("");
      worktreeActions.dataset.root = root;
      closeDrawer();
      worktreeSheet.classList.add("open");
      worktreeSheet.setAttribute("aria-hidden", "false");
    }
    function closeGallery() {
      gallerySheet.classList.remove("open");
      gallerySheet.setAttribute("aria-hidden", "true");
    }
    // VIEWER_START
    // 앱 안 뷰어 — 이미지든 텍스트 파일이든 여기서 본다. 예전엔 이미지 아닌 파일을 window.open 으로
    // 새 탭에 띄웠는데, 모아보기 흐름이 끊기고 폰에선 탭이 쌓인다(형 지적).
    const VIEWER_TEXT_MAX = 200000;   // 뷰어가 멈추지 않게 표시 상한(서버는 8MB 까지 준다)
    function viewerOpen() { return imageViewer.classList.contains("open"); }
    // 뷰어는 **(목록, 위치)** 를 받는다. URL 하나만 받던 시절엔 앞뒤에 뭐가 있는지 몰라 넘길 수가
    // 없었다. 목록 출처는 둘: 모아보기(자기 배열) / 채팅(collectViewables — 그 대화 것만, A안).
    const viewerCount = document.getElementById("viewerCount");
    const viewerDead = document.getElementById("viewerDead");
    const viewerPrev = document.getElementById("viewerPrev");
    const viewerNext = document.getElementById("viewerNext");
    let viewerList = [];
    let viewerIdx = 0;
    let viewerSeq = 0;   // 느린 텍스트 로드가 늦게 도착해 이미 넘어간 화면을 덮지 않게

    function closeImageViewer() {
      imageViewer.classList.remove("open");
      imageViewer.setAttribute("aria-hidden", "true");
      imageViewerImg.removeAttribute("src");   // 큰 이미지를 붙잡고 있지 않게
      imageViewerImg.style.display = "none";
      viewerText.style.display = "none";
      viewerText.textContent = "";
      viewerDead.style.display = "none";
      viewerName.textContent = "";
      viewerCount.textContent = "";
      viewerList = [];
      viewerSeq += 1;
    }
    function showViewer(name) {
      viewerName.textContent = name || "";
      imageViewer.classList.add("open");
      imageViewer.setAttribute("aria-hidden", "false");
    }
    // 항목 → URL. image 는 트랜스크립트 안 그림(ref), file 은 세션이 만든 파일(path).
    function viewerUrlOf(item) {
      if (!item) return "";
      if (item.type === "raw") return item.url || "";
      return item.type === "image" ? transcriptImageUrl(item.ref) : sessionFileUrl(item.path);
    }
    function viewerIsImage(item) {
      return Boolean(item && (item.type === "image" || item.isImage
        || (item.path && IMAGE_EXT_RE.test(item.path))));
    }
    function openViewer(list, index) {
      viewerList = Array.isArray(list) ? list.filter(Boolean) : [];
      viewerIdx = Math.max(0, Math.min(Number(index) || 0, viewerList.length - 1));
      if (!viewerList.length) return;
      showViewer("");
      renderViewer();
    }
    async function renderViewer() {
      const item = viewerList[viewerIdx];
      const seq = ++viewerSeq;
      viewerName.textContent = item.name || "";
      viewerCount.textContent = viewerList.length > 1 ? `${viewerIdx + 1} / ${viewerList.length}` : "";
      viewerPrev.disabled = viewerIdx <= 0;
      viewerNext.disabled = viewerIdx >= viewerList.length - 1;
      viewerPrev.style.display = viewerNext.style.display = viewerList.length > 1 ? "block" : "none";
      imageViewerImg.style.display = "none";
      imageViewerImg.removeAttribute("src");
      viewerText.style.display = "none";
      viewerDead.style.display = "none";

      const url = viewerUrlOf(item);
      if (item.servable === false || !url) {
        // 목록에서 빼지 않는다 — 조용히 건너뛰면 n/N 개수가 어긋나 형이 헷갈린다.
        viewerDead.style.display = "block";
        viewerDead.textContent = "이 파일은 열 수 없어요 — 삭제됐거나 너무 큽니다";
        return;
      }
      if (viewerIsImage(item)) {
        imageViewerImg.style.display = "block";
        imageViewerImg.src = url;
        return;
      }
      viewerText.style.display = "block";
      viewerText.textContent = "불러오는 중...";
      try {
        const r = await fetch(url, {headers: headers()});
        if (!r.ok) throw new Error(await responseError(r));
        const body = await r.text();
        if (seq !== viewerSeq) return;   // 그 사이 넘어갔다 — 남의 화면을 덮지 않는다
        viewerText.textContent = body.length > VIEWER_TEXT_MAX
          ? `${body.slice(0, VIEWER_TEXT_MAX)}\n\n… 이하 생략 (${body.length.toLocaleString()}자 중 앞 ${VIEWER_TEXT_MAX.toLocaleString()}자)`
          : (body || "(빈 파일)");
      } catch (error) {
        if (seq !== viewerSeq) return;
        viewerText.textContent = `열기 실패 · ${String(error)}`;
      }
    }
    function stepViewer(delta) {
      const at = viewerIdx + delta;
      if (at < 0 || at >= viewerList.length) return;
      viewerIdx = at;
      renderViewer();
    }
    // 옛 호출부 호환 — 한 장짜리 목록으로 연다(호출처를 다 고치면 규칙이 두 벌이 된다).
    function openImageViewer(url, name) {
      if (!url) return;
      openViewer([{type: "raw", name, url, isImage: true}], 0);
    }
    function openTextViewer(url, name) {
      if (!url) return;
      openViewer([{type: "raw", name, url, isImage: false}], 0);
    }
    // VIEWER_END
    // 모아보기 두 축.
    //  ① 대화 이미지 — 트랜스크립트에 base64 로 박힌 그림(붙여넣기·Read 한 png·캡처).
    //  ② 만든 파일 — 에이전트가 Write/Edit 한 파일. 만들기만 한 파일은 내용이 트랜스크립트에 안 남아
    //     ①로는 절대 안 잡힌다(실측: 이 세션 Write2+Edit44 인데 대화 이미지는 0장). 근거는 도구 호출의 file_path.
    let galleryTab = "images";
    let galleryImageList = [];   // 뷰어가 좌우로 넘길 목록 — 모아보기에서 열면 세션 전체다
    let galleryFileList = [];
    function fileSizeLabel(bytes) {
      const n = Number(bytes) || 0;
      if (n < 1024) return `${n}B`;
      if (n < 1024 * 1024) return `${(n / 1024).toFixed(n < 10240 ? 1 : 0)}KB`;
      return `${(n / 1048576).toFixed(1)}MB`;
    }
    function sessionFileUrl(path) {
      const params = new URLSearchParams({root: sessionRoot(), path});
      if (!cookieAuth && token()) params.set("token", token());
      return `/mobile/api/session-file?${params}`;
    }
    function openGallery(tab) {
      const value = currentTargetValue();
      if (!selectedSession() || !value.startsWith("agent:")) { showToast("에이전트 세션에서만 볼 수 있어요"); return; }
      galleryTab = tab || galleryTab;
      gallerySheet.classList.add("open");
      gallerySheet.setAttribute("aria-hidden", "false");
      [...gallerySheet.querySelectorAll("[data-gallery-tab]")].forEach(btn =>
        btn.classList.toggle("active", btn.getAttribute("data-gallery-tab") === galleryTab));
      galleryGrid.innerHTML = "";
      galleryFiles.innerHTML = "";
      galleryStatus.textContent = "불러오는 중...";
      return galleryTab === "files" ? loadGalleryFiles(value) : loadGalleryImages(value);
    }
    async function loadGalleryImages(value) {
      const [, source, sid] = value.split(":");
      try {
        const params = new URLSearchParams({root: sessionRoot(), source, sid});
        const r = await fetch(`/mobile/api/images?${params}`, {headers: headers()});
        if (!r.ok) throw new Error(await responseError(r));
        const data = await r.json();
        const images = Array.isArray(data.images) ? data.images : [];
        galleryImageList = images.map(img => ({type: "image", ref: img.ref, name: img.name || "대화 이미지"}));
        if (!images.length) {
          galleryStatus.textContent = "이 대화엔 이미지가 없어요. 내가 만든 파일은 '만든 파일' 탭에 있어요.";
          return;
        }
        galleryStatus.textContent = images.length < (data.total || images.length)
          ? `이미지 ${images.length}장 (전체 ${data.total}장 중 최신순)` : `이미지 ${images.length}장`;
        galleryGrid.innerHTML = images.map(img => {
          const url = transcriptImageUrl(img.ref, value);
          return url ? `<button class="galleryCell" type="button" data-image-ref="${esc(img.ref)}"><img src="${esc(url)}" alt="" loading="lazy" /></button>` : "";
        }).join("");
      } catch (error) {
        galleryStatus.textContent = `불러오기 실패 · ${String(error)}`;
      }
    }
    async function loadGalleryFiles(value) {
      const [, source, sid] = value.split(":");
      try {
        const params = new URLSearchParams({root: sessionRoot(), source, sid});
        const r = await fetch(`/mobile/api/session-files?${params}`, {headers: headers()});
        if (!r.ok) throw new Error(await responseError(r));
        const data = await r.json();
        const files = Array.isArray(data.files) ? data.files : [];
        galleryFileList = files.map(f => ({type: "file", path: f.path, name: f.relPath,
                                           isImage: Boolean(f.isImage), servable: f.servable !== false}));
        if (!files.length) { galleryStatus.textContent = "이 세션이 만든/바꾼 파일이 없어요."; return; }
        galleryStatus.textContent = `파일 ${files.length}개 · 최근에 손댄 것부터`;
        galleryFiles.innerHTML = files.map(file => {
          const badge = file.action === "created" ? "새로 만듦" : "수정";
          const thumb = file.isImage && file.servable
            ? `<img class="fileThumb" src="${esc(sessionFileUrl(file.path))}" alt="" loading="lazy" />`
            : `<span class="fileIcon">${esc((file.name.split(".").pop() || "?").slice(0, 4).toUpperCase())}</span>`;
          const sub = file.exists
            ? `${fileSizeLabel(file.size)} · ${file.touches}번 손댐`
            : "지금은 없는 파일 (지워졌거나 옮겨졌어요)";
          const attrs = file.servable ? `data-file-path="${esc(file.path)}" data-file-name="${esc(file.relPath)}" data-file-image="${file.isImage ? "1" : ""}"` : "disabled";
          return `<button class="fileRow" type="button" ${attrs}>${thumb}<span class="fileMeta"><span class="fileName">${esc(file.relPath)}</span><span class="fileSub">${esc(sub)}</span></span><span class="fileBadge${file.action === "created" ? "" : " edited"}">${badge}</span></button>`;
        }).join("");
      } catch (error) {
        galleryStatus.textContent = `불러오기 실패 · ${String(error)}`;
      }
    }
    function showToast(message) {
      clearTimeout(toastTimer);
      toastEl.textContent = message;
      toastEl.classList.add("show");
      toastTimer = setTimeout(() => toastEl.classList.remove("show"), 1800);
    }
    function syncVisualViewport() {
      const viewport = window.visualViewport;
      const height = viewport ? viewport.height : window.innerHeight;
      app.style.setProperty("--app-height", `${Math.round(height)}px`);
    }
    syncVisualViewport();
    if (window.visualViewport) {
      window.visualViewport.addEventListener("resize", syncVisualViewport);
      window.visualViewport.addEventListener("scroll", syncVisualViewport);
    }
    window.addEventListener("resize", syncVisualViewport);
    async function logout() {
      localStorage.removeItem("marinaMobileToken");
      localStorage.removeItem("marinaMobileDraft");
      Object.keys(localStorage).filter(key => key.startsWith("marinaMobileDraft:")).forEach(key => localStorage.removeItem(key));
      state = {worktrees: [], terms: [], sessions: [], agentOptions: {}};
      rootSelect.innerHTML = "";
      targetSelect.innerHTML = "";
      promptInput.value = "";
      sessionList.innerHTML = "";
      turnsStructureKey = "";
      turnsEl.innerHTML = "";
      Object.keys(historyCache).forEach(key => delete historyCache[key]);
      Object.keys(activityCache).forEach(key => delete activityCache[key]);
      Object.keys(catalogCache).forEach(key => delete catalogCache[key]);
      Object.keys(usageCache).forEach(key => delete usageCache[key]);
      showList();
      if (cookieAuth) {
        try { await fetch("/api/auth/logout", {method: "POST", headers: headers(true), body: "{}"}); }
        finally { location.replace("/login?next=%2Fmobile"); }
        return;
      }
      showLogin("로그아웃했습니다.");
    }
    // 타임라인 렌더러는 /web/chat-render.js 에 있다 (웹 대시보드와 공유). 이름 그대로 꺼내 쓴다.
    const {
      esc, renderInlineMarkdown, renderRichText, mdTableCells, mdIsTableRow, mdIsTableDivider,
      mdListMarker, renderMarkdownBlocks, mdRenderList, renderActivityCode, sessionSource,
      pendingDeliveryLabel, renderThinking, runtimeLabel, mergeHistoryTurns, timelineFromTurns,
      mergeTimelineItems, exchangeSections, exchangeRuns, exchangeRuntime, renderTurnMeta,
      renderLiveAction, extractAttachments, renderTurnAttachments, renderTimelineImages,
      renderTimelineMessage, timelineDetailAttrs, activityItemKey, activityItemFingerprint,
      activityGroupSummary, progressLine, renderActivityItem, renderActivityGroup, reconcileActivityList,
      renderTimelineSequence, questionsFromActivity, pendingQuestionActivity,
      questionFallbackText, renderQuestionCard, renderAnsweredQuestion, renderConversationSequence, pendingKeyPart,
      timelineItemKeyParts, exchangeRenderKey,
      setDetailScope, noteDetailToggle, IMAGE_EXT_RE, collectViewables,
    } = window.MarinaChat;
    // 렌더러가 모르는 것만 넘긴다. URL 세 종류는 인증 방식이 웹과 달라서(토큰 쿼리), 질문 응답
    // 상태는 입력창 위 라이브 카드와 공유해야 해서, 모델 이름은 모바일 카탈로그를 봐야 해서.
    window.MarinaChat.configure({
      imageUrl: (ref) => transcriptImageUrl(ref),
      fileUrl: (path) => sessionFileUrl(path),
      uploadUrl: (nameOrPath) => uploadServeUrl(nameOrPath),
      ensureAnswerState: (questions, token) => ensureAnswerState(questions, token),
      displayModel: (model) => displayModel(model),
    });
    // ROOM_LIST_START  (테스트가 이 블록을 vm 에 싣는다)
    // 방 목록 — 폰을 열면 이게 첫 화면이다.
    //
    // 정렬이 **최근 순이 아니다.** 답을 기다리는 방이 목록 아래에 있으면 형은 그걸 놓치고,
    // 그동안 일은 멈춰 있다. 그래서 급한 것부터 올린다(스펙 §2).
    const ROOM_ORDER = ["문제", "응답필요", "작업중", "완료", "대기"];
    // 화면에 개발 용어를 쓰지 않는다(스펙 §3). 형이 읽고 바로 아는 말로만.
    const ROOM_LABEL = {
      "문제": "막혔어요", "응답필요": "답을 기다려요", "작업중": "일하는 중",
      "완료": "끝났어요", "대기": "쉬는 중",
    };
    const ROOM_ICON = {
      "문제": "!", "응답필요": "?", "작업중": "▶", "완료": "✓", "대기": "·",
    };

    function roomStatusLabel(status) {
      // 모르는 값에 빈 칸이 뜨면 고장으로 보인다 — 가장 순한 쪽으로 떨어뜨린다.
      return ROOM_LABEL[status] || ROOM_LABEL["대기"];
    }

    // withArchived 는 "전체보기"에서 켜진다. 접은 방을 다시 볼 길이 없으면 접는 순간
    // 잃어버린 것과 같다 — 접기는 치우는 것이지 버리는 게 아니다.
    function renderRooms(rooms, now, withArchived, query, projectId) {
      const q = String(query || "").trim().toLowerCase();
      const live = (rooms || []).filter(room => {
        if (!withArchived && room.archived) return false;
        // 프로젝트 칩·검색창은 화면에 그대로 보인다 — 방 목록에 안 먹으면 UI 가 거짓말을 한다
        // (칩이 개수를 광고하는데 눌러도 28개 그대로였다).
        if (projectId && String(room.projectId || "") !== projectId) return false;
        if (!q) return true;
        const 안 = [room.name, room.shortName, room.project, room.root]
          .concat((room.tabs || []).map(tab => tab.title));
        return 안.some(value => String(value || "").toLowerCase().includes(q));
      });
      if (!live.length) {
        return q || projectId
          ? '<div class="roomEmpty">찾는 게 없어요.</div>'
          : '<div class="roomEmpty">아직 방이 없어요.<br />새 일감을 만들면 여기 나와요.</div>';
      }
      // 모르는 상태는 **맨 뒤**다. indexOf 가 -1 이라 그냥 쓰면 문제 방보다 위로 올라간다 —
      // 라벨은 "쉬는 중"으로 떨어뜨리면서 정렬만 최상단이면 앞뒤가 안 맞는다.
      // 접어둔 방도 뒤로 보낸다. 치워둔 것이 첫 줄이 되면 접기의 뜻과 반대다.
      const rankOf = room => {
        const idx = ROOM_ORDER.indexOf(String(room.status || ""));
        return (room.archived ? 100 : 0) + (idx < 0 ? ROOM_ORDER.length : idx);
      };
      const sorted = live.slice().sort((a, b) => {
        const rank = rankOf(a) - rankOf(b);
        return rank !== 0 ? rank : (b.lastAt || 0) - (a.lastAt || 0);
      });
      return sorted.map(room => {
        const tabs = room.tabs || [];
        // 대화가 하나면 개수를 말하지 않는다 — 방=대화 묶음이라는 건 여럿일 때만 뜻이 있다.
        const count = tabs.length > 1 ? " · 대화 " + tabs.length + "개" : "";
        // 이름이 같은 방이 실제로 있다(실측: 'ZZe2e' 두 개). 프로젝트를 안 고른 동안에는
        // 그게 유일한 구별 단서라 부제에 넣는다.
        const where = (!projectId && room.project ? " · " + room.project : "")
                    + (room.archived ? " · 접어둠" : "");
        // 손대야 낫는 사유는 상태 대신 **그것부터** 말한다 — "쉬는 중"으로 보이면 형은
        // 기다리기만 하는데, 실제로는 형이 뭘 해야 풀리는 상태다.
        const 막힘 = statusReasonText(room.blockedReason);
        const status = String(room.status || "대기");
        // 카드 몸통을 누르면 바로 대화로, ⋯ 를 누르면 방 안(다른 대화·이름·접기)으로.
        // 버튼 안에 버튼을 넣을 수 없어 형제로 두고 줄로 감싼다.
        return `<div class="roomRow st-${esc(status)}${room.archived ? " archived" : ""}">
          <button class="roomCard" type="button" data-room="${esc(room.root)}">
            <span class="roomIcon">${esc(ROOM_ICON[status] || ROOM_ICON["대기"])}</span>
            <span class="roomBody">
              <span class="roomName">${esc(room.shortName || room.name || "")}</span>
              <span class="roomMeta">${esc(막힘 ? 막힘 + count : roomStatusLabel(status) + count + where)}</span>
            </span>
          </button>
          ${room.archived
            ? `<button class="roomMore" type="button" data-room-unarchive="${esc(room.root)}" title="다시 꺼내기" aria-label="다시 꺼내기">↑</button>`
            : `<button class="roomMore" type="button" data-room-more="${esc(room.root)}" aria-label="방 메뉴">⋯</button>`}
        </div>`;
      }).join("");
    }
    // ROOM_LIST_END

    // ROOM_TABS_START  (테스트가 이 블록을 vm 에 싣는다)
    // 방 안 — 대화들이 탭이다(스펙 §2). 탭을 고르면 기존 대화 화면이 그대로 열린다.
    //
    // 방을 여는 길이 둘인 이유: 방 대부분은 대화가 하나뿐이라(실측 28개 중 21개), 카드를
    // 누르면 바로 그 대화로 간다. 이름 고치기·접기·다른 대화는 ⋯ 로 이 패널을 열어서 한다.
    // 모두를 패널로 보내면 흔한 경우에 손가락이 한 번 더 든다.
    function renderRoomTabs(room, sources) {
      const tabs = room.tabs || [];
      // **새 대화를 시작할 길**이 여기 있어야 한다. 예전엔 세션 목록 안에만 있어서, 방 목록이
      // 첫 화면이 된 순간 대화가 하나도 없는 방(실측 28개 중 14개)이 막다른 길이 됐다 —
      // "대화를 시작해 보세요"라고 말해놓고 수단이 없었다.
      const 시작 = (sources || []).map(item =>
        `<button class="roomStart" type="button" data-room-launch="${esc(item.id)}">＋ ${esc(item.label)}</button>`
      ).join("");
      const head = `<div class="roomHead">
        <span class="roomOpenTitle">${esc(room.name || room.shortName || "")}</span>
        <button class="iconBtn" type="button" data-rename="${esc(room.root)}" title="이름 바꾸기" aria-label="이름 바꾸기">✎</button>
        <button class="iconBtn" type="button" data-archive="${esc(room.root)}" title="접어두기" aria-label="접어두기">↓</button>
        ${room.removable === false ? "" :
          `<button class="iconBtn danger" type="button" data-room-delete="${esc(room.root)}" title="방 지우기" aria-label="방 지우기">🗑</button>`}
        <button class="iconBtn" type="button" data-room-close="1" title="닫기" aria-label="닫기">✕</button>
      </div>`;
      // 로그인이 풀린 방에는 **여기서 푸는 길**을 준다. 예전엔 맥에 가야만 했다 —
      // 폰엔 터미널 화면이 없어서 CLI 가 띄우는 로그인 URL 을 볼 방법이 아예 없었다.
      const 막힘글 = statusReasonText(room.blockedReason);
      const 로그인줄 = room.blockedReason === "needs_login"
        ? `<div class="roomBlocked">${esc(막힘글)}
             <button class="roomStart" type="button" data-room-relogin="${esc(room.root)}">로그인 하기</button>
           </div>`
        : 막힘글 ? `<div class="roomBlocked">${esc(막힘글)}</div>` : "";
      const 시작줄 = (로그인줄 || "") + (시작 ? `<div class="roomStartRow">${시작}</div>` : "");
      if (!tabs.length) {
        return head + 시작줄 + '<div class="roomEmpty">아직 대화가 없어요.</div>';
      }
      const strip = tabs.map(tab => {
        const key = `${tab.source}:${tab.sid}`;
        const cls = "roomTab" + (tab.primary ? " current" : "")
                  + (tab.hidden || tab.deleted ? " off" : "") + (tab.stale ? " stale" : "");
        // 숨긴 대화는 **되살릴 손잡이**를 같이 준다. 예전엔 세션 카드 롱프레스에만 있어서,
        // 방 화면에서는 숨긴 것이 영영 잠겼다. 무엇 때문에 안 세는지도 글자로 말해준다 —
        // 흐리기만 하면 "접힘"인지 "숨김"인지 구별이 안 된다.
        const 꼬리 = tab.deleted
          ? `<button class="roomTabUnhide" type="button" data-restore="${esc(key)}">되살리기</button><span class="roomTabNote">지움</span>`
          : tab.hidden
          ? `<button class="roomTabUnhide" type="button" data-unhide="${esc(key)}">숨김 해제</button>`
          : `<button class="roomTabUnhide" type="button" data-close-chat="${esc(key)}" title="이 대화 끄기">끄기</button>`
            + `<button class="roomTabUnhide" type="button" data-forget="${esc(key)}" title="이 대화 지우기">지우기</button>`
            + (tab.stale ? '<span class="roomTabNote">오래됨</span>' : "");
        return `<div class="roomTabRow"><button class="${cls}" type="button" data-tab="${esc(key)}">${esc(tab.title || key)}</button>${꼬리}</div>`;
      }).join("");
      return head + `<div class="roomTabs">${strip}</div>` + 시작줄;
    }
    // ROOM_TABS_END

    function draftKey(sessionKey=selectedSessionKey) {
      return `marinaMobileDraft:${sessionKey || selectedRoot() || "new"}`;
    }
    function saveDraft() {
      if (!activeDraftKey) return;
      localStorage.setItem(activeDraftKey, promptInput.value);
    }
    function restoreDraft() {
      const nextKey = draftKey();
      if (nextKey === activeDraftKey) return;
      saveDraft();
      activeDraftKey = nextKey;
      promptInput.value = localStorage.getItem(nextKey) || "";
      autoGrowComposer();
      closeSuggestions();
    }
    function autoGrowComposer() {
      promptInput.style.height = "auto";
      promptInput.style.height = `${Math.min(promptInput.scrollHeight, 132)}px`;
    }
    function atPageBottom() {
      return turnsEl.scrollTop + turnsEl.clientHeight >= turnsEl.scrollHeight - 16;
    }
    function scrollToLatest(behavior="auto") {
      followLatest = true;
      suppressScrollTracking = true;
      turnsEl.scrollTo({top: turnsEl.scrollHeight, behavior});
      newMessagesBtn.style.display = "none";
      requestAnimationFrame(() => { suppressScrollTracking = false; });
    }
    function captureScrollAnchor() {
      const viewportTop = turnsEl.getBoundingClientRect().top;
      const exchange = [...turnsEl.querySelectorAll("[data-exchange-id]")].find(item => item.getBoundingClientRect().bottom > viewportTop + 1);
      const message = exchange && exchange.querySelector("[data-timeline-message-id]");
      return exchange ? {
        id: exchange.getAttribute("data-exchange-id") || "",
        offset: exchange.getBoundingClientRect().top - viewportTop,
        messageId: message ? message.getAttribute("data-timeline-message-id") || "" : "",
        messageOffset: message ? message.getBoundingClientRect().top - viewportTop : 0,
        scrollTop: turnsEl.scrollTop,
        scrollHeight: turnsEl.scrollHeight,
      } : {id: "", offset: 0, messageId: "", messageOffset: 0, scrollTop: turnsEl.scrollTop, scrollHeight: turnsEl.scrollHeight};
    }
    function restoreScrollAnchor(anchor) {
      if (!anchor) return;
      const viewportTop = turnsEl.getBoundingClientRect().top;
      const exchange = [...turnsEl.querySelectorAll("[data-exchange-id]")].find(item => item.getAttribute("data-exchange-id") === anchor.id);
      const message = anchor.messageId ? [...turnsEl.querySelectorAll("[data-timeline-message-id]")].find(item => item.getAttribute("data-timeline-message-id") === anchor.messageId) : null;
      suppressScrollTracking = true;
      if (message) turnsEl.scrollTop += message.getBoundingClientRect().top - viewportTop - anchor.messageOffset;
      else if (exchange) turnsEl.scrollTop += exchange.getBoundingClientRect().top - viewportTop - anchor.offset;
      else turnsEl.scrollTop = anchor.scrollTop + Math.max(0, turnsEl.scrollHeight - Number(anchor.scrollHeight || turnsEl.scrollHeight));
      requestAnimationFrame(() => { suppressScrollTracking = false; });
    }
    function closeSuggestions() {
      suggestionsEl.classList.remove("open");
      suggestionsEl.innerHTML = "";
      suggestionRange = null;
    }
    function clearFailedSend() {
      failedSend = null;
      retryBtn.style.display = "none";
    }
    function updateHtmlIfChanged(element, html) {
      if (element.innerHTML === html) return false;
      element.innerHTML = html;
      return true;
    }
    function labelWt(w) { return [w.alias, w.sessionTitle, w.projectLabel, w.id].filter(Boolean).join(" · ") || w.root; }
    function projectId(w) { return String(w.projectId || w.projectLabel || w.alias || w.root || w.id || ""); }
    function projectName(w) {
      if (w.projectLabel || w.projectId || w.alias || w.id) return String(w.projectLabel || w.projectId || w.alias || w.id);
      const parts = String(w.root || "").split("/").filter(Boolean);
      return parts[parts.length - 1] || "Project";
    }
    function worktreeForRoot(root) { return state.worktrees.find(w => w.root === root) || null; }
    function sessionProjectId(session) {
      const wt = worktreeForRoot(session && session.root);
      return wt ? projectId(wt) : String((session && session.root) || "");
    }
    function rememberProjectForRoot(root) {
      // **'전체'는 형이 고른 상태다 — 덮지 않는다.** 예전엔 대화를 한 번 열면 그 방의
      // 프로젝트로 조용히 옮겨가, 전체를 골라도 다음 순간 방 21개가 다시 사라졌다.
      // (그 프로젝트로 옮겨가는 건 대화 목록을 따라가라는 뜻이었지, 전체 보기를 끄라는 뜻이 아니다.)
      if (!selectedProjectId) return;
      const wt = worktreeForRoot(root);
      if (!wt) return;
      selectedProjectId = projectId(wt);
      localStorage.setItem("marinaMobileProject", selectedProjectId);
    }
    function selectedRoot() { return rootSelect.value || (state.worktrees[0] && state.worktrees[0].root) || ""; }
    function targetKey(root=selectedRoot()) { return `marinaMobileTarget:${root}`; }
    function selectedSession() { return (state.sessions || []).find(s => s.key === selectedSessionKey) || null; }

    // SESSION_HOLD_START
    // 새로 연 대화는 **잠깐 어느 목록에도 없다**. PTY 를 띄운 직후엔 서버가 아직 안 싣고,
    // 첫 지시로 승격(term → agent)되는 순간엔 term 카드가 빠지고 agent 카드가 tid 를 달기까지
    // 폴 한 번이 빈다. 그 한 번을 "세션이 사라졌다"로 읽으면 render 가 목록으로 되돌려 보내
    // **새 대화를 시작하자마자 밖으로 튕긴다**(형 지적). 사라진 게 아니라 오는 중이므로,
    // 마지막으로 실물이었던 세션을 잠깐 붙들고 화면을 지킨다 — 진짜로 없어졌으면 곧 목록으로.
    const SESSION_HOLD_MS = 20000;
    function holdSession(current, held, heldAt, key, now, graceMs) {
      if (current) return current;
      if (!key || !held || held.key !== key) return null;
      return (now - heldAt) < graceMs ? held : null;
    }
    // SESSION_HOLD_END
    let heldSession = null;
    let heldSessionAt = 0;

    // ── 세션 탭 — 목록으로 돌아가지 않고 바로 옮겨다니기 ────────────────────────
    // 웹 대화 워크스페이스와 같은 모델: **연 것만** 탭으로 남는다(전체 세션을 늘어놓으면 14개가
    // 그대로 줄이 돼 탭의 의미가 없다). 순서는 연 순서 그대로 — 자동 정렬하면 누르려던 탭이 움직인다.
    const TAB_LIMIT = 8;   // 그 이상은 가장 오래된 비활성 탭부터 밀어낸다(가로 스크롤이 무한해지지 않게)
    let openTabs = [];
    try { openTabs = JSON.parse(localStorage.getItem("marinaMobileTabs") || "[]") || []; } catch (_) { openTabs = []; }
    if (!Array.isArray(openTabs)) openTabs = [];
    function saveTabs() { try { localStorage.setItem("marinaMobileTabs", JSON.stringify(openTabs.slice(0, 40))); } catch (_) {} }
    function addTab(key) {
      if (!key || openTabs.includes(key)) return;
      openTabs.push(key);
      if (openTabs.length > TAB_LIMIT) {
        const victim = openTabs.find(k => k !== key && k !== selectedSessionKey);
        if (victim) openTabs = openTabs.filter(k => k !== victim);
      }
      saveTabs();
    }
    function closeTab(key) {
      const at = openTabs.indexOf(key);
      if (at < 0) return;
      openTabs = openTabs.filter(k => k !== key);
      saveTabs();
      if (key !== selectedSessionKey) { renderSessionTabs(); return; }
      // 닫은 게 보고 있던 탭이면 옆 탭으로 — 아무것도 없으면 목록으로 돌아간다.
      const next = openTabs[Math.min(at, openTabs.length - 1)];
      if (next) chooseSession(next);
      else { selectedSessionKey = ""; localStorage.removeItem("marinaMobileSession"); showList(); renderSessionTabs(); }
    }
    function renderSessionTabs() {
      const sessions = state.sessions || [];
      // 사라진 세션 탭은 조용히 정리 — 단 **보고 있는 탭**은 예외다. 기동·승격 틈에 폴 한 번
      // 빠졌다고 지우면, 그 세션이 돌아왔을 때 탭이 없어져 있다(holdSession 과 같은 이유).
      const alive = openTabs.filter(key => key === selectedSessionKey || sessions.some(s => s.key === key));
      if (alive.length !== openTabs.length) { openTabs = alive; saveTabs(); }
      // 탭이 하나뿐이면 줄을 띄울 이유가 없다 — 화면만 먹는다.
      if (alive.length < 2) { if (sessionTabsEl.innerHTML) sessionTabsEl.innerHTML = ""; return; }
      const html = alive.map(key => {
        const s = sessions.find(item => item.key === key) || {};
        const active = key === selectedSessionKey;
        const sm = s.kind === "agent" ? agentStatusMeta(s.status) : null;
        const label = esc(String(s.title || s.key || "세션").slice(0, 22));
        return `<span class="sessionTab${active ? " active" : ""}" role="tab" aria-selected="${active}" tabindex="0" data-tab-key="${esc(key)}">`
          + `<i class="wt-dot ${sm ? sm.dot : "stop"}" aria-hidden="true"></i>`
          + `<span class="sessionTabLabel">${label}</span>`
          + `<b class="sessionTabX" data-tab-close="${esc(key)}" aria-label="탭 닫기">&#10005;</b></span>`;
      }).join("");
      if (sessionTabsEl.innerHTML !== html) sessionTabsEl.innerHTML = html;
      const activeEl = sessionTabsEl.querySelector(".sessionTab.active");
      if (activeEl && activeEl.scrollIntoView) activeEl.scrollIntoView({block: "nearest", inline: "nearest"});
    }
    // 세션 단위 동작은 **그 세션의 root** 를 쓴다. 전역 selectedRoot() 는 워크트리 피커/프로젝트 탭이
    // 움직이면 선택된 세션과 어긋나고, 그러면 서버의 agent_belongs_to_root 가 막아 403 이 된다
    // (형: "이 세션 모바일에서 안되잖아 · do not access this resource"). settings/interrupt 는 원래
    // session.root 를 써서 멀쩡했다 — 나머지를 그 관례에 맞춘다.
    function sessionRoot() {
      const session = selectedSession();
      return (session && session.root) || selectedRoot();
    }
    function termKey(tid) { return `term:${tid}`; }
    function migrateSelectionOnPromotion() {
      // 직접 launch 한 PTY 는 첫 지시가 훅을 깨우는 순간 sid 를 얻어(입양) term 카드 → agent 카드로
      // 바뀐다. 키가 통째로 갈리므로 옮겨주지 않으면 보고 있던 화면이 빈 세션이 된다.
      if (!selectedSessionKey.startsWith("term:")) return;
      const list = state.sessions || [];
      if (list.some(s => s.key === selectedSessionKey)) return;
      const tid = selectedSessionKey.slice(5);
      const promoted = list.find(s => s.kind === "agent" && s.tid === tid);
      if (!promoted) return;
      delete pendingTurns[selectedSessionKey];   // 승격 뒤엔 에이전트 트랜스크립트가 진실이다
      selectedSessionKey = promoted.key;
      turnsStructureKey = "";
      localStorage.setItem("marinaMobileSession", promoted.key);
      if (promoted.target) {
        const value = targetValue(promoted.target);
        localStorage.setItem("marinaMobileTarget", value);
        localStorage.setItem(targetKey(promoted.root), value);
      }
    }
    function currentTargetValue() {
      const s = selectedSession();
      if (s && s.target) {
        if (s.target.type === "term") return `term:${s.target.tid}`;
        if (s.target.type === "agent") return `agent:${s.target.source}:${s.target.sid}`;
        return "shell";
      }
      return targetSelect.value;
    }
    function rememberRoot() {
      const root = selectedRoot();
      if (root) localStorage.setItem("marinaMobileRoot", root);
    }
    function rememberTarget() {
      if (!targetSelect.value) return;
      localStorage.setItem("marinaMobileTarget", targetSelect.value);
      localStorage.setItem(targetKey(), targetSelect.value);
    }
    function chooseSession(key) {
      const s = (state.sessions || []).find(item => item.key === key);
      if (!s) return;
      if (key !== selectedSessionKey) clearFailedSend();
      closeUsagePanel();
      closeDrawer();          // 좌측 패널에서 골랐으면 바로 그 대화로 — 이게 "바로바로 넘어가기"의 핵심
      addTab(key);            // 연 세션은 탭으로 남는다 — 다음부턴 목록 안 거치고 바로 전환
      selectedSessionKey = key;
      followLatest = true;
      turnsStructureKey = "";
      fileSuggestions = [];
      fileSuggestionKey = "";
      localStorage.setItem("marinaMobileSession", key);
      if (s.root) {
        localStorage.setItem("marinaMobileRoot", s.root);
        rootSelect.value = s.root;
        rememberProjectForRoot(s.root);
      }
      if (s.target) {
        const value = s.target.type === "term" ? `term:${s.target.tid}` : s.target.type === "agent" ? `agent:${s.target.source}:${s.target.sid}` : "shell";
        localStorage.setItem("marinaMobileTarget", value);
        localStorage.setItem(targetKey(s.root), value);
        targetSelect.value = value;
      }
      showChat();
      if (history.state && history.state.view === "chat") history.replaceState({view: "chat"}, "", location.href);
      else history.pushState({view: "chat"}, "", location.href);
      render();
      loadSessionMessages(s).catch(error => { statusEl.textContent = `대화 실패 · ${String(error)}`; });
      requestAnimationFrame(() => scrollToLatest("auto"));
    }
    function targetValue(target) {
      if (!target) return "shell";
      if (target.type === "term") return `term:${target.tid}`;
      if (target.type === "agent") return `agent:${target.source}:${target.sid}`;
      return "shell";
    }
    function agentSessionKey(target, root) {
      return target && target.type === "agent" ? `agent:${target.source}:${target.sid}:${root}` : "";
    }
    function sameTarget(a, b) {
      if (!a || !b || a.type !== b.type) return false;
      if (a.type === "term") return a.tid === b.tid;
      if (a.type === "agent") return a.source === b.source && a.sid === b.sid;
      return a.type === b.type;
    }
    // 확정 user 메시지 카운트 — 공백/개행 정규화(큐 제출 시 내부 공백·줄바꿈 차이로 매칭 실패해 pending 이 유령으로 남던 문제) + per-text 최댓값(이중계수 방지). reconcile·baseline 공용.
    function normUserText(raw) { return String(raw || "").replace(/\s+/g, " ").trim(); }
    function confirmedUserCounts(turns, timeline) {
      const tally = (arr, pred) => {
        const map = new Map();
        (arr || []).forEach(item => {
          if (!pred(item)) return;
          const text = normUserText(item.text);
          if (text) map.set(text, (map.get(text) || 0) + 1);
        });
        return map;
      };
      const fromTurns = tally(turns, t => t.role === "user");
      const fromTimeline = tally(timeline, it => (it.kind === "message" || !it.kind) && it.role === "user");
      const out = new Map();
      new Set([...fromTurns.keys(), ...fromTimeline.keys()]).forEach(text =>
        out.set(text, Math.max(fromTurns.get(text) || 0, fromTimeline.get(text) || 0)));
      return out;
    }
    // RECONCILE_PENDING_RECORD_START
    // 대기열 레코드 하나의 순수 판정(부수효과 없음, 테스트 가능): 제거(null) | 유지(record) | 실패표기.
    // 우선순위: 소비(isConfirmed) > 유령(ghost, 더 나중 레코드가 확정됨) > tid-liveness(전달받은 PTY 가 죽음).
    // tid-liveness 는 순수 경과시간 규칙이 아니다 — 살아있는 tid 를 가진 레코드는(긴 턴이라도) 절대 시간만으로 실패 처리하지 않는다.
    function reconcilePendingRecord(record, {confirmedUsers, latestConfirmedAt, liveTids, now} = {}) {
      const norm = normUserText(record.text);
      const confirmedMap = confirmedUsers || new Map();
      const confirmedKeys = [...confirmedMap.keys()];
      const containedIn = norm.length >= 6 && confirmedKeys.some(k => k.includes(norm));
      const confirmedCount = confirmedMap.get(norm) || 0;
      const isConfirmed = confirmedCount > Number(record.baseline || 0) || containedIn;
      if (isConfirmed) return null;                                // 정상 소비 → 제거
      const isGhost = Boolean(latestConfirmedAt && Number(record.createdAt || 0) < Number(latestConfirmedAt || 0));
      if (isGhost) {
        const present = confirmedCount > 0 || containedIn;         // 트랜스크립트에 조금이라도 있으면 = 소비됨
        if (present) return null;                                  // baseline 만 어긋남 → 제거
        return {...record, failed: true, delivery: "failed"};      // 진짜 미전달 → 실패 표기
      }
      const trackedDelivery = record.delivery === "queue" || record.delivery === "steer" || record.delivery === "started";
      const hasTid = Boolean(record.tid);
      const tidLive = hasTid && Boolean(liveTids) && liveTids.has(record.tid);
      const aged = Number(now || 0) - Number(record.createdAt || 0) > 4000;   // send→첫 폴 사이 레이스 방지
      if (trackedDelivery && hasTid && !tidLive && aged) {
        return {...record, failed: true, delivery: "failed"};      // 전달 목적지 PTY 가 사라짐(문신) → 자동 실패
      }
      return record;                                                // 아직 정상 대기
    }
    // state.terms 에서 "입력 가능한" tid 집합만 뽑는다 — detached(재시작 후 디스크에서 복원된 PTY)는
    // tid 는 살아있어 보여도 fd 가 없어 term_input 이 400 나므로 liveness 판정에서 제외해야
    // 그쪽으로 큐된 메시지가 tid-liveness 규칙으로 자동 실패(문신 소멸)될 수 있다.
    function liveTidsFromTerms(terms) {
      return new Set((terms || []).filter(t => !t.detached).map(t => t.tid).filter(Boolean));
    }
    // RECONCILE_PENDING_RECORD_END
    function queuePendingTurn(key, text, delivery="pending", tid="", target=null, root="") {
      const session = (state.sessions || []).find(item => item.key === key);
      const cached = sessionHistory(session);
      const norm = normUserText(text);
      const confirmed = confirmedUserCounts((cached && cached.turns) || (session && session.turns) || [], cached && cached.timeline);
      const confirmedCount = confirmed.get(norm) || 0;
      const existing = pendingTurns[key] || [];
      const pendingCount = existing.filter(turn => normUserText(turn.text) === norm).length;
      pendingRecordSeq += 1;
      pendingTurns[key] = existing.concat([{
        id: `pend${pendingRecordSeq}`, role: "user", text, baseline: confirmedCount + pendingCount, pending: true,
        delivery, failed: delivery === "failed", tid: tid || "", createdAt: Date.now(), target: target || null, root: root || "",
      }]).slice(-12);
    }
    // OPTIMISTIC_TURN_START  (테스트가 이 블록을 vm 에 싣는다)
    // 보낸 즉시 세우고, 서버 응답이 오면 **같은 레코드에** 결과를 얹는다. 새로 만들면 같은 말이
    // 두 번 보이고, 안 세우면 응답 전까지 화면이 죽은 것처럼 보인다.
    function queueOptimisticTurn(key, text, target, root) {
      queuePendingTurn(key, text, "pending", "", target, root);
      const list = pendingTurns[key] || [];
      return list.length ? list[list.length - 1].id : "";
    }
    function settleOptimisticTurn(key, id, delivery, tid) {
      if (!id) return false;
      const list = pendingTurns[key] || [];
      const record = list.find(turn => turn.id === id);
      if (!record) return false;              // 그새 확정돼 사라졌다 — 서버 행이 대신한다
      record.delivery = delivery;
      record.failed = delivery === "failed";
      if (tid) record.tid = tid;
      return true;
    }
    // OPTIMISTIC_TURN_END
    function selectAgentAfterSend(text, target, delivery="pending", tid="", existingId="") {
      const root = selectedRoot();
      const current = selectedSession();
      const key = current && sameTarget(current.target, target) ? selectedSessionKey : agentSessionKey(target, root);
      selectedSessionKey = key;
      localStorage.setItem("marinaMobileSession", key);
      // 이미 낙관적으로 세워 둔 말풍선이 이 세션에 있으면 다시 만들지 않는다 — 만들면 같은 말이
      // 두 개로 보인다(하나는 결과가 얹힌 것, 하나는 새로 만든 것).
      const already = existingId && (pendingTurns[key] || []).some(turn => turn.id === existingId);
      if (!already) queuePendingTurn(key, text, delivery, tid, target, root);
      const value = targetValue(target);
      localStorage.setItem("marinaMobileTarget", value);
      localStorage.setItem(targetKey(root), value);
      rootSelect.value = root;
      targetSelect.value = value;
      showChat();
      render();
    }
    function ensureLiveTermSession(tid, root, text="", target=null) {
      const key = termKey(tid);
      if (!(state.sessions || []).some(s => s.key === key)) {
        state.sessions = [
          {
            key,
            kind: "term",
            root,
            title: "Live terminal",
            subtitle: "방금 보낸 세션",
            preview: text,
            tid,
            target: target || {type: "term", tid},
            turns: [],
            ts: Date.now() / 1000,
          },
          ...(state.sessions || []),
        ];
      }
      selectedSessionKey = key;
      localStorage.setItem("marinaMobileSession", key);
      if (root) localStorage.setItem("marinaMobileRoot", root);
      return key;
    }
    function selectReturnedTerm(tid, text, target=null, delivery="pending", existingId="") {
      if (target && target.type === "agent") {
        selectAgentAfterSend(text, target, delivery, tid, existingId);
        return;
      }
      const root = selectedRoot();
      const key = ensureLiveTermSession(tid, root, text, target);
      const already = existingId && (pendingTurns[key] || []).some(turn => turn.id === existingId);
      if (!already) queuePendingTurn(key, text, delivery, tid, target || {type: "term", tid}, root);
      const value = targetValue(target || {type: "term", tid});
      localStorage.setItem("marinaMobileTarget", value);
      localStorage.setItem(targetKey(root), value);
      rootSelect.value = root;
      targetSelect.value = value;
      showChat();
      render();
    }
    function projectsWithCounts() {
      const projects = [];
      const byId = new Map();
      state.worktrees.forEach(w => {
        const id = projectId(w);
        if (!id) return;
        if (!byId.has(id)) {
          const item = {id, label: projectName(w), count: 0};
          byId.set(id, item);
          projects.push(item);
        }
      });
      (state.sessions || []).forEach(s => {
        const item = byId.get(sessionProjectId(s));
        if (item) item.count += 1;
      });
      return projects;
    }
    function renderProjectTabs() {
      const projects = projectsWithCounts();
      // 빈 값("전체")은 유효한 선택이다 — 강제 선택으로 덮으면 '전체'를 고를 수 없다.
      if (selectedProjectId && !projects.some(p => p.id === selectedProjectId)) {
        const current = selectedSession();
        const currentProject = current ? sessionProjectId(current) : "";
        selectedProjectId = projects.some(p => p.id === currentProject) ? currentProject : ((projects[0] && projects[0].id) || "");
        if (selectedProjectId) localStorage.setItem("marinaMobileProject", selectedProjectId);
      }
      // **'전체' 칩이 있어야 한다.** 없으면 항상 한 프로젝트가 강제로 선택돼(바로 위 코드),
      // 방 목록이 그 프로젝트만 보여준다 — 실측으로 방 28개 중 21개가, 답을 기다리는 방
      // 4개 중 3개가 화면에서 사라졌다. 급한 방을 아래에 두는 것보다 안 보이게 하는 게 나쁘다.
      // 숫자는 **방** 개수다 — 목록이 보여주는 게 방이라, 칩이 세션을 세면 합이 안 맞는다
      // (실측: 전체 28 인데 칩 합 34). 방이 아직 없으면(폴백) 예전대로 세션을 센다.
      const 방들 = state.rooms || [];
      const 방수 = new Map();
      방들.forEach(room => {
        const key = String(room.projectId || "");
        방수.set(key, (방수.get(key) || 0) + 1);
      });
      const 세기 = p => (방들.length ? (방수.get(p.id) || 0) : p.count);
      const 전체칩 = `<button class="project-chip ${selectedProjectId ? "" : "active"}" type="button" data-project="" title="전체">전체<span class="project-count">${방들.length || projects.reduce((sum, p) => sum + p.count, 0)}</span></button>`;
      const html = 전체칩 + projects.map(p => `<button class="project-chip ${p.id === selectedProjectId ? "active" : ""}" type="button" data-project="${esc(p.id)}" title="${esc(p.label)}">${esc(p.label)}<span class="project-count">${세기(p)}</span></button>`).join("");
      updateHtmlIfChanged(projectTabs, html);
    }
    function projectSessions() {
      return (state.sessions || []).filter(s => !selectedProjectId || sessionProjectId(s) === selectedProjectId);
    }
    // 자리표시자(kind=shell)는 아직 아무것도 안 도는 워크트리의 "셸 열래?" 카드다. 공유
    // sessionSource 는 claude/codex 가 아니면 전부 terminal 로 떨어뜨리는데, 그러면 돌고 있는
    // PTY 가 하나도 없어도 "터미널 N" 으로 세어진다. 필터·카운트는 이 술어를 쓴다.
    function sessionFilterSource(session) {
      if (session && session.kind === "shell") return "none";
      return sessionSource(session);
    }
    function renderSourceTabs() {
      const sessions = projectSessions();
      const counts = {all: sessions.length, codex: 0, claude: 0, terminal: 0, none: 0};
      sessions.forEach(s => { counts[sessionFilterSource(s)] += 1; });
      if (!["all", "codex", "claude", "terminal"].includes(sourceFilter)) sourceFilter = "all";
      const tabs = [
        {id: "all", label: "전체"},
        {id: "codex", label: "Codex"},
        {id: "claude", label: "Claude"},
        {id: "terminal", label: "터미널"},
      ];
      const html = tabs.map(tab => `<button class="source-tab ${tab.id === sourceFilter ? "active" : ""}" type="button" data-source="${tab.id}">${tab.label} ${counts[tab.id]}</button>`).join("");
      updateHtmlIfChanged(sourceTabs, html);
    }
    function modelCatalogLabel(model) {
      const value = String(model || "");
      if (!value) return "";
      const opts = state.agentOptions || {};
      for (const src of Object.keys(opts)) {
        const found = ((opts[src] || {}).models || []).find(item => item.value === value);
        if (found && found.label) return found.label;
      }
      return "";
    }
    function displayModel(model) {
      const value = String(model || "");
      const catalog = modelCatalogLabel(value);   // 카탈로그 라벨 우선(설정버튼·턴메타·드롭다운 표기 통일)
      if (catalog) return catalog;
      const short = value.match(/^gpt-[\d.]+-(sol|terra|luna)$/i);
      if (short) return short[1].charAt(0).toUpperCase() + short[1].slice(1).toLowerCase();
      if (value.startsWith("claude-")) return value.slice(7).replaceAll("-", " ");
      return value;
    }
    function sessionSubtitle(session) {
      const current = session && session.settings && session.settings.current;
      const runtime = runtimeLabel(current);
      return [session.subtitle || session.root || "", runtime].filter(Boolean).join(" · ");
    }
    function sessionCard(session) {
      const source = sessionSource(session);
      // 자리표시자를 TERM 으로 배지하면 안 도는 걸 도는 것처럼 말하는 셈이다.
      const meta = session.kind === "shell" ? {label: "새 셸", badge: "새 셸"} : sourceMeta[source];
      const sm = session.kind === "agent" ? agentStatusMeta(session.status) : null;
      // 질문 대기는 별도 표시가 아니라 **상태값**이다 — 서버가 status="blocked" 로 주고
      // 상태표에 blocked → "응답 필요"가 이미 있다. 시간 자리는 시간만 맡는다.
      const when = relTime(session.ts);
      const notable = NOTABLE_STATUS.has(String(session.status || ""));
      // 요소는 **항상 만들고** 내용/표시만 patch 가 갱신한다 — 노드를 재사용해야 순서를 옮겨도
      // 스크롤·포커스가 안 튄다. 간단/자세히 밀도는 CSS 가 가리므로 렌더를 다시 하지 않는다.
      const statusHtml = `<span class="session-status${notable ? " notable" : ""}" data-session-status><span class="wt-dot ${sm ? sm.dot : "stop"}"></span><span class="session-status-label">${sm ? esc(sm.label) : ""}</span></span>`;
      const hiddenKey = `${session.source}:${session.sid}`;
      const isHidden = hiddenSessions.has(hiddenKey);
      return `<button class="session-card ${session.key === selectedSessionKey ? "active" : ""}${isHidden ? " hidden-session" : ""}" type="button" data-key="${esc(session.key)}" data-hide-key="${esc(hiddenKey)}">
        <span class="session-card-top"><span class="source-badge ${source}">${meta.badge}</span><span class="session-title" data-session-title>${esc(session.title || session.key)}</span>${statusHtml}<span class="session-when" data-session-when>${esc(when)}</span></span>
        <span class="session-subtitle" data-session-subtitle>${esc(sessionSubtitle(session))}</span>
        <span class="session-preview" data-session-preview>${esc(session.preview || "(최근 작업 없음)")}</span>
      </button>`;
    }
    // LIST_RECONCILE_START
    // key 로 노드를 **재사용하고 위치만 옮긴다**(insertBefore). 새로 만들면 폴링마다 스크롤·펼침이 튄다.
    // 예전 renderSessions 는 구조키에 .sort() 를 걸어 순서에 둔감했고, 그래서 세션에서 일해 mtime 이
    // 올라가도 화면에서 위로 올라오지 않았다(형: "작업 완료 최신순도 아니고 정렬이").
    function reconcileKeyed(container, items, opts) {
      const existing = new Map();
      for (const node of [...container.children]) {
        const k = node.dataset ? node.dataset.rkey : null;
        if (k == null) container.removeChild(node);          // 잔재(빈 상태 등)
        else existing.set(k, node);
      }
      let cursor = null;
      for (const item of items) {
        const k = String(opts.key(item));
        let node = existing.get(k);
        if (node) { existing.delete(k); if (opts.patch) opts.patch(node, item); }
        else { node = opts.create(item); node.dataset.rkey = k; }
        const expected = cursor ? cursor.nextSibling : container.firstChild;
        if (node !== expected) container.insertBefore(node, expected);
        cursor = node;
      }
      for (const node of existing.values()) container.removeChild(node);
    }
    // 마지막 활동 상대시간 — 한 줄 카드에서 "언제"를 담당한다.
    function relTime(ts) {
      const seconds = Math.floor(Date.now() / 1000 - (Number(ts) || 0));
      if (!ts || seconds < 0) return "";
      if (seconds < 60) return "방금";
      if (seconds < 3600) return `${Math.floor(seconds / 60)}분`;
      if (seconds < 86400) return `${Math.floor(seconds / 3600)}시간`;
      if (seconds < 172800) return "어제";
      return `${Math.floor(seconds / 86400)}일`;
    }
    // 그룹 배지도 **같은 상태값**에서 센다 — pendingQuestion 을 따로 세면 두 진실이 갈린다.
    function groupOf(sessions) {
      const asking = sessions.filter(s => s.status === "blocked").length;
      const busy = sessions.filter(s => s.status === "working").length;
      return {asking, busy, dot: asking ? "ask" : (busy ? "boot" : "stop")};
    }
    function wtName(root) {
      const wt = (state.worktrees || []).find(w => w.root === root);
      return (wt && wt.alias) || root.split("/").filter(Boolean).pop() || root || "워크트리";
    }
    function renderSessions() {
      const q = sessionSearch.value.trim().toLowerCase();
      const sessions = projectSessions().filter(s => {
        if (sourceFilter !== "all" && sessionFilterSource(s) !== sourceFilter) return false;
        return !q || [s.title, s.subtitle, s.preview, s.root].some(v => String(v || "").toLowerCase().includes(q));
      }).slice(0, 40);
      if (!sessions.length) {
        sessionList.innerHTML = `<div class="empty-state">${q ? "검색 결과가 없습니다." : "이 분류에 열린 세션이 없습니다."}</div>`;
        return;
      }
      // 서버가 이미 마지막 활동 최신순으로 준다 → 첫 등장 순서가 곧 그룹의 최신순이다.
      const order = [];
      const byRoot = new Map();
      sessions.forEach(session => {
        const root = String(session.root || "");
        if (!byRoot.has(root)) { byRoot.set(root, []); order.push(root); }
        byRoot.get(root).push(session);
      });
      // 핀 먼저. Array#sort 는 안정 정렬이라 각 묶음 안에서는 최신순이 그대로 유지된다.
      order.sort((a, b) => (pinnedRoots.has(b) ? 1 : 0) - (pinnedRoots.has(a) ? 1 : 0));
      reconcileKeyed(sessionList, order, {
        key: root => root,
        create: root => {
          const node = document.createElement("details");
          node.className = "session-group wt-group";
          node.setAttribute("data-wt-root", root);
          // 기본 접힘. 지금 보고 있는 세션이 있거나 주의가 필요한 그룹만 펼친다.
          // patch 에서는 open 을 건드리지 않는다 — 접고 펴는 건 형 소유다.
          const grouped = byRoot.get(root) || [];
          const info = groupOf(grouped);
          node.open = info.asking > 0 || info.busy > 0
            || grouped.some(s => s.key === selectedSessionKey);
          node.innerHTML = `<summary class="session-group-title wt-group-head">
              <span class="wt-group-name"><span class="wt-pin" data-pin-root role="img"></span><span class="wt-dot"></span><span class="wt-label"></span></span>
              <span class="wt-group-acts">
                <span class="wt-group-flags"></span>
                <span class="wt-group-count"></span>
                <button class="wtLaunchBtn wtMoreBtn" type="button" data-wt-more="${esc(root)}" title="이 워크트리 작업" aria-label="이 워크트리 작업">&#8943;</button>
              </span>
            </summary><div class="wt-group-body"></div>`;
          patchGroup(node, root);
          return node;
        },
        patch: patchGroup,
      });
    }
    function patchGroup(node, root) {
      const grouped = byRootSessions(root);
      const info = groupOf(grouped);
      const pinned = pinnedRoots.has(root);
      node.classList.toggle("pinned", pinned);
      const pin = node.querySelector("[data-pin-root]");
      pin.textContent = pinned ? "📌" : "";
      pin.setAttribute("aria-label", pinned ? "고정 해제" : "고정");
      const dot = node.querySelector(".wt-dot");
      dot.className = `wt-dot ${info.dot}`;
      node.querySelector(".wt-label").textContent = wtName(root);
      node.querySelector(".wt-group-count").textContent = String(grouped.length);
      // 접혀 있어도 안에서 무슨 일이 나는지는 보여야 한다 — 안 그러면 접기가 정보를 숨긴다.
      const flags = [];
      if (info.asking) flags.push(`<span class="wt-flag asking">응답 ${info.asking}</span>`);
      if (info.busy) flags.push(`<span class="wt-flag busy">작업 ${info.busy}</span>`);
      const flagsHtml = flags.join("");
      const flagsEl = node.querySelector(".wt-group-flags");
      if (flagsEl.innerHTML !== flagsHtml) flagsEl.innerHTML = flagsHtml;
      reconcileKeyed(node.querySelector(".wt-group-body"), grouped, {
        key: session => session.key,
        create: session => {
          const holder = document.createElement("div");
          holder.innerHTML = sessionCard(session);
          return holder.firstElementChild;
        },
        patch: patchSessionCard,
      });
    }
    function byRootSessions(root) {
      const q = sessionSearch.value.trim().toLowerCase();
      return projectSessions().filter(s => {
        if (String(s.root || "") !== root) return false;
        if (sourceFilter !== "all" && sessionFilterSource(s) !== sourceFilter) return false;
        return !q || [s.title, s.subtitle, s.preview, s.root].some(v => String(v || "").toLowerCase().includes(q));
      });
    }
    function patchSessionCard(card, session) {
      card.classList.toggle("active", session.key === selectedSessionKey);
      card.classList.toggle("hidden-session", hiddenSessions.has(`${session.source}:${session.sid}`));
      const sm = session.kind === "agent" ? agentStatusMeta(session.status) : null;
      card.querySelector("[data-session-title]").textContent = session.title || session.key;
      card.querySelector("[data-session-subtitle]").textContent = sessionSubtitle(session);
      card.querySelector("[data-session-preview]").textContent = session.preview || "(최근 작업 없음)";
      const when = card.querySelector("[data-session-when]");
      if (when) when.textContent = relTime(session.ts);
      const statusEl = card.querySelector("[data-session-status]");
      if (statusEl) statusEl.classList.toggle("notable", NOTABLE_STATUS.has(String(session.status || "")));
      const statusDot = card.querySelector("[data-session-status] .wt-dot");
      if (statusDot) statusDot.className = `wt-dot ${sm ? sm.dot : "stop"}`;
      const statusLabel = card.querySelector(".session-status-label");
      if (statusLabel) statusLabel.textContent = sm ? sm.label : "";
    }
    // LIST_RECONCILE_END
    function sessionHistory(session) {
      if (!session || session.kind !== "agent") return null;
      let history = historyCache[session.key];
      if (!history) {
        history = historyCache[session.key] = {
          turns: (session.turns || []).slice(), cursor: session.historyCursor ?? null,
          timeline: (session.timeline || []).slice(),
          hasMore: Boolean(session.hasMoreHistory), loaded: Boolean(session.historyLoaded),
          loading: false, paged: false,
        };
      } else {
        history.turns = mergeHistoryTurns(history.turns, session.turns || []);
        history.timeline = mergeTimelineItems(history.timeline, session.timeline || []);
      }
      return history;
    }
    function formatTokens(value) {
      if (value == null || value === "" || !Number.isFinite(Number(value))) return "-";
      const amount = Number(value);
      if (amount >= 1_000_000) return `${(amount / 1_000_000).toFixed(amount >= 10_000_000 ? 0 : 1)}M`;
      if (amount >= 1_000) return `${(amount / 1_000).toFixed(amount >= 100_000 ? 0 : 1)}K`;
      return String(Math.round(amount));
    }
    function formatUsageReset(value) {
      const timestamp = Number(value);
      if (!Number.isFinite(timestamp) || timestamp <= 0) return "리셋 시각 확인 안 됨";
      return `리셋 ${new Date(timestamp * 1000).toLocaleString("ko-KR", {month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit"})}`;
    }
    function renderAccountUsage(account) {
      const windows = account && Array.isArray(account.windows) ? account.windows : [];
      const source = account && account.source;
      if (!source) {
        usageAccountRows.innerHTML = '<span class="usageUnavailable">확인 안 됨</span>';
        return;
      }
      const labels = {fiveHour: "5시간", weekly: "주간", fableWeekly: "Fable 주간"};
      const indexed = new Map(windows.map(item => [item.key, item]));
      const expected = source === "claude" ? ["fiveHour", "weekly", "fableWeekly"] : ["fiveHour", "weekly"];
      windows.forEach(item => { if (!expected.includes(item.key)) expected.push(item.key); });
      usageAccountRows.innerHTML = expected.map(key => {
        const item = indexed.get(key);
        if (!item) {
          return `<div class="usageAccountRow unavailable" data-account-usage="${esc(key)}"><span class="usageAccountLabel">${esc(labels[key] || key)}</span><span class="usageAccountValue">제공되지 않음</span><span class="usageAccountReset">현재 계정 응답에 없음</span><span class="usageAccountTrack"><span class="usageAccountFill" style="width:0%"></span></span></div>`;
        }
        const used = Number(item.usedPercent);
        const usedText = Number.isFinite(used) ? `${used.toFixed(1)}% 사용 · ${Number(item.remainingPercent).toFixed(1)}% 남음` : "확인 안 됨";
        const label = labels[item.key] || item.label || item.key || "사용량";
        const percent = Number.isFinite(used) ? Math.max(0, Math.min(100, used)) : 0;
        const level = percent >= 90 ? "critical" : percent >= 70 ? "warn" : "normal";
        return `<div class="usageAccountRow" data-level="${level}" data-account-usage="${esc(item.key || "window")}"><span class="usageAccountLabel">${esc(label)}</span><span class="usageAccountValue">${esc(usedText)}</span><span class="usageAccountReset">${esc(formatUsageReset(item.resetsAt))}</span><span class="usageAccountTrack"><span class="usageAccountFill" style="width:${percent}%"></span></span></div>`;
      }).join("");
    }
    function renderAgentUsage(session) {
      const isAgent = Boolean(session && session.kind === "agent");
      usageBtn.classList.toggle("available", isAgent);
      if (!isAgent) {
        closeUsagePanel();
        renderAccountUsage(null);
        return;
      }
      const entry = usageCache[session.key];
      const usage = entry && entry.data;
      renderAccountUsage(usage && usage.accountUsage);
      const percent = usage && Number.isFinite(Number(usage.contextPercent)) ? Number(usage.contextPercent) : null;
      usagePercent.textContent = percent == null ? "-" : `${percent.toFixed(1)}%`;
      usageUsed.textContent = formatTokens(usage && usage.usedTokens);
      usageRemaining.textContent = formatTokens(usage && usage.remainingTokens);
      usageFill.style.width = `${percent == null ? 0 : Math.max(0, Math.min(100, percent))}%`;
      usagePanel.dataset.level = percent != null && percent >= 90 ? "critical" : percent != null && percent >= 70 ? "warn" : "normal";
      usagePanel.title = usage && usage.contextWindow ? `컨텍스트 ${formatTokens(usage.usedTokens)} / ${formatTokens(usage.contextWindow)}` : "컨텍스트 한도 정보 없음";
      // 우상단 게이지에 담는다. 예전엔 입력창 위에 "컨텍스트 NN%" 한 줄을 따로 뒀는데, 그 줄은
      // 매 턴 보는 자리를 차지하면서 정작 아이콘 버튼과 같은 값을 두 번 말하고 있었다(형 지적).
      // 아이콘은 고정 문자(◔)라 값이 안 변해 아무 정보도 못 줬으므로, 아이콘 쪽을 진짜 게이지로 만든다.
      const level = percent == null ? "normal" : percent >= 90 ? "critical" : percent >= 70 ? "warn" : "normal";
      usageRing.dataset.level = level;
      usageRing.style.setProperty("--pct", String(percent == null ? 0 : Math.max(0, Math.min(100, percent))));
      usageRingNum.textContent = percent == null ? "" : String(Math.round(percent));
      usageBtn.title = percent == null ? "토큰 사용량"
        : (usage && usage.contextWindow
           ? `컨텍스트 ${percent.toFixed(0)}% · ${formatTokens(usage.usedTokens)} / ${formatTokens(usage.contextWindow)}`
           : `컨텍스트 ${percent.toFixed(0)}%`);
    }
    async function loadAgentUsage(session) {
      if (!session || session.kind !== "agent") {
        renderAgentUsage(null);
        return;
      }
      const entry = usageCache[session.key] || (usageCache[session.key] = {data: null, loading: false, loadedAt: 0});
      if (entry.loading || Date.now() - entry.loadedAt < 6000) {
        renderAgentUsage(session);
        return;
      }
      entry.loading = true;
      try {
        const params = new URLSearchParams({root: session.root, source: session.source, sid: session.sid});
        const response = await fetch(`${usageEndpoint}?${params}`, {headers: headers()});
        if (!response.ok) throw new Error(await responseError(response));
        entry.data = await response.json();
        entry.loadedAt = Date.now();
        if (selectedSessionKey === session.key) renderAgentUsage(session);
      } catch (_) {
        entry.loadedAt = Date.now();
        if (selectedSessionKey === session.key) renderAgentUsage(session);
      } finally {
        entry.loading = false;
      }
    }
    async function loadSessionMessages(session, options={}) {
      const history = sessionHistory(session);
      if (!session || !history || history.loading || (history.loaded && !options.refresh)) return;
      history.loading = true;
      try {
        const params = new URLSearchParams({root: session.root, source: session.source, sid: session.sid});
        const response = await fetch(`/mobile/api/transcript?${params}`, {headers: headers()});
        if (!response.ok) throw new Error(await response.text());
        const page = await response.json();
        const fresh = page.turns || [];
        const freshTimeline = page.timeline || timelineFromTurns(fresh);
        // 최신 로드는 서버 응답으로 교체 — 서버가 필터한 주입 메시지(Continue/task-notification 등)가
        // 클라 캐시에 눌러앉지 않게. 이전 대화(paged)를 스크롤한 상태에서만 병합을 유지한다.
        history.turns = history.paged ? mergeHistoryTurns(history.turns, fresh) : fresh;
        history.timeline = history.paged ? mergeTimelineItems(history.timeline, freshTimeline) : freshTimeline;
        if (!history.paged) {
          history.cursor = page.cursor ?? null;
          history.hasMore = Boolean(page.hasMore);
        }
        // 서버가 상한(120) 때문에 오래된 활동을 버렸으면 그렇다고 말한다 — 조용히 자르면
        // 화면의 "작업 N"이 실제보다 적어서 형이 세는 것과 안 맞는다.
        history.trimmedActivities = Number(page.trimmedActivities) || 0;
        history.loaded = true;
        if (selectedSessionKey === session.key) {
          renderTurns(session);
        }
      } finally {
        history.loading = false;
      }
    }
    async function loadOlderMessages() {
      const session = selectedSession();
      const history = sessionHistory(session);
      if (!session || !history || !history.hasMore || historyLoading || history.cursor == null) return;
      historyLoading = true;
      historyStatus.textContent = "이전 대화 불러오는 중";
      historyStatus.style.display = "flex";
      try {
        const params = new URLSearchParams({root: session.root, source: session.source, sid: session.sid, before: String(history.cursor)});
        const response = await fetch(`/mobile/api/transcript?${params}`, {headers: headers()});
        if (!response.ok) throw new Error(await response.text());
        const page = await response.json();
        history.turns = mergeHistoryTurns(history.turns, page.turns || []);
        history.timeline = mergeTimelineItems(history.timeline, page.timeline || timelineFromTurns(page.turns || []), true);
        history.cursor = page.cursor ?? null;
        history.hasMore = Boolean(page.hasMore);
        history.paged = true;
        if (selectedSessionKey === session.key) renderTurns(session);
        historyStatus.style.display = "none";
      } catch (error) {
        historyStatus.textContent = "이전 대화 로딩 실패 · 위로 스크롤해 재시도";
        historyStatus.style.display = "flex";
      } finally {
        historyLoading = false;
      }
    }
    function conversationExchanges(items) {
      const exchanges = [];
      let current = null;
      (items || []).forEach((item, index) => {
        // 턴 중간에 끼어든 메시지(큐 대기 중 = queued, 턴이 삼킨 것 = steered)는 **새 exchange 를 시작하지
        // 않는다**. 시작해 버리면 진행 중이던 어시스턴트 설명(지문)이 이전 exchange 에 남고 그 뒤의
        // 질문만 새 exchange 로 가서, 답하기 전엔 읽을 게 아무것도 없다(형: "답을 해야 질문 전에 지문이 보여").
        const startsExchange = item.kind === "message" && item.role === "user" && !item.queued && !item.steered;
        if (startsExchange) {
          if (current && current.items.length) exchanges.push(current);
          current = {id: String(item.id || `user:${index}`), user: item, items: [item]};
          return;
        }
        if (!current) current = {id: String(item.id || `leading:${index}`), user: null, items: []};
        current.items.push(item);
      });
      if (current && current.items.length) exchanges.push(current);
      return exchanges;
    }
    // 대화 안 이미지 — 타임라인엔 ref 만 오고(트랜스크립트의 base64 는 수 MB) 실제 바이트는 이 URL 로.
    // ref 는 (파일 오프셋, 블록 인덱스)라 불변이라서 브라우저 캐시가 그대로 먹는다.
    function transcriptImageUrl(ref, target) {
      const value = target || currentTargetValue();
      if (!ref || !value.startsWith("agent:")) return "";
      const [, source, sid] = value.split(":");
      const params = new URLSearchParams({root: sessionRoot(), source, sid, ref});
      if (!cookieAuth && token()) params.set("token", token());
      return `/mobile/api/transcript-image?${params}`;
    }
    // 표시 순서만 정해두고, **counts 에 있는 키는 하나도 빠뜨리지 않는다**(모르는 종류는 뒤에 붙인다).
    // 예전엔 이 목록이 하드코딩(skill·command·diff·file·agent)이라 tool/progress 로 분류되는 것들
    // (Grep · mcp__* · ToolSearch · AskUserQuestion · Glob …)이 "작업 N" 총계엔 들어가고 항목엔 안 나와
    // 합이 안 맞았다. 실측: 40세션 활동 1291개 중 165개(13%)가 사라졌고 17세션이 영향받았다.
    function exchangeShellKey(exchange, session, isLatest) {
      // 활동 목록을 **뺀** 나머지(사용자/어시스턴트 말풍선·큐·질문카드·라이브 상태). 이게 그대로면
      // 활동만 늘어난 것이므로 exchange 를 새로 만들지 않고 목록만 제자리에서 이어붙인다.
      const sections = exchangeSections(exchange);
      const question = pendingQuestionActivity(sections);
      const message = it => it ? [it.id || "", it.kind, it.role, it.text, it.model, it.effort, pendingKeyPart(it)] : 0;
      return JSON.stringify([
        isLatest,
        isLatest ? [session.status, session.controllable] : 0,
        message(sections.user),
        (sections.queued || []).map(message),
        message(sections.assistant),
        question ? [question.id || "", question.status, question.detail] : 0,
        // 답한 질문 카드는 말풍선 쪽에 그려진다 — 여기 안 넣으면 붙어도 다시 안 그린다.
        (sections.questions || []).map(item => [item.id || "", item.status, JSON.stringify(item.answers || [])]),
        Boolean((sections.activities || []).length),   // 목록의 유무가 바뀌면 골격이 달라진다
      ]);
    }
    function reconcileExchangeActivities(node, exchange) {
      // 골격이 같을 때만 불린다. 활동 목록만 제자리 갱신하고 요약 문구를 고친다.
      // 구간이 여러 개일 수 있다(설명 → 도구 → 설명 → 도구) — 순서대로 짝지어 갱신한다.
      const lists = [...node.querySelectorAll("[data-activity-list]")];
      const runs = exchangeRuns(exchange).filter(run => run.type === "activities");
      if (!lists.length || lists.length !== runs.length) return false;
      lists.forEach((listEl, index) => {
        const activities = runs[index].items;
        reconcileActivityList(listEl, activities);
        const summaryEl = listEl.parentElement && listEl.parentElement.querySelector("summary");
        if (summaryEl) {
          const next = activityGroupSummary(activities);
          if (summaryEl.textContent !== next) summaryEl.textContent = next;
        }
      });
      return true;
    }
    function reconcileAgentExchanges(exchanges, session) {
      // ③ 증분 렌더: exchange(<section data-exchange-id>) 단위로 diff — 변경된 것만 새로 만들어 교체,
      // 나머지 DOM(스크롤 위치·열린 details·로드된 이미지)은 그대로 재사용. 3s 폴마다 전량 재구성하던 것을 대체.
      const existing = new Map();
      [...turnsEl.children].forEach(node => {
        if (node.dataset && node.dataset.exchangeId) existing.set(node.dataset.exchangeId, node);
      });
      const kept = new Set();
      let cursor = null;
      exchanges.forEach((exchange, index) => {
        const isLatest = index === exchanges.length - 1;
        const id = String(exchange.id);
        const key = exchangeRenderKey(exchange, session, isLatest);
        let node = existing.get(id);
        const shell = exchangeShellKey(exchange, session, isLatest);
        if (node && node.dataset.exchangeKey !== key && node.dataset.exchangeShell === shell
            && reconcileExchangeActivities(node, exchange)) {
          node.dataset.exchangeKey = key;    // 작업만 늘었다 — 읽던 DOM 을 살린 채 목록만 이어붙였다
        } else if (!node || node.dataset.exchangeKey !== key) {
          const holder = document.createElement("div");
          holder.innerHTML = renderConversationSequence(exchange, session, isLatest);
          const fresh = holder.firstElementChild;
          fresh.dataset.exchangeKey = key;
          fresh.dataset.exchangeShell = shell;
          if (node && node.parentNode === turnsEl) turnsEl.replaceChild(fresh, node);
          node = fresh;
        }
        kept.add(node);
        const expected = cursor ? cursor.nextSibling : turnsEl.firstChild;
        if (node !== expected) turnsEl.insertBefore(node, expected);
        cursor = node;
      });
      [...turnsEl.children].forEach(node => { if (!kept.has(node)) turnsEl.removeChild(node); });
    }
    // THINKING_STATE_START  (테스트가 이 블록을 vm 에 싣는다)
    // 언제 "생각 중"을 보일까. 헤더의 작업중 표시는 대화와 떨어져 있어 와닿지 않았다.
    //  · 에이전트 대화일 때만(터미널·셸엔 '생각'이 없다)
    //  · 서버가 working 이거나, 방금 보내서 아직 서버가 못 따라잡았을 때(낙관적)
    //  · 답을 기다리는 질문이 떠 있으면 **안 보인다** — 그건 내가 아니라 형 차례다
    function thinkingLabelFor(session, optimisticWorking, now, running) {
      if (!session || session.kind !== "agent") return "";
      const status = String(session.status || "");
      if (session.pendingQuestion) return "";
      if (status !== "working" && !optimisticWorking) return "";
      // 지금 도는 일을 **한 줄 사람말로**(스펙 §3). 못 알아내면 "생각 중" 으로 떨어뜨린다 —
      // 빈 칸이 뜨면 멈춘 것처럼 보이고, 도구 이름을 그대로 쓰면 개발 화면이 된다.
      return progressLine(running) || "생각 중";
    }
    // 지금 **도는 중인** 활동만 — 진행 표시 한 줄이 이걸 사람말로 옮긴다.
    // 마지막 턴만 본다: 앞 턴의 활동은 이미 끝났고, 화면에 남아 있어도 지금 하는 일이 아니다.
    function runningActivities() {
      const session = selectedSession();
      const history = sessionHistory(session);
      const timeline = (history && history.timeline) || (session && session.timeline) || [];
      const out = [];
      for (let i = timeline.length - 1; i >= 0 && out.length < 40; i -= 1) {
        const item = timeline[i];
        if (!item) continue;
        if (item.kind === "message" && item.role === "user") break;   // 이번 턴의 시작
        if (item.status === "running") out.push(item);
      }
      return out;
    }
    // running 을 **인자로 받는다** — 안에서 화면 전역을 부르면 이 함수만 떼어 시험할 수 없다.
    function renderThinkingSlot(session, optimisticWorking, running) {
      const label = thinkingLabelFor(session, optimisticWorking, Date.now(), running);
      if (!label) {
        if (!thinkingSlot.hidden) {
          thinkingSlot.hidden = true;
          thinkingSlot.innerHTML = "";
          thinkingSlot.dataset.label = "";
          if (chatView) chatView.classList.remove("thinking");
        }
        return;
      }
      if (chatView) chatView.classList.add("thinking");   // 마지막 말풍선이 가리지 않게 자리를 연다
      // 같은 라벨이면 DOM 을 건드리지 않는다 — 매 폴마다 갈아끼우면 애니메이션이 처음으로 튄다.
      if (thinkingSlot.dataset.label === label && !thinkingSlot.hidden) return;
      thinkingSlot.dataset.label = label;
      thinkingSlot.innerHTML = renderThinking(label);
      thinkingSlot.hidden = false;
    }
    // THINKING_STATE_END
    function renderTurns(session) {
      // 펼친 <details> 기억은 렌더러가 세션별로 들고 있다 — 그릴 때마다 스코프를 맞춰 준다.
      setDetailScope(selectedSessionKey);
      if (!session) {
        turnsEl.innerHTML = "";
        turnsStructureKey = "";
        newMessagesBtn.style.display = "none";
        historyStatus.style.display = "none";
        trimNotice.style.display = "none";
        return;
      }
      const history = sessionHistory(session);
      // 상한에 걸려 버려진 활동이 있으면 눈에 보이게. 조용한 절단이 "갯수가 안 맞는다"의 절반이었다.
      const trimmed = (history && history.trimmedActivities) || 0;
      trimNotice.textContent = trimmed ? `이전 작업 ${trimmed}개는 표시 상한(${trimmed + 120}개 중 최근 120개)으로 생략됐어요` : "";
      trimNotice.style.display = trimmed ? "block" : "none";
      const serverTurns = history ? history.turns : ((session && session.turns) || []);
      const serverTimeline = history && history.timeline.length ? history.timeline : timelineFromTurns(serverTurns);
      // 확정 user 메시지 카운트 — turns 와 timeline 둘 다 보고(모바일은 timeline 렌더라 turns 가 놓칠 수 있음)
      // 텍스트는 trim 비교(큐 제출 시 공백/개행 차이로 매칭 실패해 pending 이 영영 안 지워지던 문제, 형 피드백).
      // 두 소스는 같은 메시지를 이중 계수하지 않도록 per-text 최댓값을 취한다.
      const confirmedUsers = confirmedUserCounts(serverTurns, serverTimeline);
      const rawPending = pendingTurns[selectedSessionKey] || [];
      const confirmedKeys = [...confirmedUsers.keys()];
      // 포함 매칭: 정규화해도 텍스트가 딱 안 맞을 때(래핑·잘림 등) 트랜스크립트 user 텍스트가 pending 을 포함하면 소비로 인정(6자 이상만, 오탐 방지).
      const containedIn = n => n.length >= 6 && confirmedKeys.some(k => k.includes(n));
      const isConfirmed = t => (confirmedUsers.get(normUserText(t.text)) || 0) > Number(t.baseline || 0) || containedIn(normUserText(t.text));
      // 유령 대기열 정리는 오직 확실한 신호일 때만: 더 나중에 큐된 게 이미 확정됐는데 앞선 게 미확정 →
      // 큐 FIFO 상 앞선 건 소비됐거나 드롭됨. (예전 'idle+15s' 규칙은 긴 턴 중 상태가 잠깐 완료로 읽히면
      // 정상 대기 큐를 실패로 오판해서 제거함 — 형 큐테스트가 셋 다 빨갛게 뜬 원인.)
      const latestConfirmedAt = Math.max(0, ...rawPending.filter(isConfirmed).map(t => Number(t.createdAt || 0)));
      // tid-liveness: 전달받은 PTY(state.terms)가 사라지거나 detached(재시작 후 입력 불가로 복원)면
      // 문신(영원한 대기열)을 자동 실패로 소멸시킨다.
      const liveTids = liveTidsFromTerms(state.terms);
      const now = Date.now();
      const pending = rawPending
        .map(t => reconcilePendingRecord(t, {confirmedUsers, latestConfirmedAt, liveTids, now}))
        .filter(Boolean);
      pendingTurns[selectedSessionKey] = pending;
      const pendingTimeline = pending.map((turn, index) => ({...turn, kind: "message", id: turn.id || `pending:${index}:${turn.text || ""}`}));
      const timeline = history ? serverTimeline.concat(pendingTimeline) : serverTimeline.concat(pendingTimeline).slice(-40);
      if (session && session.kind === "term" && session.preview) {
        timeline.push({kind: "message", role: "output", text: session.preview, id: "terminal-preview"});
      }
      const nextKey = JSON.stringify([session.status, timeline.map(timelineItemKeyParts)]);
      if (nextKey === turnsStructureKey) return;
      const hadTurns = Boolean(turnsStructureKey);
      const followLatestBefore = followLatest;
      const scrollAnchor = hadTurns && !followLatestBefore ? captureScrollAnchor() : null;
      if (session.kind !== "agent") {
        turnsEl.innerHTML = renderTimelineSequence(timeline);
      } else {
        reconcileAgentExchanges(conversationExchanges(timeline), session);
      }
      turnsStructureKey = nextKey;
      requestAnimationFrame(() => {
        if (!hadTurns || followLatestBefore) scrollToLatest();
        else {
          restoreScrollAnchor(scrollAnchor);
          newMessagesBtn.style.display = "block";
        }
      });
    }
    function sessionActivity(session) {
      if (!session || session.kind !== "agent") return null;
      return activityCache[session.key] || (activityCache[session.key] = {items: [], loaded: false, loading: false});
    }
    async function loadSessionActivity(session) {
      const activity = sessionActivity(session);
      if (!activity || activity.loaded || activity.loading) return;
      activity.loading = true;
      try {
        const params = new URLSearchParams({root: session.root, source: session.source, sid: session.sid});
        const response = await fetch(`/mobile/api/activity?${params}`, {headers: headers()});
        if (!response.ok) throw new Error(await response.text());
        const payload = await response.json();
        activity.items = payload.subagents || [];
        activity.loaded = true;
        if (selectedSessionKey === session.key) renderSubagents(session);
      } finally {
        activity.loading = false;
      }
    }
    function renderSubagents(session) {
      const activity = sessionActivity(session);
      const subagents = activity ? activity.items : [];
      subagentCount.textContent = activity && activity.loaded ? String(subagents.length) : "";
      subagentSessionBtn.style.display = activity ? "inline-block" : "none";
      galleryBtn.style.display = app.getAttribute("data-view") === "chat" && currentTargetValue().startsWith("agent:")
        ? "inline-block" : "none";
      if (!subagents.length) {
        const message = activity && !activity.loaded ? "불러오는 중..." : "이 세션의 작업 에이전트 기록이 없습니다.";
        updateHtmlIfChanged(subagentList, `<div class="empty-state">${message}</div>`);
        return;
      }
      const statusLabel = {running: "실행 중", completed: "완료", failed: "실패", stopped: "중지"};
      const openSubagentIds = new Set([...subagentList.querySelectorAll("details[open]")].map(item => item.getAttribute("data-subagent-id")));
      const previousScrollTop = subagentList.scrollTop;
      const html = subagents.map(agent => {
        const turns = (agent.turns || []).map(turn => `<div class="subagent-turn ${turn.role === "user" ? "user" : "assistant"}">${renderMarkdownBlocks(turn.text || "")}</div>`).join("");
        return `<details class="subagentItem" data-subagent-id="${esc(agent.id || agent.title || "")}"><summary><span class="subagentTitle">${esc(agent.title || agent.id || "Subagent")}</span><span class="subagentStatus">${esc(statusLabel[agent.status] || agent.status || "")}</span></summary><div class="subagentPreview">${renderRichText(agent.preview || "")}</div>${turns ? `<div class="subagentTurns">${turns}</div>` : ""}</details>`;
      }).join("");
      if (updateHtmlIfChanged(subagentList, html)) {
        subagentList.querySelectorAll("details").forEach(item => { item.open = openSubagentIds.has(item.getAttribute("data-subagent-id")); });
        subagentList.scrollTop = previousScrollTop;
      }
    }
    async function openSubagents() {
      const session = selectedSession();
      if (!session || session.kind !== "agent") return;
      renderSubagents(session);
      subagentSheet.classList.add("open");
      subagentSheet.setAttribute("aria-hidden", "false");
      try {
        await loadSessionActivity(session);
      } catch (error) {
        updateHtmlIfChanged(subagentList, `<div class="empty-state">서브에이전트를 불러오지 못했습니다.<br>${esc(String(error))}</div>`);
      }
    }
    function renderServiceState() {
      const labels = {running: "실행 중", starting: "시작 중", stopped: "정지", error: "오류"};
      const html = (servicesState.services || []).map(item => {
        const running = Boolean(item.running);
        const stateLabel = labels[item.state] || item.state || (running ? "실행 중" : "정지");
        const reason = item.stateReason ? ` · ${item.stateReason}` : item.port ? ` · :${item.port}` : "";
        return `<div class="serviceItem" data-service-row="${esc(item.service)}">
          <div><div class="serviceName">${esc(item.service)}</div><div class="serviceState">${esc(stateLabel + reason)}</div></div>
          <div class="serviceActions">
            ${item.openUrl ? `<button type="button" data-service-open="${esc(item.openUrl)}" title="웹 열기" aria-label="${esc(item.service)} 웹 열기">&#8599;</button>` : ""}
            ${running ? `<button type="button" data-service-action="restart" data-service="${esc(item.service)}" title="재시작" aria-label="${esc(item.service)} 재시작">&#8635;</button><button type="button" data-service-action="stop" data-service="${esc(item.service)}" title="중지" aria-label="${esc(item.service)} 중지">&#9632;</button>` : `<button type="button" data-service-action="start" data-service="${esc(item.service)}" title="시작" aria-label="${esc(item.service)} 시작">&#9654;</button>`}
          </div>
        </div>`;
      }).join("");
      updateHtmlIfChanged(serviceList, html || '<div class="empty-state">이 워크트리에 정의된 서비스가 없습니다.</div>');
    }
    async function loadServices(force=false) {
      const root = servicesRoot || sessionRoot();
      if (!root || serviceLoading) return;
      if (!force && servicesState.root === root && Date.now() - serviceLoadedAt < 8000) {
        renderServiceState();
        return;
      }
      serviceLoading = true;
      try {
        const params = new URLSearchParams({root});
        const response = await fetch(`/mobile/api/services?${params}`, {headers: headers()});
        if (!response.ok) throw new Error(await response.text());
        servicesState = await response.json();
        serviceLoadedAt = Date.now();
        renderServiceState();
      } catch (error) {
        if (servicesSheet.classList.contains("open")) {
          serviceList.innerHTML = `<div class="empty-state">서비스 상태를 불러오지 못했습니다.<br>${esc(String(error))}</div>`;
        }
      } finally {
        serviceLoading = false;
      }
    }
    async function runServiceAction(service, action) {
      const button = serviceList.querySelector(`[data-service="${CSS.escape(service)}"][data-service-action="${CSS.escape(action)}"]`);
      if (button) button.disabled = true;
      try {
        const response = await fetch("/mobile/api/services/action", {
          method: "POST", headers: headers(true),
          body: JSON.stringify({root: servicesRoot || sessionRoot(), service, action}),
        });
        if (!response.ok) throw new Error(await response.text());
        showToast(action === "stop" ? `${service} 중지 요청` : action === "restart" ? `${service} 재시작 요청` : `${service} 시작 요청`);
        serviceLoadedAt = 0;
        setTimeout(() => loadServices(true), action === "stop" ? 300 : 900);
      } catch (error) {
        showToast(`서비스 제어 실패 · ${String(error)}`);
      } finally {
        if (button) button.disabled = false;
      }
    }
    // 서비스는 **워크트리 소속**이다. 드로어엔 여러 워크트리 세션이 섞여 있어서 전역 버튼 하나로는
    // "어느 워크트리 서버인지" 알 수가 없다(형 지적). 그래서 어느 root 를 보는지 명시적으로 받는다.
    function openServices(root) {
      servicesRoot = String(root || servicesRoot || sessionRoot() || selectedRoot() || "");
      servicesSheetTitle.textContent = servicesRoot
        ? `서비스 · ${wtName(servicesRoot)}` : "서비스";
      closeDrawer();   // 시트를 열면 드로어는 접는다(오버레이 두 장이 겹쳐 탭이 엉키는 걸 막는다)
      closeInbox();
      closeSettings();
      servicesSheet.classList.add("open");
      servicesSheet.setAttribute("aria-hidden", "false");
      loadServices(true);
    }
    // ── 로그·깃 시트 (읽기 전용) ──
    // 모바일엔 둘 다 없어서 밖에서 "빌드 깨졌나"를 확인할 방법이 없었다. 서버는 웹과 같은 함수를
    // 쓰고(/mobile/api/logs/*, /mobile/api/git-*), 여기는 표시만 한다. 쓰기(커밋·푸시·머지)는 없다.
    const logsSheet = document.getElementById("logsSheet");
    const logsBody = document.getElementById("logsBody");
    const logsService = document.getElementById("logsService");
    const logsRun = document.getElementById("logsRun");
    const logsFilter = document.getElementById("logsFilter");
    const logsErrOnly = document.getElementById("logsErrOnly");
    const gitSheet = document.getElementById("gitSheet");
    const gitStatusEl = document.getElementById("gitStatus");
    const gitBody = document.getElementById("gitBody");
    let logsRoot = "";
    let logsTimer = null;
    let logsErr = false;
    let logsServices = [];

    // run 은 서버가 'current' 또는 'run-NNN.log' 만 받는다(marina_paths.selected_log). 임의 문자열은
    // 400 이라, 웹과 같은 출처(서비스의 logRuns)로만 채운다.
    function renderLogRuns() {
      const svc = logsServices.find(x => String(x.service || "") === logsService.value);
      const runs = (svc && svc.logRuns) || [];
      logsRun.innerHTML = '<option value="current">현재 run</option>'
        + runs.map(r => `<option value="${esc(r.id)}">${esc(r.label || r.id)}</option>`).join("");
    }

    function logsOpen() { return logsSheet.classList.contains("open"); }
    function closeLogs() {
      logsSheet.classList.remove("open");
      logsSheet.setAttribute("aria-hidden", "true");
      clearInterval(logsTimer); logsTimer = null;
    }
    async function openLogs(root) {
      logsRoot = String(root || logsRoot || sessionRoot() || selectedRoot() || "");
      document.getElementById("logsSheetTitle").textContent = `로그 · ${wtName(logsRoot)}`;
      closeDrawer(); closeInbox(); closeSettings();
      logsSheet.classList.add("open");
      logsSheet.setAttribute("aria-hidden", "false");
      logsBody.textContent = "불러오는 중…";
      await loadLogServices();
      await loadLogChunk();
      clearInterval(logsTimer);
      // 시트가 열려 있을 때만 3초 폴 — 닫으면 멈춘다(배터리·데이터).
      logsTimer = setInterval(() => { if (logsOpen()) loadLogChunk().catch(() => {}); }, 3000);
    }
    async function loadLogServices() {
      try {
        const r = await fetch(`/mobile/api/services?root=${encodeURIComponent(logsRoot)}`, {headers: headers()});
        if (!r.ok) throw new Error(await responseError(r));
        const d = await r.json();
        logsServices = d.services || [];
        const names = logsServices.map(x => String(x.service || "")).filter(Boolean);
        const keep = logsService.value;
        logsService.innerHTML = names.map(n => `<option value="${esc(n)}">${esc(n)}</option>`).join("")
          || '<option value="">(서비스 없음)</option>';
        if (names.includes(keep)) logsService.value = keep;
      } catch (error) { logsService.innerHTML = '<option value="">(목록 실패)</option>'; }
      renderLogRuns();
    }
    function logLineHtml(line) {
      const err = /\b(error|fail(ed|ure)?|exception|traceback|fatal)\b/i.test(line);
      return `<div class="${err ? "lgErr" : ""}">${esc(line)}</div>`;
    }
    async function loadLogChunk() {
      const service = logsService.value;
      if (!service) { logsBody.textContent = "서비스를 고르세요"; return; }
      const q = logsFilter.value.trim();
      const base = `root=${encodeURIComponent(logsRoot)}&service=${encodeURIComponent(service)}&run=${encodeURIComponent(logsRun.value || "current")}`;
      const atBottom = logsBody.scrollHeight - logsBody.scrollTop - logsBody.clientHeight < 40;
      try {
        let lines;
        if (q || logsErr) {
          const r = await fetch(`/mobile/api/logs/matches?${base}&q=${encodeURIComponent(q)}&errOnly=${logsErr ? 1 : 0}`, {headers: headers()});
          if (!r.ok) throw new Error(await responseError(r));
          const d = await r.json();
          lines = (d.matches || []).map(m => String(m.t ?? ""));
          if (!lines.length) lines = ["(일치하는 줄 없음)"];
        } else {
          // 두 번 부른다: 먼저 size 를 알아야 tail 을 집을 수 있다(before=0 은 0바이트 청크).
          const head = await fetch(`/mobile/api/logs/chunk?${base}&after=0`, {headers: headers()});
          if (!head.ok) throw new Error(await responseError(head));
          const meta = await head.json();
          const size = Number(meta.size || 0);
          let chunk = meta;
          if (size > Number(meta.end || 0)) {
            const tail = await fetch(`/mobile/api/logs/chunk?${base}&before=${size}`, {headers: headers()});
            if (tail.ok) chunk = await tail.json();
          }
          lines = (chunk.lines || []).map(item => String(item.t ?? ""));
        }
        logsBody.innerHTML = lines.slice(-800).map(logLineHtml).join("");
        if (atBottom) logsBody.scrollTop = logsBody.scrollHeight;
      } catch (error) {
        logsBody.textContent = `로그 실패 · ${String(error)}`;
      }
    }
    logsService.onchange = () => { renderLogRuns(); loadLogChunk().catch(() => {}); };
    logsRun.onchange = () => loadLogChunk().catch(() => {});
    logsFilter.oninput = () => loadLogChunk().catch(() => {});
    logsErrOnly.onclick = () => {
      logsErr = !logsErr;
      logsErrOnly.classList.toggle("on", logsErr);
      loadLogChunk().catch(() => {});
    };
    document.getElementById("logsCloseBtn").onclick = closeLogs;
    logsSheet.onclick = event => { if (event.target === logsSheet) closeLogs(); };

    function closeGit() {
      gitSheet.classList.remove("open");
      gitSheet.setAttribute("aria-hidden", "true");
    }
    function diffHtml(text) {
      return String(text || "").split("\n").map(line => {
        const cls = line.startsWith("+") ? "add" : line.startsWith("-") ? "del"
          : line.startsWith("@@") ? "hunk" : "";
        return `<span class="${cls}">${esc(line)}</span>`;
      }).join("\n");
    }
    async function openGit(root) {
      const target = String(root || sessionRoot() || selectedRoot() || "");
      gitSheet.dataset.root = target;
      document.getElementById("gitSheetTitle").textContent = `깃 · ${wtName(target)}`;
      closeDrawer(); closeInbox(); closeSettings();
      gitSheet.classList.add("open");
      gitSheet.setAttribute("aria-hidden", "false");
      gitStatusEl.textContent = "불러오는 중…";
      gitBody.innerHTML = "";
      const q = `root=${encodeURIComponent(target)}`;
      try {
        const [wipRes, graphRes] = await Promise.all([
          fetch(`/mobile/api/git-wip-stat?${q}`, {headers: headers()}),
          fetch(`/mobile/api/git-graph?${q}`, {headers: headers()}),
        ]);
        if (!wipRes.ok) throw new Error(await responseError(wipRes));
        const wip = await wipRes.json();
        const graph = graphRes.ok ? await graphRes.json() : {};
        // 실제 스키마: wip.files = [{name, add, del, untracked}], graph.commits = [{hash, subject, ts, author}],
        // graph.branches = [{branch, head, root, ...}]. 이 워크트리의 브랜치는 root 로 찾는다.
        const files = wip.files || [];
        const mine = (graph.branches || []).find(b => b.root === target) || {};
        gitStatusEl.textContent = [
          mine.branch ? `브랜치 ${mine.branch}` : "",
          files.length ? `변경 ${files.length}개` : "변경 없음",
          Number(mine.ahead) ? `↑${mine.ahead}` : "", Number(mine.behind) ? `↓${mine.behind}` : "",
        ].filter(Boolean).join(" · ");
        const rows = files.map(f => {
          const path = String(f.name || "");
          const stat = [Number(f.add) ? `+${f.add}` : "", Number(f.del) ? `-${f.del}` : "",
                        f.untracked ? "new" : ""].filter(Boolean).join(" ");
          return `<div class="gitRow" data-git-file="${esc(path)}"><span class="nm">${esc(path)}</span><span class="st">${esc(stat)}</span></div>`;
        }).join("");
        const commits = (graph.commits || []).slice(0, 30).map(c =>
          `<div class="gitRow" data-git-commit="${esc(c.hash || "")}"><span class="nm">${esc(c.subject || "")}</span><span class="st">${esc(String(c.hash || "").slice(0, 7))}</span></div>`).join("");
        gitBody.innerHTML = (rows ? `<div class="gitSect">변경 파일</div>${rows}` : "")
          + (commits ? `<div class="gitSect">최근 커밋</div>${commits}` : "");
      } catch (error) {
        gitStatusEl.textContent = `깃 실패 · ${String(error)}`;
      }
    }
    // 파일 = diff 펼치기, 커밋 = 파일 목록 펼치기. 둘 다 읽기 전용이다.
    gitBody.onclick = async event => {
      const row = event.target.closest && event.target.closest("[data-git-file], [data-git-commit]");
      if (!row) return;
      const open = row.nextElementSibling && row.nextElementSibling.classList.contains("gitDiff");
      if (open) { row.nextElementSibling.remove(); return; }
      const target = gitSheet.dataset.root || "";
      const holder = document.createElement("div");
      holder.className = "gitDiff";
      holder.textContent = "불러오는 중…";
      row.insertAdjacentElement("afterend", holder);
      try {
        const file = row.getAttribute("data-git-file");
        const url = file
          ? `/mobile/api/git-diff?root=${encodeURIComponent(target)}&file=${encodeURIComponent(file)}`
          : `/mobile/api/git-commit-info?root=${encodeURIComponent(target)}&commit=${encodeURIComponent(row.getAttribute("data-git-commit") || "")}`;
        const r = await fetch(url, {headers: headers()});
        if (!r.ok) throw new Error(await responseError(r));
        const d = await r.json();
        holder.innerHTML = file
          ? diffHtml(d.diff || d.text || "(내용 없음)")
          : esc((d.files || []).map(f => `${f.name}  +${f.add} -${f.del}`).join("\n") || "(파일 없음)");
      } catch (error) { holder.textContent = `실패 · ${String(error)}`; }
    };
    document.getElementById("gitCloseBtn").onclick = closeGit;
    gitSheet.onclick = event => { if (event.target === gitSheet) closeGit(); };

    // ── CLI(claude/codex) 버전 배너 ──
    // 새 버전은 터미널에서 CLI 를 띄울 때만 보였다 — 모바일엔 터미널이 아예 없다.
    const cliUpdateBanner = document.getElementById("cliUpdateBanner");
    let cliUpdateBusy = false;
    async function loadCliUpdate() {
      if (cliUpdateBusy) return;
      try {
        const r = await fetch("/mobile/api/update-status", {headers: headers()});
        if (!r.ok) return;
        const cli = (await r.json()).cli || {};
        const behind = Object.keys(cli).filter(h => cli[h] && cli[h].behind);
        if (!behind.length) { cliUpdateBanner.hidden = true; return; }
        const h = behind[0];
        cliUpdateBanner.hidden = false;
        cliUpdateBanner.textContent = `${h} ${cli[h].installed} → ${cli[h].latest} · 탭하여 받기`;
        cliUpdateBanner.dataset.harness = h;
      } catch (error) { /* 조용히 — 배너가 없는 게 오탐보다 낫다 */ }
    }
    cliUpdateBanner.onclick = async () => {
      const harness = cliUpdateBanner.dataset.harness || "";
      if (!harness || cliUpdateBusy) return;
      cliUpdateBusy = true;
      const before = cliUpdateBanner.textContent;
      cliUpdateBanner.textContent = `${harness} 받는 중…`;
      try {
        const r = await fetch("/mobile/api/cli-update", {method: "POST", headers: headers(true),
                                                         body: JSON.stringify({harness})});
        if (r.status === 409) {
          const d = await r.json().catch(() => ({}));
          showToast(`${harness} 세션 ${(d.busy || []).length}개 작업 중 — 끝나면 받아요`);
          cliUpdateBanner.textContent = before;
          return;
        }
        if (!r.ok) throw new Error(await responseError(r));
        const d = await r.json();
        showToast(`${harness} ${d.installed || ""} 로 업데이트했어요`);
        cliUpdateBanner.hidden = true;
      } catch (error) {
        showToast(`업데이트 실패 · ${String(error)}`);
        cliUpdateBanner.textContent = before;
      } finally {
        cliUpdateBusy = false;
      }
    };

    function sessionStatusText(session) {
      if (!session || session.kind !== "agent") return "";
      let text = agentStatusMeta(session.status).label;   // 웹과 통일된 라벨(idle=유휴 등)
      if (session.status === "working" && session.statusTs) {
        const elapsed = Math.max(0, Math.round(Date.now() / 1000 - Number(session.statusTs)));
        text += elapsed < 60 ? ` · ${elapsed}초` : ` · ${Math.floor(elapsed / 60)}분`;
      }
      if (session.status === "working" && session.externalActive && !session.controllable) text += " · 외부에서 실행 중";
      return text;
    }
    function renderSessionControls(session) {
      const isAgent = Boolean(session && session.kind === "agent");
      settingsBtn.style.display = isAgent ? "inline-block" : "none";
      if (isAgent) {
        const current = (session.settings && session.settings.current) || {model: "", effort: ""};
        const pending = (session.settings && session.settings.pending) || {model: "", effort: ""};
        const currentLabel = `${current.model ? displayModel(current.model) : "기본 모델"}${current.effort ? ` · ${current.effort}` : ""}`;
        const pendingLabel = pending.model || pending.effort ? ` → 다음 ${pending.model ? displayModel(pending.model) : "기본 모델"}${pending.effort ? ` · ${pending.effort}` : ""}` : "";
        settingsBtn.textContent = `${currentLabel}${pendingLabel}`;   // 모델명이 브랜드 포함이라 소스접두 생략(중복 방지)
      }
      if (isAgent && session.status === "working") optimisticWorkUntil = 0;   // 실제 working 잡히면 낙관 해제
      const optimisticWorking = isAgent && optimisticWorkUntil > Date.now() && session.status !== "working";
      // 정지버튼은 실제 working + 라이브 tid 있을 때만 — 낙관적으로 띄우면 tid 없어 '중단 실패' 유발.
      const running = isAgent && session.controllable && session.status === "working";
      stopBtn.style.display = running ? "inline-block" : "none";
      if (!sending) statusEl.textContent = optimisticWorking ? "작업 중…" : sessionStatusText(session);
      renderThinkingSlot(session, optimisticWorking, runningActivities());   // 대화 안에서도 같은 사실을 보여준다
      renderDoneSlot(session);
      renderLiveQuestion(session);
    }
    function sourceOptions(session) {
      return (state.agentOptions || {})[sessionSource(session)] || {models: [], efforts: [], manualModel: true};
    }
    function updateEffortChoices(session, selected="") {
      const options = sourceOptions(session);
      const model = modelSelect.value === "__custom__" ? customModelInput.value.trim() : modelSelect.value;
      const modelItem = (options.models || []).find(item => item.value === model);
      const efforts = (modelItem && modelItem.efforts && modelItem.efforts.length) ? modelItem.efforts : (options.efforts || []);
      effortSelect.innerHTML = `<option value="">CLI 기본값</option>${efforts.map(value => `<option value="${esc(value)}">${esc(value)}</option>`).join("")}`;
      if ([...effortSelect.options].some(item => item.value === selected)) effortSelect.value = selected;
    }
    function openSettings() {
      const session = selectedSession();
      if (!session || session.kind !== "agent") return;
      closeServices();
      const options = sourceOptions(session);
      const current = (session.settings && session.settings.current) || {model: "", effort: ""};
      const pending = (session.settings && session.settings.pending) || {model: "", effort: ""};
      const selected = pending.model || pending.effort ? pending : current;
      const known = (options.models || []).some(item => item.value === selected.model);
      modelSelect.innerHTML = `<option value="">CLI 기본값</option>${(options.models || []).map(item => `<option value="${esc(item.value)}">${esc(item.label || item.value)}</option>`).join("")}<option value="__custom__">직접 입력</option>`;
      modelSelect.value = selected.model && known ? selected.model : selected.model ? "__custom__" : "";
      customModelInput.value = selected.model && !known ? selected.model : "";
      customModelLabel.style.display = modelSelect.value === "__custom__" ? "flex" : "none";
      updateEffortChoices(session, selected.effort || "");
      settingsSheet.classList.add("open");
      settingsSheet.setAttribute("aria-hidden", "false");
    }
    async function saveSettings() {
      const session = selectedSession();
      if (!session || session.kind !== "agent") return;
      const model = modelSelect.value === "__custom__" ? customModelInput.value.trim() : modelSelect.value;
      const effort = effortSelect.value;
      const response = await fetch("/mobile/api/settings", {
        method: "POST", headers: headers(true),
        body: JSON.stringify({root: session.root, source: session.source, sid: session.sid, model, effort}),
      });
      if (!response.ok) throw new Error(await response.text());
      const result = await response.json();
      session.settings = session.settings || {current: {model: "", effort: ""}, pending: {model: "", effort: ""}};
      const settings = {model: result.model || "", effort: result.effort || ""};
      if (result.applyMode === "live") {
        session.settings.current = settings;
        session.settings.pending = {model: "", effort: ""};
      } else {
        session.settings.pending = settings;
      }
      closeSettings();
      renderSessionControls(session);
      showToast(result.applyMode === "live" ? "현재 CLI에 적용했습니다"
                : result.pendingReason === "busy" ? "작업 중이라 이번 응답이 끝난 뒤 적용합니다"
                : result.pendingReason === "unverified" ? "적용 확인이 안 돼요 — 잠시 후 자동 재시도합니다"
                : "다음 Marina 연결에 적용합니다");
    }
    async function interruptCurrentTurn() {
      const session = selectedSession();
      if (!session || !session.controllable) return;
      stopBtn.disabled = true;
      try {
        const response = await fetch("/mobile/api/interrupt", {
          method: "POST", headers: headers(true),
          body: JSON.stringify({root: session.root, target: session.target}),
        });
        if (!response.ok) throw new Error(await response.text());
        statusEl.textContent = "중단 요청됨";
        showToast("현재 응답을 중단했습니다");
        setTimeout(() => load({quiet: true}), 400);
      } catch (error) {
        // 대개 턴이 이미 끝나 라이브 PTY 가 없는 경우 — 놀랄 에러 대신 조용히 상태만 갱신.
        showToast("중단할 작업이 없어요 (이미 끝났을 수 있어요)");
        load({quiet: true}).catch(() => {});
      } finally {
        stopBtn.disabled = false;
      }
    }
    function inboxEventId(session) {
      return `${session.source || ""}:${session.sid || ""}:${session.status || "idle"}:${session.statusTs || session.ts || 0}`;
    }
    function inboxSessions() {
      const actionable = new Set(["blocked", "waiting", "completed", "failed"]);
      return (state.sessions || []).filter(session => session.kind === "agent" && session.sid && actionable.has(session.status))
        .map(session => ({...session, eventId: inboxEventId(session)}))
        .sort((a, b) => Number(b.statusTs || b.ts || 0) - Number(a.statusTs || a.ts || 0))
        .slice(0, 50);
    }
    function inboxRelativeTime(ts) {
      const seconds = Math.max(0, Date.now() / 1000 - Number(ts || 0));
      if (seconds < 90) return "지금";
      if (seconds < 3600) return `${Math.round(seconds / 60)}분`;
      if (seconds < 86400) return `${Math.round(seconds / 3600)}시간`;
      return `${Math.round(seconds / 86400)}일`;
    }
    function persistInboxRead() {
      localStorage.setItem(inboxReadKey, JSON.stringify([...inboxRead].slice(-300)));
    }
    function renderInbox() {
      const items = inboxSessions();
      const unread = items.filter(item => !inboxRead.has(item.eventId)).length;
      inboxCount.textContent = unread > 99 ? "99+" : String(unread);
      inboxMenuBtn.title = unread ? `새 작업 ${unread}개` : "확인할 새 작업 없음";
      if (!inboxSheet.classList.contains("open")) return;
      const statusLabel = {blocked: "응답 필요", waiting: "응답 대기", completed: "완료", failed: "실패"};
      let previousProject = "";
      const html = items.map(item => {
        const wt = worktreeForRoot(item.root);
        const project = wt ? projectName(wt) : (item.subtitle || "Project");
        const group = project !== previousProject ? `<div class="inboxGroup">${esc(project)}</div>` : "";
        previousProject = project;
        const source = sessionSource(item);
        const meta = sourceMeta[source];
        return `${group}<button class="inboxItem ${inboxRead.has(item.eventId) ? "read" : "unread"}" type="button" data-inbox-id="${esc(item.eventId)}">
          <span class="source-badge ${source}">${meta.badge}</span>
          <span class="inboxItemCopy"><strong>${esc(item.title || item.sid)}</strong><small>${esc(item.preview || item.subtitle || "")}</small></span>
          <span class="inboxState">${esc(statusLabel[item.status] || item.status)} · ${esc(inboxRelativeTime(item.statusTs || item.ts))}</span>
        </button>`;
      }).join("");
      updateHtmlIfChanged(inboxList, html || '<div class="empty-state">확인할 에이전트 작업이 없습니다.</div>');
    }
    function openInbox() {
      closeSubagents();
      closeServices();
      inboxSheet.classList.add("open");
      inboxSheet.setAttribute("aria-hidden", "false");
      renderInbox();
    }
    function selectInboxSession(eventId) {
      const item = inboxSessions().find(session => session.eventId === eventId);
      if (!item) return;
      inboxRead.add(eventId);
      persistInboxRead();
      closeInbox();
      chooseSession(item.key);
    }
    function triggerAtCursor() {
      const cursor = promptInput.selectionStart;
      const before = promptInput.value.slice(0, cursor);
      const match = before.match(/(^|\s)([\/@$][^\s]*)$/);
      if (!match) return null;
      const token = match[2];
      return {trigger: token[0], query: token.slice(1).toLowerCase(), start: cursor - token.length, end: cursor};
    }
    function sessionCatalog(session) {
      if (!session || session.kind !== "agent") return {skills: [], agents: [], loaded: true, loading: false};
      const key = `${session.root}|${session.source}`;
      return catalogCache[key] || (catalogCache[key] = {skills: [], agents: [], loaded: false, loading: false});
    }
    async function loadNativeCatalog(session) {
      const catalog = sessionCatalog(session);
      if (!session || session.kind !== "agent" || catalog.loaded || catalog.loading) return;
      catalog.loading = true;
      try {
        const params = new URLSearchParams({root: session.root, source: session.source});
        const response = await fetch(`${catalogEndpoint}?${params}`, {headers: headers()});
        if (!response.ok) throw new Error(await response.text());
        const payload = await response.json();
        catalog.skills = payload.skills || [];
        catalog.agents = payload.agents || [];
        catalog.loaded = true;
        if (selectedSessionKey === session.key && document.activeElement === promptInput) renderSuggestions();
      } finally {
        catalog.loading = false;
      }
    }
    function suggestionItems(trigger) {
      const session = selectedSession();
      const source = sessionSource(session);
      const catalog = sessionCatalog(session);
      let items = [];
      if (source === "claude" && trigger.trigger === "/") items = (catalog.skills || []).map(item => ({...item, kind: "skill"}));
      else if (source === "claude" && trigger.trigger === "@") items = (catalog.agents || []).map(item => ({...item, kind: "agent"})).concat(fileSuggestions.map(item => ({...item, kind: "file"})));
      else if (source === "codex" && trigger.trigger === "$") items = (catalog.skills || []).map(item => ({...item, kind: "skill"}));
      else if (source === "codex" && trigger.trigger === "@") items = fileSuggestions.map(item => ({...item, kind: "file"}));
      return items.filter(item => !trigger.query || [item.name, item.description].some(value => String(value || "").toLowerCase().includes(trigger.query))).slice(0, 16);
    }
    function renderSuggestions() {
      const trigger = triggerAtCursor();
      if (!trigger || !selectedSession() || selectedSession().kind !== "agent") {
        closeSuggestions();
        return;
      }
      const source = sessionSource(selectedSession());
      const nativeTrigger = (source === "claude" && ["/", "@"].includes(trigger.trigger)) || (source === "codex" && ["$", "@"].includes(trigger.trigger));
      if (!nativeTrigger) {
        closeSuggestions();
        return;
      }
      const catalog = sessionCatalog(selectedSession());
      if (!catalog.loaded) loadNativeCatalog(selectedSession()).catch(() => {});
      suggestionRange = trigger;
      const items = suggestionItems(trigger);
      suggestionsEl.innerHTML = items.map((item, index) => `<button class="suggestion" type="button" role="option" data-suggestion="${index}" data-insert="${esc(item.insert)}"><span><span class="suggestion-name">${esc(item.insert || item.name)}</span><span class="suggestion-description">${esc(item.description === item.kind ? "" : item.description || "")}</span></span><span class="suggestion-kind">${esc(item.kind)}</span></button>`).join("");
      suggestionsEl.classList.toggle("open", Boolean(items.length));
      if (trigger.trigger === "@" && trigger.query) scheduleFileSuggestions(trigger.query, source);
    }
    function scheduleFileSuggestions(query, source) {
      const root = sessionRoot();
      const sessionKey = selectedSessionKey;
      const key = `${root}|${source}|${query}`;
      if (fileSuggestionKey === key) return;
      fileSuggestionKey = key;
      clearTimeout(fileSuggestionTimer);
      fileSuggestionTimer = setTimeout(async () => {
        const params = new URLSearchParams({root, source, q: query});
        try {
          const response = await fetch(`${catalogEndpoint}?${params}`, {headers: headers()});
          if (!response.ok) return;
          const result = await response.json();
          const current = triggerAtCursor();
          if (selectedSessionKey !== sessionKey || selectedRoot() !== root || sessionSource(selectedSession()) !== source) return;
          if (!current || current.trigger !== "@" || current.query !== query) return;
          fileSuggestions = result.files || [];
          renderSuggestions();
        } catch (_) {
          if (fileSuggestionKey === key && selectedSessionKey === sessionKey && sessionRoot() === root && sessionSource(selectedSession()) === source) {
            fileSuggestions = [];
          }
        }
      }, 180);
    }
    function insertSuggestion(value) {
      if (!suggestionRange || !value) return;
      const before = promptInput.value.slice(0, suggestionRange.start);
      const after = promptInput.value.slice(suggestionRange.end);
      promptInput.value = `${before}${value} ${after}`;
      const cursor = before.length + value.length + 1;
      promptInput.setSelectionRange(cursor, cursor);
      saveDraft();
      autoGrowComposer();
      closeSuggestions();
      promptInput.focus();
    }
    function render() {
      const previousRoot = localStorage.getItem("marinaMobileRoot") || rootSelect.value;
      rootSelect.innerHTML = state.worktrees.map(w => `<option value="${esc(w.root)}">${esc(labelWt(w))}</option>`).join("");
      if ([...rootSelect.options].some(o => o.value === previousRoot)) rootSelect.value = previousRoot;
      const root = selectedRoot();
      const wt = state.worktrees.find(w => w.root === root) || {agents: []};
      const terms = state.terms.filter(t => t.root === root);
      const opts = [`<option value="shell">새 셸에 보내기</option>`]
        .concat((wt.agents || []).map(a => `<option value="agent:${esc(a.source)}:${esc(a.sid)}">${esc(a.source)} · ${esc(a.title || a.sid)}</option>`))
        .concat(terms.map(t => `<option value="term:${esc(t.tid)}">터미널 · ${esc(t.fg || t.cmd || t.preview || t.tid)}</option>`));
      const prevTarget = localStorage.getItem(targetKey(root)) || localStorage.getItem("marinaMobileTarget") || targetSelect.value;
      targetSelect.innerHTML = opts.join("");
      if ([...targetSelect.options].some(o => o.value === prevTarget)) targetSelect.value = prevTarget;
      renderProjectTabs();
      renderSourceTabs();
      renderSessions();
      // 방 목록이 첫 화면이다(형 결정). 세션 목록은 지우지 않고 숨겨만 둔다 — 방 화면이
      // 이상하면 이 두 줄만 되돌리면 예전 화면으로 돌아간다.
      renderRoomList();
      renderInbox();
      const live = selectedSession();
      if (live) { heldSession = live; heldSessionAt = Date.now(); }
      const session = holdSession(live, heldSession, heldSessionAt, selectedSessionKey, Date.now(), SESSION_HOLD_MS);
      if (session) showChat();
      else showList();
      chatNavTitle.textContent = session ? (session.title || "세션") : "";
      renderSessionTabs();
      renderAgentUsage(session);
      restoreDraft();
      renderTurns(session);
      renderSubagents(session);
      renderSessionControls(session);
      const source = sessionSource(session);
      promptInput.placeholder = source === "claude" ? "Claude에 메시지" : source === "codex" ? "Codex에 메시지" : "터미널에 입력";
      if (document.activeElement === promptInput) renderSuggestions();
      loadServices(false);
      loadAgentUsage(session);
    }
    async function load(options={}) {
      if (!cookieAuth && !token()) {
        showLogin("mobile token을 입력하세요.");
        return;
      }
      if (options.quiet && isEditing()) return;
      if (loading) return;
      loading = true;
      try {
        if (!options.quiet) statusEl.textContent = "불러오는 중...";
        const r = await fetch(`/mobile/api/state${showAll ? "?all=1" : ""}`, {headers: headers()});
        if (r.status === 401) {
          location.replace("/login?next=%2Fmobile");
          return;
        }
        if (r.status === 403) {
          localStorage.removeItem("marinaMobileToken");
          showLogin("token이 맞지 않거나 mobile이 꺼져 있습니다.");
          return;
        }
        if (!r.ok) throw new Error(await r.text());
        state = await r.json();
        pinnedRoots = new Set(state.pins || []);
        hiddenSessions = new Set(state.hidden || []);
        migrateSelectionOnPromotion();
        // 데몬 재시작(새 버전) 감지 → full-reload 를 강제하지 않고 배너만 띄운다(형 탭할 때 리로드).
        // 재방문 폴링마다 location.reload() 를 때리면 스크롤·작업중 상태가 다 풀렸음.
        if (state.serverInstance) {
          if (serverInstance && serverInstance !== state.serverInstance) {
            // 데몬이 새 버전으로 떴다 = 이 페이지의 JS 는 낡았다. 배너만 띄우면 형이 못 보고 계속 쓰다가
            // "고쳤다는데 왜 그대로냐"가 반복된다(실제로 세 번 겪었다). **안전할 때만** 스스로 새로고침한다:
            // 입력 중도 아니고, 보내는 중도 아니고, 질문 카드를 고르는 중도 아닐 때.
            const busyTyping = Boolean(promptInput.value.trim()) || document.activeElement === promptInput;
            const answering = Boolean(liveAnswer.sending || (liveAnswer.choices || []).some(v => v && v.length));
            if (!busyTyping && !sending && !answering) { location.reload(); return; }
            updateBanner.style.display = "block";   // 지금은 위험 — 형이 직접 탭하게 둔다
          } else if (!serverInstance) serverInstance = state.serverInstance;
        }
        showApp();
        render();
        await loadSessionMessages(selectedSession(), {refresh: Boolean(options.quiet)});
        if (!options.quiet && !selectedSession()) statusEl.textContent = "준비됨";
      } finally {
        loading = false;
      }
    }
    const attachBtn = document.getElementById("attachBtn");
    const fileInput = document.getElementById("fileInput");
    const attachStrip = document.getElementById("attachStrip");
    let pendingAttachments = [];   // [{id, name, path, url, isImage, uploading, failed}]
    function uploadServeUrl(nameOrPath) {
      const stored = String(nameOrPath || "").split("/").pop();
      let url = `/mobile/api/file?name=${encodeURIComponent(stored)}`;
      if (!cookieAuth && token()) url += `&token=${encodeURIComponent(token())}`;
      return url;
    }
    function renderAttachStrip() {
      attachStrip.innerHTML = pendingAttachments.map(a => {
        const thumb = a.isImage && a.url ? `<img src="${esc(a.url)}" alt="" />` : "";
        const del = a.uploading ? "" : `<button class="attachDel" type="button" data-attach-del="${esc(a.id)}" aria-label="첨부 제거">&#215;</button>`;
        return `<span class="attachChip${a.uploading ? " uploading" : ""}${a.failed ? " failed" : ""}">${thumb}<span class="attachName">${esc(a.failed ? "실패 · " + a.name : a.name)}</span>${del}</span>`;
      }).join("");
    }
    async function uploadFiles(files) {
      const root = sessionRoot();
      if (!root) { showToast("워크트리를 먼저 선택하세요"); return; }
      for (const file of files) {
        const id = `att-${Date.now()}-${Math.round(performance.now() * 1000) % 100000}-${pendingAttachments.length}`;
        const entry = {id, name: file.name || "file", path: "", url: "", isImage: IMAGE_EXT_RE.test(file.name || ""), uploading: true, failed: false};
        pendingAttachments.push(entry);
        renderAttachStrip();
        try {
          const params = new URLSearchParams({root, filename: file.name || "file"});
          const r = await fetch(`/mobile/api/upload?${params}`, {
            method: "POST",
            headers: {...headers(true), "content-type": "application/octet-stream", "x-marina-filename": encodeURIComponent(file.name || "file")},
            body: file,
          });
          if (!r.ok) throw new Error(await responseError(r));
          const d = await r.json();
          entry.path = d.path; entry.url = d.url || uploadServeUrl(d.stored); entry.isImage = Boolean(d.isImage); entry.uploading = false;
        } catch (error) {
          entry.uploading = false; entry.failed = true;
          showToast(`첨부 실패 · ${String(error)}`);
        }
        renderAttachStrip();
      }
    }
    // PASTE_START
    // 클립보드 붙여넣기(Cmd/Ctrl+V) — 스크린샷·파일이 오면 📎 와 같은 업로드 경로를 탄다.
    // 예전엔 paste 핸들러가 아예 없어서 이미지를 붙여넣으면 조용히 버려졌다(형 지적).
    // 순수 텍스트는 손대지 않는다(브라우저 기본 삽입이 캐럿/undo 를 제대로 처리한다).
    function clipboardFiles(clipboard) {
      if (!clipboard) return [];
      const direct = clipboard.files ? [...clipboard.files] : [];
      if (direct.length) return direct;
      // Safari 등은 files 가 비고 items 에만 실린다.
      return [...(clipboard.items || [])]
        .filter(item => item && item.kind === "file")
        .map(item => item.getAsFile())
        .filter(Boolean);
    }
    promptInput.addEventListener("paste", event => {
      const files = clipboardFiles(event.clipboardData);
      if (!files.length) return;
      event.preventDefault();
      uploadFiles(files);
    });
    // PASTE_END
    attachBtn.onclick = () => fileInput.click();
    fileInput.onchange = () => { if (fileInput.files && fileInput.files.length) uploadFiles([...fileInput.files]); fileInput.value = ""; };
    attachStrip.onclick = event => {
      const del = event.target.closest("[data-attach-del]");
      if (!del) return;
      pendingAttachments = pendingAttachments.filter(a => a.id !== del.getAttribute("data-attach-del"));
      renderAttachStrip();
    };
    async function postSend(root, target, text) {
      const r = await fetch("/mobile/api/send", {method: "POST", headers: headers(true), body: JSON.stringify({root, target, text})});
      if (!r.ok) throw new Error(await responseError(r));
      return r.json();
    }
    async function send() {
      const text = promptInput.value;
      if (sending) return;
      if (pendingAttachments.some(a => a.uploading)) {
        statusEl.textContent = "첨부 업로드 중입니다...";
        return;
      }
      const ready = pendingAttachments.filter(a => a.path && !a.failed);
      if (!text.trim() && !ready.length) {
        statusEl.textContent = "메시지를 입력하세요.";
        return;
      }
      const outgoingText = [...ready.map(a => a.path), text].filter(part => part && part.length).join("\n");
      const value = currentTargetValue();
      let target = {type: "shell"};
      if (value.startsWith("term:")) target = {type: "term", tid: value.slice(5)};
      else if (value.startsWith("agent:")) {
        const [, source, sid] = value.split(":");
        target = {type: "agent", source, sid};
      }
      const requestContext = {root: sessionRoot(), sessionKey: selectedSessionKey, text, target, draftKey: activeDraftKey};
      const requestIsActive = () => selectedSessionKey === requestContext.sessionKey && sessionRoot() === requestContext.root;
      statusEl.textContent = selectedSession() && selectedSession().controllable ? "지시 추가 중..." : "보내는 중...";
      sending = true;
      sendBtn.disabled = true;
      retryBtn.style.display = "none";
      // **누르는 즉시** 대화에 세운다. 서버 응답(그리고 그 안의 도착 확인)을 기다렸다가 그리면,
      // 그 사이 화면엔 아무 일도 안 일어난다 — 형이 "바로 접수된 걸로 보이게" 라 한 자리다.
      // 입력창도 지금 비운다(보낸 것처럼 보이는데 글자가 남아 있으면 두 번 보내게 된다).
      const optimisticId = queueOptimisticTurn(requestContext.sessionKey, text, target, requestContext.root);
      if (requestIsActive()) {
        pendingAttachments = [];
        renderAttachStrip();
        promptInput.value = "";
        autoGrowComposer();
        closeSuggestions();
        followLatest = true;
        renderTurns(selectedSession());
      }
      try {
        const d = await postSend(requestContext.root, target, outgoingText);
        localStorage.removeItem(requestContext.draftKey);
        if (requestIsActive()) {
          failedSend = null;
          // held = 세션이 입력을 안 받아 서버 보류함에 보존됨(회복 후 자동 전달). 압축 회복이
          // 시작됐으면 그 사실까지 라벨로 — "보냈다" 착시를 만들지 않는다.
          const delivery = d.delivery === "held" && d.compacting ? "held-compacting"
            : (d.delivery || (target.type === "agent" ? "started" : "sent"));
          // 미리 세운 말풍선에 결과만 얹는다 — 여기서 새로 만들면 같은 말이 두 개로 보인다.
          settleOptimisticTurn(requestContext.sessionKey, optimisticId, delivery, d.tid);
          selectReturnedTerm(d.tid, text, target, delivery, optimisticId);
          statusEl.textContent = target.type === "agent" ? pendingDeliveryLabel(delivery) : `보냄 · ${d.tid}`;
          if (delivery === "held" || delivery === "held-compacting") showToast(pendingDeliveryLabel(delivery));
          if (target.type === "agent" && delivery !== "held" && delivery !== "held-compacting")
            optimisticWorkUntil = Date.now() + 6000;   // 착수 즉시 작업중 느낌
        }
        setTimeout(() => load({quiet: true}).catch(() => {}), 500);
        setTimeout(() => load({quiet: true}).catch(() => {}), 1500);   // working 상태 빨리 잡기
      } catch (error) {
        failedSend = requestContext;
        settleOptimisticTurn(requestContext.sessionKey, optimisticId, "failed", "");
        if (requestIsActive()) {
          renderTurns(selectedSession());
          statusEl.textContent = `전송 실패 · ${String(error)}`;
          showToast(`전송 실패 · ${String(error)}`);
          retryBtn.style.display = "inline-block";
        }
      } finally {
        sending = false;
        sendBtn.disabled = false;
        renderSessionControls(selectedSession());
      }
    }
    promptInput.oninput = () => {
      saveDraft();
      autoGrowComposer();
      fileSuggestions = [];
      fileSuggestionKey = "";
      renderSuggestions();
    };
    // KEY_SEND_START
    // 엔터 = 전송, 줄바꿈은 Shift+엔터 / Shift+스페이스.
    // 단 **물리 키보드일 때만** 갈라 쓴다. 폰 가상 키보드에서 엔터가 전송이면 오발이 잦아서 예전에
    // "엔터=줄바꿈, ↑로 전송"(옵션 B)으로 정한 것이고, 그 판단은 폰에선 여전히 유효하다. 형이 웹
    // (데스크톱 브라우저)에서 쓸 때만 채팅앱처럼 엔터로 바로 보낸다.
    function physicalKeyboard() {
      return Boolean(window.matchMedia && window.matchMedia("(pointer: fine)").matches);
    }
    function insertNewlineAtCaret() {
      const value = promptInput.value;
      const start = promptInput.selectionStart == null ? value.length : promptInput.selectionStart;
      const end = promptInput.selectionEnd == null ? start : promptInput.selectionEnd;
      promptInput.value = value.slice(0, start) + "\n" + value.slice(end);
      promptInput.selectionStart = promptInput.selectionEnd = start + 1;
      autoGrowComposer();
      saveDraft();
    }
    function syncComposerEnterHint() {
      const send = physicalKeyboard();
      promptInput.setAttribute("enterkeyhint", send ? "send" : "enter");
      promptInput.placeholder = send
        ? "메시지 (엔터=전송, Shift+엔터·Shift+스페이스=줄바꿈)"
        : "메시지 (엔터=줄바꿈, ↑ 로 전송)";
    }
    syncComposerEnterHint();
    if (window.matchMedia) {
      const fine = window.matchMedia("(pointer: fine)");
      if (fine.addEventListener) fine.addEventListener("change", syncComposerEnterHint);
    }
    promptInput.onkeydown = event => {
      if (event.key === "Escape") {
        closeSuggestions();
        return;
      }
      // 한글 조립 중 엔터는 **조합 확정**용이다 — 여기서 가로채면 마지막 음절이 깨지거나 삼켜진다.
      if (event.isComposing) return;
      // 멘션/스킬 제안이 열려 있으면 엔터는 첫 제안 채택(전송보다 우선).
      if (event.key === "Enter" && !event.shiftKey && suggestionsEl.classList.contains("open")) {
        const first = suggestionsEl.querySelector("[data-insert]");
        if (first) { event.preventDefault(); insertSuggestion(first.getAttribute("data-insert") || ""); return; }
      }
      // Shift+스페이스 → 줄바꿈(형 요청). 기본 동작은 공백이라 직접 넣어야 한다.
      if (event.shiftKey && (event.key === " " || event.code === "Space")) {
        event.preventDefault();
        insertNewlineAtCaret();
        return;
      }
      // Shift+엔터 → 줄바꿈. textarea 기본 동작이라 그냥 통과시킨다.
      if (event.key === "Enter" && event.shiftKey) return;
      // 엔터 → 전송. 조합키가 섞이면(Alt/Cmd/Ctrl) 손대지 않는다.
      if (event.key === "Enter" && !event.altKey && !event.metaKey && !event.ctrlKey && physicalKeyboard()) {
        event.preventDefault();
        send();
      }
    };
    // KEY_SEND_END
    promptInput.onfocus = () => {
      syncVisualViewport();
      if (followLatest) {
        requestAnimationFrame(() => scrollToLatest("auto"));
        setTimeout(() => { if (followLatest) scrollToLatest("auto"); }, 180);
      }
    };
    function isEditing() {
      return [rootSelect, targetSelect, sessionSearch].includes(document.activeElement);
    }
    document.getElementById("loginForm").onsubmit = (event) => {
      event.preventDefault();
      const value = document.getElementById("tokenInput").value.trim();
      if (!value) {
        loginStatus.textContent = "token을 입력하세요.";
        return;
      }
      localStorage.setItem("marinaMobileToken", value);
      loginStatus.textContent = "확인 중...";
      load().catch(e => showLogin(String(e)));
    };
    suggestionsEl.onclick = event => {
      const item = event.target.closest("[data-suggestion]");
      if (!item) return;
      insertSuggestion(item.getAttribute("data-insert") || "");
    };
    suggestionsEl.onmousedown = event => event.preventDefault();
    projectTabs.onclick = event => {
      const btn = event.target.closest("[data-project]");
      if (!btn || !projectTabs.contains(btn)) return;
      selectedProjectId = btn.getAttribute("data-project") || "";
      localStorage.setItem("marinaMobileProject", selectedProjectId);
      const nextRoot = state.worktrees.find(item => projectId(item) === selectedProjectId);
      if (nextRoot) {
        rootSelect.value = nextRoot.root;
        localStorage.setItem("marinaMobileRoot", nextRoot.root);
      }
      servicesState = {root: "", running: 0, defined: 0, services: []};
      // 드로어에서 프로젝트를 바꾼 경우엔 대화를 떠나지 않는다 — 패널을 열어둔 채 목록만 갈아서
      // 형이 바로 다른 세션을 고를 수 있게. (selectedSession 은 key 로 찾으니 프로젝트 필터와 무관하다.)
      // '전체'(빈 값)는 모든 대화를 포함하므로 떠날 이유가 없다.
      if (selectedProjectId && !drawerOpen() && selectedSession()
          && sessionProjectId(selectedSession()) !== selectedProjectId) leaveChat(false);
      renderProjectTabs();
      renderSourceTabs();
      renderSessions();
      renderRoomList();     // 칩이 개수를 광고하는데 눌러도 목록이 그대로면 UI 가 거짓말이다
      loadServices(true);
    };
    sourceTabs.onclick = event => {
      const btn = event.target.closest("[data-source]");
      if (!btn || !sourceTabs.contains(btn)) return;
      sourceFilter = btn.getAttribute("data-source") || "all";
      localStorage.setItem("marinaMobileSource", sourceFilter);
      if (!drawerOpen() && selectedSession() && sourceFilter !== "all" && sessionFilterSource(selectedSession()) !== sourceFilter) leaveChat(false);
      renderSourceTabs();
      renderSessions();
    };
    sessionList.onclick = event => {
      const launch = event.target.closest("[data-launch]");
      if (launch && sessionList.contains(launch)) {
        event.preventDefault();          // summary 안의 버튼 — 접기 토글로 새지 않게
        event.stopPropagation();
        launchAgent(launch.getAttribute("data-root"), launch.getAttribute("data-launch"), launch);
        return;
      }
      const btn = event.target.closest("[data-key]");
      if (!btn || !sessionList.contains(btn)) return;
      chooseSession(btn.getAttribute("data-key"));
    };
    async function launchAgent(root, source, btn) {
      if (!root || !source || (btn && btn.disabled)) return;
      if (btn) btn.disabled = true;
      try {
        const r = await fetch("/mobile/api/launch", {method: "POST", headers: headers(true),
                                                     body: JSON.stringify({root, source})});
        if (!r.ok) throw new Error(await responseError(r));
        const d = await r.json();
        showToast(`${source === "codex" ? "Codex" : "Claude"} 새 세션을 띄웠어요`);
        await load({quiet: true}).catch(() => {});
        // 새 세션은 아직 트랜스크립트가 없어 터미널로 잡힌다 — 그걸 골라두면 바로 첫 지시를 보낼 수 있고,
        // 그 지시가 훅을 깨워 세션이 에이전트로 승격된다(입양).
        // 폴 타이밍상 방금 띄운 PTY 가 아직 state 에 없을 수 있어 화면 전환을 폴에 맡기지 않는다.
        if (d.tid) {
          // 진입 경로는 **하나**다. 예전엔 폴이 새 PTY 를 실었느냐에 따라 chooseSession 과 손수
          // 만든 경로로 갈렸는데, 후자는 탭 등록도 history 푸시도 안 해서 같은 버튼인데 결과가
          // 달라 보였다(패널이 덮은 채 남고, 뒤로가기 한 번에 목록으로 튕김).
          // 아직 안 실렸으면 자리만 만들어 두고(ensureLiveTermSession), 통과는 늘 chooseSession 으로.
          clearFailedSend();   // 새 대화다 — 앞 세션의 전송 실패 배너를 들고 가지 않는다
          ensureLiveTermSession(d.tid, root, "", {type: "term", tid: d.tid});
          chooseSession(`term:${d.tid}`);
        }
      } catch (error) {
        showToast(`세션 시작 실패 · ${String(error)}`);
      } finally {
        if (btn) btn.disabled = false;
      }
    }
    document.getElementById("refreshBtn").onclick = () => { closeServices(); load().catch(e => statusEl.textContent = String(e)); };
    function leaveChat(updateHistory=true) {
      saveDraft();
      clearFailedSend();
      selectedSessionKey = "";
      activeDraftKey = "";
      turnsStructureKey = "";
      localStorage.removeItem("marinaMobileSession");
      showList();
      renderProjectTabs();
      renderSourceTabs();
      renderSessions();
      if (updateHistory && history.state && history.state.view === "chat") history.back();
      else if (!updateHistory && history.state && history.state.view === "chat") history.replaceState({view: "list"}, "", location.href);
    }
    // ☰ = 좌측 패널 토글. 채팅에서 완전히 나가는 건 브라우저/안드로이드 뒤로가기가 계속 담당한다
    // (history 상태가 leaveChat 에 걸려 있음) — 세션 갈아타기는 패널에서 바로 하는 게 형이 원한 흐름.
    backBtn.onclick = () => toggleDrawer();
    drawerBackdrop.onclick = () => closeDrawer();
    document.addEventListener("keydown", event => {
      if (event.key !== "Escape") return;
      if (viewerOpen()) { closeImageViewer(); return; }   // 뷰어가 위에 있다 — 먼저 닫는다
      if (drawerOpen()) closeDrawer();
    });
    // 왼쪽 가장자리에서 오른쪽으로 스와이프 → 열기 / 열린 상태에서 왼쪽으로 → 닫기.
    let drawerTouch = null;
    app.addEventListener("touchstart", event => {
      if (app.getAttribute("data-view") !== "chat" || event.touches.length !== 1) { drawerTouch = null; return; }
      const touch = event.touches[0];
      drawerTouch = {x: touch.clientX, y: touch.clientY, wasOpen: drawerOpen()};
    }, {passive: true});
    app.addEventListener("touchmove", event => {
      if (!drawerTouch || event.touches.length !== 1) return;
      const touch = event.touches[0];
      const intent = drawerSwipeIntent(drawerTouch, {x: touch.clientX, y: touch.clientY}, drawerTouch.wasOpen);
      if (intent === "open") { openDrawer(); drawerTouch = null; }
      else if (intent === "close") { closeDrawer(); drawerTouch = null; }
    }, {passive: true});
    app.addEventListener("touchend", () => { drawerTouch = null; }, {passive: true});
    usageBtn.onclick = event => {
      event.stopPropagation();
      const opening = !usagePanel.classList.contains("open");
      usagePanel.classList.toggle("open", opening);
      usagePanel.setAttribute("aria-hidden", opening ? "false" : "true");
      usageBtn.setAttribute("aria-expanded", opening ? "true" : "false");
    };
    usagePanel.onclick = event => event.stopPropagation();
    document.addEventListener("click", event => {
      if (usagePanel.classList.contains("open") && !usagePanel.contains(event.target) && event.target !== usageBtn) closeUsagePanel();
    });
    document.getElementById("logoutBtn").onclick = () => { closeServices(); logout(); };
    document.getElementById("clearUploadsBtn").onclick = clearUploads;
    sendBtn.onclick = () => send();
    retryBtn.onclick = () => {
      if (!failedSend || failedSend.sessionKey !== selectedSessionKey || failedSend.root !== sessionRoot()) { clearFailedSend(); return; }
      promptInput.value = failedSend.text;
      saveDraft();
      autoGrowComposer();
      send();
    };
    newMessagesBtn.onclick = scrollToLatest;
    turnsEl.addEventListener("toggle", event => {
      const detail = event.target.closest && event.target.closest("details[data-timeline-detail]");
      if (!detail || !turnsEl.contains(detail)) return;
      // 펼침 상태는 렌더러가 세션 스코프별로 기억한다 (chat-render.js setDetailScope/noteDetailToggle).
      noteDetailToggle(detail.getAttribute("data-timeline-detail") || "detail", detail.open);
    }, true);
    // 서버 응답을 그대로 돌려준다 — settled(=상태파일이 사라졌나) 를 호출자가 봐야 카드를 되살릴지 정한다.
    async function answerQuestion(payload) {
      const session = selectedSession();
      if (!session || session.kind !== "agent") return null;
      const value = currentTargetValue();
      if (!value.startsWith("agent:")) return null;
      const [, source, sid] = value.split(":");
      statusEl.textContent = "응답 전송 중...";
      try {
        const body = {root: sessionRoot(), target: {type: "agent", source, sid}};
        if (payload && payload.text != null) body.text = payload.text;
        else if (Array.isArray(payload && payload.answers)) body.answers = payload.answers;
        else if (Array.isArray(payload && payload.optionIndexes)) body.optionIndexes = payload.optionIndexes;
        else body.optionIndex = (payload && payload.optionIndex) || 0;
        const r = await fetch("/mobile/api/answer", {method: "POST", headers: headers(true), body: JSON.stringify(body)});
        if (!r.ok) throw new Error(await responseError(r));
        const result = await r.json();
        followLatest = true;
        statusEl.textContent = result && result.settled === false ? "응답이 안 먹었어요" : "";
        if (result && result.settled === false) showToast("응답이 셀렉터에 안 먹었어요 — 다시 눌러보세요");
        setTimeout(() => load({quiet: true}).catch(() => {}), 400);
        return result;
      } catch (error) {
        statusEl.textContent = `응답 실패 · ${String(error)}`;
        showToast(`응답 실패 · ${String(error)}`);
        return null;
      }
    }
    // 인라인 대기 레코드 취소·재시도(pendingTurns 안 기록만 대상 — 서버 확정 메시지는 여기 없음).
    function cancelPendingRecord(id) {
      const sessionKey = selectedSessionKey;
      const list = pendingTurns[sessionKey] || [];
      if (!list.some(t => t.id === id)) return;
      pendingTurns[sessionKey] = list.filter(t => t.id !== id);
      render();
    }
    async function resendPendingRecord(id) {
      const sessionKey = selectedSessionKey;
      const list = pendingTurns[sessionKey] || [];
      const record = list.find(t => t.id === id);
      if (!record) return;
      // 옛 문신 레코드는 즉시 제거 — 재시도가 새 레코드를 큐잉하므로 중복 표시 방지.
      pendingTurns[sessionKey] = list.filter(t => t.id !== id);
      render();
      const target = record.target || {type: "shell"};
      const root = record.root || selectedRoot();
      try {
        const d = await postSend(root, target, record.text);
        const delivery = d.delivery === "held" && d.compacting ? "held-compacting"
          : (d.delivery || (target.type === "agent" ? "started" : "sent"));
        queuePendingTurn(sessionKey, record.text, delivery, d.tid || "", target, root);
        if (selectedSessionKey === sessionKey) {
          followLatest = true;
          statusEl.textContent = target.type === "agent" ? pendingDeliveryLabel(delivery) : `보냄 · ${d.tid}`;
        }
        // 인수인계: 다른 데 열려 있던(유휴) 세션을 넘겨받았다. 작업 중인 세션은 여기 오지 않는다
        // — 그건 보류함(delivery: queue)으로 가고 끝난 뒤 자동 전달된다.
        if (d.takeover) showToast("다른 곳에 열려 있던 세션을 넘겨받았어요");
        setTimeout(() => load({quiet: true}).catch(() => {}), 500);
        setTimeout(() => load({quiet: true}).catch(() => {}), 1500);
      } catch (error) {
        queuePendingTurn(sessionKey, record.text, "failed", record.tid, target, root);
        if (selectedSessionKey === sessionKey) {
          statusEl.textContent = `전송 실패 · ${String(error)}`;
          showToast(`전송 실패 · ${String(error)}`);
        }
      } finally {
        render();
      }
    }
    turnsEl.addEventListener("click", event => {
      const cancelTarget = event.target.closest && event.target.closest("[data-pending-cancel]");
      if (cancelTarget) {
        cancelPendingRecord(cancelTarget.getAttribute("data-pending-cancel") || "");
        return;
      }
      const retryTarget = event.target.closest && event.target.closest("[data-pending-retry]");
      if (retryTarget) {
        resendPendingRecord(retryTarget.getAttribute("data-pending-retry") || "");
        return;
      }
      const resend = event.target.closest && event.target.closest("[data-resend-text]");
      if (resend) {
        promptInput.value = resend.getAttribute("data-resend-text") || "";
        saveDraft(); autoGrowComposer(); promptInput.focus();
        statusEl.textContent = "다시 보내기 — 전송 버튼을 누르세요";
        return;
      }
      const answer = event.target.closest && event.target.closest("[data-answer-option]");
      if (answer) {
        const index = parseInt(answer.getAttribute("data-answer-option"), 10);
        if (Number.isNaN(index)) return;
        const rawQ = parseInt(answer.getAttribute("data-answer-q") || "0", 10);
        // 라이브 카드와 **같은 규칙**. 예전엔 여기서 바로 쏴서 multiSelect 가 한 개만 보내지고 끝났다.
        if (pickAnswerOption(Number.isNaN(rawQ) ? 0 : rawQ, index)) submitLiveAnswer({answers: [[index]]});
        else repaintTurns();
        return;
      }
      if (event.target.closest && event.target.closest("[data-answer-submit]")) {
        const chosen = Array.from({length: liveAnswer.total}, (_, i) => liveAnswer.choices[i] || []);
        if (chosen.every(list => list.length)) submitLiveAnswer();
        return;
      }
      const action = event.target.closest && event.target.closest("[data-live-action]");
      if (!action) return;
      const target = action.getAttribute("data-live-action");
      if (!target) return;
      const detail = [...turnsEl.querySelectorAll("details[data-timeline-detail]")]
        .find(item => item.getAttribute("data-timeline-detail") === target);
      if (!detail) return;
      detail.open = true;
      detail.scrollIntoView({block: "nearest", behavior: "smooth"});
    });
    inboxMenuBtn.onclick = openInbox;
    inboxList.onclick = event => {
      const item = event.target.closest("[data-inbox-id]");
      if (item) selectInboxSession(item.getAttribute("data-inbox-id"));
    };
    document.getElementById("inboxCloseBtn").onclick = closeInbox;
    inboxSheet.onclick = event => { if (event.target === inboxSheet) closeInbox(); };
    subagentSessionBtn.onclick = openSubagents;
    document.getElementById("subagentCloseBtn").onclick = closeSubagents;
    subagentSheet.onclick = event => { if (event.target === subagentSheet) closeSubagents(); };
    document.getElementById("servicesCloseBtn").onclick = closeServices;
    servicesSheet.onclick = event => { if (event.target === servicesSheet) closeServices(); };
    // 밀도: CSS 로만 가린다 — 토글이 재렌더를 부르지 않아 스크롤/펼침이 안 튄다.
    function applyDensity() {
      sessionList.classList.toggle("density-detail", listDensity === "detail");
      densityBtn.textContent = listDensity === "detail" ? "\u2637" : "\u2630";
      densityBtn.title = listDensity === "detail" ? "간단히 보기" : "자세히 보기";
      densityBtn.setAttribute("aria-label", densityBtn.title);
    }
    densityBtn.onclick = () => {
      listDensity = listDensity === "detail" ? "simple" : "detail";
      localStorage.setItem("marinaMobileDensity", listDensity);
      applyDensity();
    };
    applyDensity();
    // 핀 — 워크트리에 붙고 서버에 저장된다.
    // ROOM_ACTIONS_START  (테스트가 이 블록의 배선을 확인한다)
    let openRoomRoot = "";
    let roomBusy = false;      // 방 패널에서 뭔가 돌고 있다 — 그동안은 패널을 다시 안 그린다

    // DONE_CARD_START  (테스트가 이 블록을 확인한다)
    // 완료 카드 — 일이 끝나면 **뭐가 바뀌었는지** 말하고 화면을 열 수 있게 한다(스펙 §3·§4).
    // 예전엔 방이 "끝났어요"라고만 해서, 형은 뭘 했는지 알려면 대화를 처음부터 읽어야 했다.
    function renderDoneCard(room, openUrl) {
      const done = room && room.done;
      if (!room || room.status !== "완료" || !done) return "";
      const files = Number(done.files || 0);
      const commits = Number(done.commits || 0);
      if (!files && !commits) return "";
      // 커밋까지 끝낸 방은 바뀐 파일이 0 이다. 그때 카드를 안 그리면 목록엔 "끝났어요"인데
      // 대화엔 아무것도 없는 어긋남이 생긴다(실측: 완료 방 3개 중 2개가 그랬다).
      const 무엇 = files ? `파일 ${files}개 바뀜` : `커밋 ${commits}개`;
      const names = (done.names || []).join(", ");
      // 이름을 다 나열하지 않는다 — 카드 한 장이고, 자세한 건 방을 열어 보면 된다.
      const 더 = done.files > (done.names || []).length ? " 외" : "";
      const 보기 = openUrl
        ? `<button class="doneOpen" type="button" data-open-preview="${esc(openUrl)}">화면 보기</button>` : "";
      return `<div class="doneCard">
        <span class="doneTitle">끝났어요 · ${esc(무엇)}</span>
        ${names ? `<span class="doneNames">${esc(names)}${esc(더)}</span>` : ""}
        ${보기}
      </div>`;
    }
    // DONE_CARD_END

    // 완료 카드를 대화 화면에 얹는다. 서비스가 떠 있으면 그 주소로 "화면 보기"를 준다 —
    // 서비스 목록은 이미 방마다 불러오고 있어서 추가 요청이 없다.
    doneSlot.addEventListener("click", event => {
      const open = event.target.closest && event.target.closest("[data-open-preview]");
      if (!open) return;
      // 새 탭으로 — 이 화면을 떠나면 대화로 돌아오는 길이 한 단계 늘어난다.
      window.open(open.getAttribute("data-open-preview"), "_blank", "noopener");
    });
    function renderDoneSlot(session) {
      const room = session ? roomByRoot(String(session.root || "")) : null;
      // 서비스 목록은 방마다 비동기로 받아 캐시한다 — **지금 방 것인지 확인**하지 않으면
      // 방 A→B 로 넘어간 직후 A 의 주소로 "화면 보기"가 뜬다. 다른 일감의 앱이 열리는 건
      // 비개발자에게 진단 불가능한 고장이다.
      const 같은방 = room && String(servicesState.root || "") === String(room.root || "");
      const running = 같은방
        ? (servicesState.services || []).find(item => item.running && item.openUrl) : null;
      const html = renderDoneCard(room, running ? running.openUrl : "");
      if (doneSlot.innerHTML !== html) doneSlot.innerHTML = html;
      doneSlot.hidden = !html;
      // 카드가 대화 마지막 줄을 가리지 않게 자리를 비운다(생각중 표시와 같은 규칙).
      if (chatView) chatView.classList.toggle("hasDone", Boolean(html));
    }

    // ROOM_SIBLING_TABS_START  (테스트가 이 블록을 vm 에 싣는다)
    // 방 안에서 **다른 대화로 바로 넘어가게** 한다(스펙 §3 화면 그림의 `[기본] [디자인 손보기]`).
    // 예전엔 대화 화면의 탭 줄이 "형이 연 탭" 기준이라, 방 카드로 들어가면 탭이 하나뿐이라
    // 줄이 안 떴다 — 같은 방의 다른 대화로 가려면 목록으로 나갔다 다시 들어가야 했다.
    function roomSiblingKeys(room) {
      if (!room) return [];
      // 숨긴·오래된 대화는 뺀다 — 목록에서 치운 것이 탭 줄로 되살아나면 숨김이 무의미하다.
      return (room.tabs || [])
        .filter(tab => tab && !tab.hidden && !tab.stale)
        .map(tab => `agent:${tab.source}:${tab.sid}:${room.root}`);
    }
    // 기존 멀티탭(다른 방 대화를 함께 띄우는 것)은 **없애지 않고 얹기만** 한다.
    function addRoomTabs(room) {
      roomSiblingKeys(room).forEach(key => addTab(key));
    }
    // ROOM_SIBLING_TABS_END

    // 방 목록 다시 그리기 — 폴·검색·필터가 모두 이 함수를 쓴다(규칙이 갈라지면 안 된다).
    function renderRoomList() {
      const 방들 = state.rooms || [];
      roomList.innerHTML = renderRooms(방들, Date.now() / 1000, showAll,
                                       sessionSearch.value, selectedProjectId);
      // 방이 하나도 없으면 예전 세션 목록을 되살린다. 서버가 rooms 를 못 만들었을 때
      // (옛 데몬·조립 실패) 빈 화면만 남으면 형은 앱이 고장난 줄 안다 — 목록이 안 뜨면
      // 아무것도 못 하므로, 방은 부가정보고 세션 목록이 생명줄이다.
      // 열어둔 패널도 같이 갱신한다 — 안 그러면 상태가 멈춘 화면을 보고 있게 되고,
      // 그 사이 사라진 대화의 탭은 눌러도 아무 일이 안 난다.
      if (openRoomRoot) {
        const 열린방 = roomByRoot(openRoomRoot);
        // **동작 중에는 손대지 않는다.** 패널을 다시 그리면 눌러서 잠가둔 버튼이 새 노드로
        // 갈리며 잠금이 풀린다 — 기동 중인데 다시 눌려서 세션이 둘 생긴다(실측: 폴 한 번 3초).
        if (roomBusy) { /* 그대로 둔다 */ }
        else if (열린방) roomOpen.innerHTML = renderRoomTabs(열린방, launchSources());
        else closeRoom();
      }
      const 방없음 = !방들.length;
      sessionList.hidden = !방없음;
      roomList.hidden = 방없음;
      // 종류 탭(claude/codex/터미널)은 **세션** 개념이라 방 목록에는 안 먹는다. 보이기만 하고
      // 아무 일도 안 하면 UI 가 거짓말을 하는 것이라, 방 목록일 때는 아예 숨긴다.
      sourceTabs.hidden = !방없음;
    }
    function launchSources() {
      const opts = state.agentOptions || {};
      // 순서를 못 박는다 — 워크트리 시트도 claude·codex 순이라, 같은 동작이 화면마다 다른
      // 자리에 있으면 손가락이 헷갈린다. Object.keys 는 순서를 약속하지 않는다.
      const 순서 = ["claude", "codex"];
      const ids = Object.keys(opts).sort((a, b) => {
        const ia = 순서.indexOf(a), ib = 순서.indexOf(b);
        return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib);
      });
      return ids.map(id => ({id, label: id === "claude" ? "Claude" : id === "codex" ? "Codex" : id}));
    }
    function roomByRoot(root) {
      return (state.rooms || []).find(item => item.root === root) || null;
    }
    function closeRoom() {
      openRoomRoot = "";
      roomOpen.hidden = true;
      roomOpen.innerHTML = "";
    }
    function openRoom(root) {
      const room = roomByRoot(root);
      if (!room) return;
      openRoomRoot = root;
      roomOpen.innerHTML = renderRoomTabs(room, launchSources());
      roomOpen.hidden = false;
      // 패널은 목록 맨 위에 있다 — 아래쪽 방을 열면 화면 밖에서 열려서 "아무 일도 안 났다"로
      // 보인다(실측: 목록을 1300px 내린 상태에서 열면 패널이 뷰포트 위 -1300px).
      roomOpen.scrollIntoView({block: "nearest", behavior: "smooth"});
    }
    // 방 카드를 누르면 **바로 그 방의 대화로** 간다. 대부분의 방은 대화가 하나뿐이라,
    // 여기서 한 번 더 고르게 하면 흔한 경우에 손가락이 한 번 더 든다.
    roomList.addEventListener("click", event => {
      const back = event.target.closest && event.target.closest("[data-room-unarchive]");
      if (back) { unarchiveRoom(back.getAttribute("data-room-unarchive")); return; }
      const more = event.target.closest && event.target.closest("[data-room-more]");
      if (more) { openRoom(more.getAttribute("data-room-more")); return; }
      const card = event.target.closest && event.target.closest("[data-room]");
      if (!card) return;
      const room = roomByRoot(card.getAttribute("data-room"));
      if (!room) return;
      const tab = (room.tabs || []).find(item => item.primary) || (room.tabs || [])[0];
      // 대화가 아직 없는 방은 고를 게 없으니 방 안을 연다 — 아무 반응이 없으면 고장으로 보인다.
      if (!tab) { openRoom(room.root); return; }
      closeRoom();
      addRoomTabs(room);      // 같은 방의 다른 대화로 바로 넘어갈 수 있게
      chooseSession(`agent:${tab.source}:${tab.sid}:${room.root}`);
    });
    roomOpen.addEventListener("click", async event => {
      const target = event.target.closest && event.target.closest("[data-tab],[data-rename],[data-archive],[data-room-close],[data-room-launch],[data-unhide],[data-room-relogin],[data-room-code],[data-room-delete],[data-forget],[data-close-chat],[data-restore]");
      if (!target) return;
      roomBusy = true;
      try { await handleRoomAction(target); } finally { roomBusy = false; }
    });
    async function handleRoomAction(target) {
      if (target.hasAttribute("data-room-close")) { closeRoom(); return; }
      if (target.hasAttribute("data-room-code")) {
        await sendReloginCode(target.getAttribute("data-room-code"));
        return;
      }
      if (target.hasAttribute("data-room-relogin")) {
        await reloginRoom(target.getAttribute("data-room-relogin"), target);
        return;
      }
      if (target.hasAttribute("data-room-delete")) {
        await deleteRoom(target.getAttribute("data-room-delete"));
        return;
      }
      if (target.hasAttribute("data-restore")) {
        await forgetChat(target.getAttribute("data-restore"), false);
        return;
      }
      if (target.hasAttribute("data-close-chat")) {
        await closeChatProcess(target.getAttribute("data-close-chat"));
        return;
      }
      if (target.hasAttribute("data-forget")) {
        await forgetChat(target.getAttribute("data-forget"));
        return;
      }
      if (target.hasAttribute("data-unhide")) {
        const 값 = String(target.getAttribute("data-unhide"));
        const source = 값.slice(0, 값.indexOf(":"));
        const sid = 값.slice(값.indexOf(":") + 1);
        await unhideSession(openRoomRoot, source, sid);
        return;
      }
      if (target.hasAttribute("data-room-launch")) {
        await launchAgent(openRoomRoot, target.getAttribute("data-room-launch"), target);
        return;
      }
      if (target.hasAttribute("data-rename")) { await renameRoom(target.getAttribute("data-rename")); return; }
      if (target.hasAttribute("data-archive")) { await archiveRoom(target.getAttribute("data-archive")); return; }
      const 값 = String(target.getAttribute("data-tab") || "");
      const source = 값.slice(0, 값.indexOf(":"));
      const sid = 값.slice(값.indexOf(":") + 1);     // sid 에 ':' 가 있어도 안 깨지게
      const root = openRoomRoot;
      const 방 = roomByRoot(root);
      closeRoom();
      addRoomTabs(방);
      chooseSession(`agent:${source}:${sid}:${root}`);
    }

    // 접기 — 끝난 방을 목록에서 치운다. 서버가 "무엇으로 부르고 있었는지"를 같이 적어두므로,
    // 새로 부를 일이 생기면 저절로 다시 올라온다(1차에서 만든 규칙).
    async function archiveRoom(root) {
      if (!root) return;
      try {
        const r = await fetch("/mobile/api/archive", {method: "POST", headers: headers(true),
                                                      body: JSON.stringify({root, archived: true})});
        if (!r.ok) throw new Error(await responseError(r));
        closeRoom();
        showToast("접어뒀어요 · 다시 부르면 올라와요");
        await load({force: true});   // 접었는데 그대로 있으면 안 먹은 걸로 보인다
      } catch (error) {
        showToast(`접기 실패 · ${String(error)}`);
      }
    }

    // 클로드 로그인 — 폰에서 끝낸다. 서버가 PTY 에 /login 을 쳐서 URL 을 읽어다 주면,
    // 형은 그 링크를 열고 받은 코드를 여기 붙여넣는다.
    async function reloginRoom(root, btn) {
      const room = roomByRoot(root);
      if (!room) return;
      // **로그인이 풀린 그 대화**를 고른다. 예전엔 "가장 최근 클로드 대화"를 골라서,
      // 옆에서 작업 중인 대화에 /login 이 프롬프트로 들어갈 수 있었다.
      const tabs = (room.tabs || []).filter(item => item.source === "claude");
      const tab = tabs.find(item => item.reason === "needs_login") || tabs[0];
      if (!tab) { showToast("로그인할 대화가 없어요"); return; }
      if (tab.canon === "working") {
        showToast("그 대화가 일하는 중이에요 — 끝나면 다시 눌러주세요");
        return;
      }
      if (btn) { btn.disabled = true; btn.textContent = "여는 중…"; }
      try {
        const r = await fetch("/mobile/api/relogin", {method: "POST", headers: headers(true),
          body: JSON.stringify({root, source: tab.source, sid: tab.sid, step: "start"})});
        if (!r.ok) throw new Error(await responseError(r));
        const data = await r.json();
        // 링크는 **새 탭**으로 연다 — 이 화면을 떠나면 코드를 붙여넣을 자리가 사라진다.
        roomOpen.querySelector(".roomBlocked").innerHTML =
          `<a class="reloginLink" href="${esc(data.url || "")}" target="_blank" rel="noopener">클로드 로그인 열기</a>
           <div class="reloginHint">로그인하면 코드가 나와요. 그걸 여기 붙여넣어 주세요.</div>
           <div class="reloginRow">
             <input class="reloginCode" id="reloginCode" placeholder="코드 붙여넣기" autocapitalize="none" spellcheck="false" />
             <button class="roomStart" type="button" data-room-code="${esc(root)}">보내기</button>
           </div>`;
      } catch (error) {
        showToast(`로그인 열기 실패 · ${String(error)}`);
        if (btn) { btn.disabled = false; btn.textContent = "로그인 하기"; }
      }
    }
    async function sendReloginCode(root) {
      const input = document.getElementById("reloginCode");
      const code = input ? input.value.trim() : "";
      if (!code) { showToast("코드를 넣어주세요"); return; }
      const room = roomByRoot(root);
      const tab = room && ((room.tabs || []).find(item => item.source === "claude") || (room.tabs || [])[0]);
      try {
        const r = await fetch("/mobile/api/relogin", {method: "POST", headers: headers(true),
          body: JSON.stringify({root, source: (tab || {}).source || "claude", sid: (tab || {}).sid || "", step: "code", code})});
        if (!r.ok) throw new Error(await responseError(r));
        const d = await r.json();
        showToast(d.stage === "done" ? "로그인됐어요"
                  : d.stage === "logged_out" ? "코드가 안 먹었어요 — 다시 해주세요"
                  : "코드를 보냈어요");
        closeRoom();
        await load({force: true});
      } catch (error) {
        showToast(`코드 전송 실패 · ${String(error)}`);
      }
    }

    // 방 지우기 — 되돌릴 수 없으므로 한 번 묻는다. 미커밋 변경은 서버가 **먼저 보관**하고
    // 지우므로 여기서 막지 않는다(스펙 §7). 보관 얘기는 형에게 안 한다 — 멤버에겐 물음표만 남는다.
    async function deleteRoom(root) {
      const room = roomByRoot(root);
      if (!room) return;
      if (!confirm(`"${room.name || room.shortName}" 을 지울까요?\n되돌릴 수 없어요.`)) return;
      try {
        const r = await fetch("/mobile/api/remove-room", {method: "POST", headers: headers(true),
          body: JSON.stringify({root, name: room.name || room.shortName || ""})});
        if (!r.ok) throw new Error(await responseError(r));
        closeRoom();
        showToast("지웠어요");
        await load({force: true});
      } catch (error) {
        showToast(`지우기 실패 · ${String(error)}`);
      }
    }
    // 대화 끄기 — 돌고 있는 프로세스를 닫는다. 기록은 그대로라 다시 열면 이어서 한다.
    // 정지(Esc)는 붙잡힌 CLI 에 안 먹어서, 아예 끄는 길이 따로 있어야 한다.
    async function closeChatProcess(key) {
      const source = key.slice(0, key.indexOf(":"));
      const sid = key.slice(key.indexOf(":") + 1);
      if (!confirm("이 대화를 끌까요?\n하던 일이 끊겨요. 기록은 남아요.")) return;
      try {
        const r = await fetch("/mobile/api/close-chat", {method: "POST", headers: headers(true),
          body: JSON.stringify({root: openRoomRoot, source, sid})});
        if (!r.ok) throw new Error(await responseError(r));
        const d = await r.json();
        // 서버가 못 껐다고 하면 그대로 말한다. 데몬 재시작 뒤(마스터 fd 를 잃은 세션)엔
        // 끌 tid 가 없다 — 폭주 CLI 를 끄려던 순간에 "껐어요"는 거짓말이 된다.
        showToast(d.closed ? "껐어요" : "이미 안 돌고 있어요");
        await load({force: true});
        if (openRoomRoot) openRoom(openRoomRoot);
      } catch (error) {
        showToast(`끄기 실패 · ${String(error)}`);
      }
    }
    // 폰에서 보낸 사진 정리 — 폰에서 만들 수 있는데 지울 길이 없던 것(형 지적).
    async function clearUploads() {
      try {
        const usage = state.uploads || {files: 0, bytes: 0};
        if (!usage.files) { showToast("정리할 사진이 없어요"); return; }
        const mb = (usage.bytes / 1048576).toFixed(1);
        // **취소는 취소여야 한다.** 예전엔 확인/취소를 두 갈래 선택지로 썼는데, 놀라서 취소를
        // 누르면 30일 지난 사진이 지워졌다 — 되돌릴 수 없는 동작에 빠져나올 문이 없었다.
        if (!confirm(`30일 지난 사진을 정리할까요?\n지금 ${usage.files}개(${mb}MB) 있어요.`)) return;
        const r = await fetch("/mobile/api/clear-uploads", {method: "POST", headers: headers(true),
          body: JSON.stringify({olderThanDays: 30})});
        if (!r.ok) throw new Error(await responseError(r));
        const d = await r.json();
        showToast(d.removed ? `사진 ${d.removed}개 지웠어요` : "지울 게 없었어요");
        await load({force: true});
      } catch (error) {
        showToast(`사진 정리 실패 · ${String(error)}`);
      }
    }
    // 대화 지우기 — 마리나에서만 치운다(원본은 그대로). 워크트리는 안 건드린다.
    // forget=false 면 되살린다 — 실수로 지웠을 때 폰에서 되돌릴 길이 있어야 한다.
    // (지운 대화는 전체보기에서만 "지움" 으로 보이고, 거기서 이 버튼을 누른다.)
    async function forgetChat(key, forget = true) {
      const source = key.slice(0, key.indexOf(":"));
      const sid = key.slice(key.indexOf(":") + 1);
      if (forget && !confirm("이 대화를 목록에서 지울까요?")) return;
      try {
        const r = await fetch("/mobile/api/forget-chat", {method: "POST", headers: headers(true),
          body: JSON.stringify({source, sid, forget})});
        if (!r.ok) throw new Error(await responseError(r));
        showToast(forget ? "지웠어요" : "되살렸어요");
        await load({force: true});
        if (openRoomRoot) openRoom(openRoomRoot);
      } catch (error) {
        showToast(`지우기 실패 · ${String(error)}`);
      }
    }

    // 숨김 해제 — 세션 카드 롱프레스가 쓰던 표면과 같은 것을 쓴다(규칙이 갈라지지 않게).
    async function unhideSession(root, source, sid) {
      if (!root || !source || !sid) return;
      try {
        const r = await fetch("/mobile/api/hidden", {method: "POST", headers: headers(true),
                                                     body: JSON.stringify({root, source, sid, hidden: false})});
        if (!r.ok) throw new Error(await responseError(r));
        await load({force: true});
        if (openRoomRoot === root) openRoom(root);
      } catch (error) {
        showToast(`숨김 해제 실패 · ${String(error)}`);
      }
    }

    // 다시 꺼내기 — 접기와 같은 표면에 archived=false 를 보낸다(서버가 기록을 지운다).
    async function unarchiveRoom(root) {
      if (!root) return;
      try {
        const r = await fetch("/mobile/api/archive", {method: "POST", headers: headers(true),
                                                      body: JSON.stringify({root, archived: false})});
        if (!r.ok) throw new Error(await responseError(r));
        await load({force: true});
      } catch (error) {
        showToast(`꺼내기 실패 · ${String(error)}`);
      }
    }

    async function renameRoom(root) {
      const room = roomByRoot(root);
      if (!room) return;
      const next = prompt("방 이름", room.name || "");
      if (next === null) return;            // 취소
      try {
        const r = await fetch("/mobile/api/rename", {method: "POST", headers: headers(true),
                                                     body: JSON.stringify({root, name: next})});
        if (!r.ok) throw new Error(await responseError(r));
        await load({force: true});
        if (openRoomRoot === root) openRoom(root);   // 열어둔 패널의 제목도 새 이름으로
      } catch (error) {
        showToast(`이름 바꾸기 실패 · ${String(error)}`);
      }
    }
    // ROOM_ACTIONS_END

    sessionList.addEventListener("click", event => {
      const more = event.target.closest && event.target.closest("[data-wt-more]");
      if (!more) return;
      event.preventDefault();
      event.stopPropagation();          // summary 안이라 접기 토글로 새지 않게
      openWorktreeSheet(more.getAttribute("data-wt-more") || "");
    }, true);
    // 시트 안 동작 — 워크트리 하나에 대해서만 돈다
    worktreeActions.onclick = async event => {
      const item = event.target.closest && event.target.closest("[data-wt-act]");
      if (!item) return;
      const root = worktreeActions.dataset.root || "";
      const act = item.getAttribute("data-wt-act") || "";
      if (act === "services") { closeWorktreeSheet(); openServices(root); return; }
      if (act === "logs") { closeWorktreeSheet(); openLogs(root); return; }
      if (act === "git") { closeWorktreeSheet(); openGit(root); return; }
      if (act.startsWith("launch:")) { closeWorktreeSheet(); launchAgent(root, act.slice(7), item); return; }
      if (act === "pin") { closeWorktreeSheet(); await toggleWorktreePin(root); }
    };
    document.getElementById("worktreeCloseBtn").onclick = closeWorktreeSheet;
    worktreeSheet.onclick = event => { if (event.target === worktreeSheet) closeWorktreeSheet(); };
    async function toggleWorktreePin(root) {
      if (!root) return;
      const next = !pinnedRoots.has(root);
      if (next) pinnedRoots.add(root); else pinnedRoots.delete(root);
      renderSessions();
      try {
        const r = await fetch("/mobile/api/pins", {method: "POST", headers: headers(true),
                                                   body: JSON.stringify({root, pinned: next})});
        if (!r.ok) throw new Error(await responseError(r));
        pinnedRoots = new Set((await r.json()).roots || []);
      } catch (error) {
        if (next) pinnedRoots.delete(root); else pinnedRoots.add(root);   // 서버가 거절하면 되돌린다
        showToast(`고정 실패 · ${String(error)}`);
      }
      renderSessions();
    }
    // 헤더의 핀 아이콘도 같은 함수를 쓴다(규칙이 갈라지지 않게).
    sessionList.addEventListener("click", event => {
      const pin = event.target.closest && event.target.closest("[data-pin-root]");
      if (!pin) return;
      event.preventDefault();
      event.stopPropagation();
      const group = pin.closest("[data-wt-root]");
      toggleWorktreePin(group && group.getAttribute("data-wt-root"));
    }, true);
    // 워크트리 생성 — 프로젝트 단위라 진입점을 그룹 헤더와 층을 나눈다.
    // NEW_TASK_START  (테스트가 이 블록을 확인한다)
    // 새 일감 — 형은 **무슨 일을 할지만** 쓴다(스펙 §3 "브랜치명은 마리나가 첫 메시지에서
    // 짓는다. 선택지를 프로젝트 하나로 줄이는 게 안전장치다").
    //
    // 예전엔 "새 워크트리의 브랜치명"을 물었다. 비개발자 화면에서 브랜치라는 말도, 그 이름
    // 규칙(영문/숫자/-)도 형이 알 이유가 없다.
    newWorktreeBtn.onclick = async () => {
      // 프로젝트: 고른 게 있으면 그것, '전체'면 방금 보던 방의 프로젝트.
      const 최근 = (state.rooms || []).slice().sort((a, b) => (b.lastAt || 0) - (a.lastAt || 0))[0];
      const 대상프로젝트 = selectedProjectId || String((최근 && 최근.projectId) || "");
      if (!대상프로젝트) { showToast("프로젝트를 먼저 고르세요"); return; }
      const 할일 = (prompt("무슨 일을 할까요?") || "").trim();
      if (!할일) return;

      newWorktreeBtn.disabled = true;
      const previous = newWorktreeBtn.textContent;
      newWorktreeBtn.textContent = "만드는 중…";
      statusEl.textContent = "일감 만드는 중 — 서브레포가 있으면 몇 분 걸릴 수 있어요";
      try {
        const r = await fetch("/mobile/api/worktree-create", {method: "POST", headers: headers(true),
          body: JSON.stringify({projectId: 대상프로젝트, task: 할일})});
        if (!r.ok) throw new Error(await responseError(r));
        const d = await r.json();
        const root = String(d.root || "");
        // 형이 쓴 말을 **방 이름으로** 남긴다. 폴더 이름은 ASCII 로 안전하게 짓기 때문에
        // (게이트웨이 도메인 라벨로도 쓰인다) 이걸 안 하면 목록에 work-4f2a1 같은 게 뜬다.
        // fetch 는 4xx 에 reject 하지 않는다 — .catch 만 붙이면 403/400 이 조용히 지나가고
        // 반쪽 상태(폴더는 있고 이름·대화는 없음)가 "성공"으로 보고된다.
        const 이름응답 = await fetch("/mobile/api/rename", {method: "POST", headers: headers(true),
          body: JSON.stringify({root, name: 할일})});
        if (!이름응답.ok) showToast("이름은 못 붙였어요 — 방에서 ✎ 로 바꿔주세요");
        // 바로 일을 시작한다 — 만들어만 놓고 끝나면 형이 또 찾아 들어가야 한다.
        const 시작응답 = await fetch("/mobile/api/launch", {method: "POST", headers: headers(true),
          body: JSON.stringify({root, source: "claude", prompt: 할일})});
        if (!시작응답.ok) throw new Error(await responseError(시작응답));
        showToast("새 일감을 시작했어요");
        await load({force: true}).catch(() => {});
      } catch (error) {
        showToast(`새 일감 실패 · ${String(error)}`);
      } finally {
        newWorktreeBtn.disabled = false;
        newWorktreeBtn.textContent = previous;
        statusEl.textContent = "";
      }
    };
    // NEW_TASK_END

    // 전체보기 — 7일 넘어 목록에서 빠진 세션과 숨긴 세션까지 서버에서 받아온다.
    function applyShowAll() {
      showAllBtn.classList.toggle("on", showAll);
      showAllBtn.title = showAll ? "전체보기 끄기" : "전체보기(오래된·숨긴·접은 것 포함)";
      sessionList.classList.toggle("show-all", showAll);
    }
    showAllBtn.onclick = () => {
      showAll = !showAll;
      applyShowAll();
      load({quiet: true}).catch(() => {});
    };
    applyShowAll();
    // 세션 숨기기/되살리기 — 길게 누르기(모바일) · 오른쪽 클릭(데스크톱).
    // "삭제"가 아니다: 기록은 그대로 두고 목록에서만 뺀다(되돌릴 수 있어야 하니까).
    sessionList.addEventListener("contextmenu", async event => {
      const card = event.target.closest && event.target.closest("[data-hide-key]");
      if (!card) return;
      event.preventDefault();
      const key = card.getAttribute("data-hide-key") || "";
      const [source, ...rest] = key.split(":");
      const sid = rest.join(":");
      if (!source || !sid) return;
      const next = !hiddenSessions.has(key);
      if (next) hiddenSessions.add(key); else hiddenSessions.delete(key);
      renderSessions();
      try {
        const r = await fetch("/mobile/api/hidden", {method: "POST", headers: headers(true),
          body: JSON.stringify({root: sessionRootForKey(card.getAttribute("data-key")), source, sid, hidden: next})});
        if (!r.ok) throw new Error(await responseError(r));
        hiddenSessions = new Set((await r.json()).keys || []);
        showToast(next ? "목록에서 숨겼어요 (전체보기에서 되살릴 수 있어요)" : "다시 보이게 했어요");
        if (next && !showAll) load({quiet: true}).catch(() => {});
      } catch (error) {
        if (next) hiddenSessions.delete(key); else hiddenSessions.add(key);   // 서버가 거절하면 되돌린다
        showToast(`숨기기 실패 · ${String(error)}`);
      }
      renderSessions();
    });
    function sessionRootForKey(key) {
      const found = (state.sessions || []).find(s => s.key === key);
      return (found && found.root) || selectedRoot();
    }
    galleryBtn.onclick = () => openGallery();
    galleryCloseBtn.onclick = closeGallery;
    gallerySheet.onclick = event => { if (event.target === gallerySheet) closeGallery(); };
    galleryGrid.onclick = event => {
      const cell = event.target.closest && event.target.closest("[data-image-ref]");
      if (cell) {
        const ref = cell.getAttribute("data-image-ref");
        const at = galleryImageList.findIndex(v => v.ref === ref);
        if (at >= 0) openViewer(galleryImageList, at);
        else openImageViewer(transcriptImageUrl(ref), "대화 이미지");
      }
    };
    gallerySheet.querySelectorAll("[data-gallery-tab]").forEach(btn => {
      btn.onclick = () => openGallery(btn.getAttribute("data-gallery-tab"));
    });
    galleryFiles.onclick = event => {
      const row = event.target.closest && event.target.closest("[data-file-path]");
      if (!row) return;
      const path = row.getAttribute("data-file-path");
      const name = row.getAttribute("data-file-name") || path.split("/").pop();
      // 이미지든 텍스트든 앱 안 뷰어로 — 새 탭을 띄우지 않는다. 목록째로 열어 좌우로 넘긴다.
      const at = galleryFileList.findIndex(v => v.path === path);
      if (at >= 0) openViewer(galleryFileList, at);
      else if (row.getAttribute("data-file-image")) openImageViewer(sessionFileUrl(path), name);
      else openTextViewer(sessionFileUrl(path), name);
    };
    imageViewerClose.onclick = closeImageViewer;
    // 배경(오버레이 자체)만 닫는다 — 텍스트를 스크롤/선택하려면 본문 클릭이 닫으면 안 된다.
    imageViewer.onclick = event => { if (event.target === imageViewer || event.target === viewerBar) closeImageViewer(); };
    viewerPrev.onclick = event => { event.stopPropagation(); stepViewer(-1); };
    viewerNext.onclick = event => { event.stopPropagation(); stepViewer(1); };
    // 스와이프 — 폰에서 버튼보다 이게 먼저 손이 간다. 세로 스크롤(긴 텍스트)과 겹치지 않게
    // 가로 이동이 세로보다 확실히 클 때만 넘긴다.
    let viewerTouch = null;
    imageViewer.addEventListener("touchstart", event => {
      const t = event.changedTouches[0];
      viewerTouch = t ? {x: t.clientX, y: t.clientY} : null;
    }, {passive: true});
    imageViewer.addEventListener("touchend", event => {
      if (!viewerTouch || viewerList.length < 2) return;
      const t = event.changedTouches[0];
      if (!t) return;
      const dx = t.clientX - viewerTouch.x, dy = t.clientY - viewerTouch.y;
      viewerTouch = null;
      if (Math.abs(dx) > 48 && Math.abs(dx) > Math.abs(dy) * 1.6) stepViewer(dx < 0 ? 1 : -1);
    }, {passive: true});
    document.addEventListener("keydown", event => {
      if (!imageViewer.classList.contains("open")) return;
      if (event.key === "ArrowLeft") { event.preventDefault(); stepViewer(-1); }
      else if (event.key === "ArrowRight") { event.preventDefault(); stepViewer(1); }
      else if (event.key === "Escape") closeImageViewer();
    });
    // 대화 안 썸네일·파일 탭 → 전체보기. **A안** — 넘기면 그 대화에 나온 것만 순서대로 흐른다
    // (형: "해당 채팅에서는 해당 채팅 내용만"). 세션 전체를 보려면 모아보기가 따로 있다.
    function chatViewables() {
      const session = selectedSession();
      const history = session ? historyCache[session.key] : null;
      return collectViewables((history && history.timeline) || []);
    }
    turnsEl.addEventListener("click", event => {
      const closest = event.target.closest ? event.target.closest.bind(event.target) : null;
      if (!closest) return;
      const thumb = closest("[data-image-ref]");
      const fileBtn = closest("[data-file-path]");
      if (!thumb && !fileBtn) return;
      event.preventDefault();
      event.stopPropagation();
      const list = chatViewables();
      const key = thumb ? thumb.getAttribute("data-image-ref") : fileBtn.getAttribute("data-file-path");
      const at = list.findIndex(v => (thumb ? v.ref : v.path) === key);
      if (at >= 0) { openViewer(list, at); return; }
      // 목록에 없으면(구조가 예상과 다르면) 한 장만이라도 연다 — 눌렀는데 아무 일도 안 나면 안 된다.
      if (thumb) openImageViewer(transcriptImageUrl(key), "대화 이미지");
      else openTextViewer(sessionFileUrl(key), String(key).split("/").pop());
    });
    serviceList.onclick = event => {
      const open = event.target.closest("[data-service-open]");
      if (open) {
        window.open(open.getAttribute("data-service-open"), "_blank", "noopener");
        return;
      }
      const action = event.target.closest("[data-service-action]");
      if (action) runServiceAction(action.getAttribute("data-service") || "", action.getAttribute("data-service-action") || "");
    };
    settingsBtn.onclick = openSettings;
    document.getElementById("settingsCloseBtn").onclick = closeSettings;
    settingsSheet.onclick = event => { if (event.target === settingsSheet) closeSettings(); };
    modelSelect.onchange = () => {
      customModelLabel.style.display = modelSelect.value === "__custom__" ? "flex" : "none";
      updateEffortChoices(selectedSession(), effortSelect.value);
      if (modelSelect.value === "__custom__") customModelInput.focus();
    };
    customModelInput.oninput = () => updateEffortChoices(selectedSession(), effortSelect.value);
    settingsForm.onsubmit = event => {
      event.preventDefault();
      saveSettings().catch(error => showToast(`설정 저장 실패 · ${String(error)}`));
    };
    stopBtn.onclick = interruptCurrentTurn;
    rootSelect.onchange = () => { rememberRoot(); render(); };
    targetSelect.onchange = () => { rememberTarget(); render(); };
    // 검색은 방 목록에도 먹어야 한다 — 안 그러면 입력해도 28개 그대로다.
    sessionSearch.oninput = () => { renderSessions(); renderRoomList(); };
    turnsEl.addEventListener("scroll", () => {
      if (suppressScrollTracking) return;
      followLatest = atPageBottom();
      if (followLatest) newMessagesBtn.style.display = "none";
      const session = selectedSession();
      const history = sessionHistory(session);
      if (!followLatest && turnsEl.scrollTop < 72 && history && history.hasMore) loadOlderMessages();
    }, {passive: true});
    if (!history.state || !history.state.view) {
      history.replaceState({view: "base"}, "", location.href);
      history.pushState({view: "list"}, "", location.href);
    }
    window.addEventListener("popstate", () => {
      // 드로어가 열려 있으면 뒤로가기는 **드로어만** 닫는다 — 대화에서 튕겨나가면 안 된다.
      if (drawerOpen()) {
        closeDrawer();
        history.pushState({view: "chat"}, "", location.href);
        return;
      }
      if (history.state && history.state.view === "list") {
        if (selectedSessionKey) leaveChat(false);
        return;
      }
      if (history.state && history.state.view === "chat") return;
      if (Date.now() < exitArmedUntil) {
        history.back();
        return;
      }
      exitArmedUntil = Date.now() + 2000;
      showToast("한 번 더 누르면 Marina를 나갑니다");
      history.pushState({view: "list"}, "", location.href);
    });
    // 백그라운드 폴은 일시적 fetch 실패(모바일 원격연결은 흔함)를 조용히 삼킨다 — 예전엔 실패마다 "Failed to fetch"
    // 를 상태줄에 뿌려 계속 깜빡였음. 연속 3회+ 실패(진짜 끊김)에만 차분히 1회 알리고 복구되면 지운다.
    let pollFailStreak = 0;
    const CONN_MSG = "연결 확인 중…";
    function quietPoll() {
      if (document.visibilityState === "hidden") return;
      load({quiet: true}).then(() => {
        if (pollFailStreak >= 3 && statusEl.textContent === CONN_MSG) statusEl.textContent = "";
        pollFailStreak = 0;
      }).catch(() => {
        pollFailStreak += 1;
        if (pollFailStreak === 3) statusEl.textContent = CONN_MSG;
      });
    }
    // LIVE_STREAM_START
    // 서버가 밀어주는 변화를 듣는다. 이게 붙어 있으면 폴링을 느리게 돌리고, 끊기면 되돌린다.
    // **연결 자체가 화면 상태다** — 살아 있음을 헤더에 표시해야 "멈춘 것 같다"는 느낌이 사라진다.
    let liveSource = null;
    let liveBackoffMs = 1000;
    let liveConnected = false;
    let pollTimer = 0;
    function setPollInterval(ms) {
      if (autoPollMs === ms && pollTimer) return;
      autoPollMs = ms;
      if (pollTimer) clearInterval(pollTimer);
      pollTimer = setInterval(quietPoll, autoPollMs);
    }
    function markLive(connected) {
      liveConnected = connected;
      if (typeof document !== "undefined" && document.body) {
        document.body.dataset.live = connected ? "on" : "off";
      }
      setPollInterval(connected ? POLL_LIVE_MS : POLL_FALLBACK_MS);
    }
    function liveEventUrl() {
      const token = new URLSearchParams(location.search).get("token");
      return "/mobile/api/events" + (token ? `?token=${encodeURIComponent(token)}` : "");
    }
    function connectLive() {
      if (liveSource || document.visibilityState === "hidden") return;
      let source;
      try { source = new EventSource(liveEventUrl()); }
      catch (e) { markLive(false); return; }
      liveSource = source;
      source.onopen = () => { liveBackoffMs = 1000; markLive(true); };
      source.onmessage = event => {
        markLive(true);
        let payload = null;
        try { payload = JSON.parse(event.data); } catch (e) { return; }
        // 사건은 "뭔가 바뀌었다"는 신호일 뿐 — 화면의 진실은 여전히 state 다. 바로 한 번 당겨온다.
        // (사건 안의 값으로 화면을 직접 고치면 서버와 화면이 두 벌로 갈라진다.)
        if (payload && payload.kind) load({quiet: true}).catch(() => {});
      };
      source.onerror = () => {
        try { source.close(); } catch (e) {}
        if (liveSource === source) liveSource = null;
        markLive(false);
        // 끊긴 채로 두면 폰이 절전에서 깨도 안 붙는다 — 점점 뜸하게, 최대 30초 간격으로 재시도.
        setTimeout(connectLive, liveBackoffMs);
        liveBackoffMs = Math.min(liveBackoffMs * 2, 30000);
      };
    }
    function disconnectLive() {
      if (!liveSource) return;
      try { liveSource.close(); } catch (e) {}
      liveSource = null;
      markLive(false);
    }
    // LIVE_STREAM_END
    // PUSH_OPT_IN_START
    // 폰이 잠겨 있어도 오는 알림. 아이폰은 **홈 화면에 추가**한 상태에서만 권한이 생기고,
    // 구독은 https 에서만 된다 — 안 되는 이유를 삼키지 말고 그대로 말해준다(그래야 형이 고친다).
    const NOTIFY_KEY = "marinaMobileNotify";
    function pushBlockedReason() {
      if (typeof navigator === "undefined" || !("serviceWorker" in navigator)
          || typeof window === "undefined" || !("PushManager" in window)) {
        // iOS 는 홈 화면에 설치해야 PushManager 가 생긴다. 사파리 탭에선 아무리 눌러도 안 된다.
        return isStandalone() ? "이 브라우저는 알림을 지원하지 않아요"
                              : "홈 화면에 추가한 뒤 거기서 열면 알림을 켤 수 있어요";
      }
      if (typeof window !== "undefined" && !window.isSecureContext)
        return "https 주소(원격 접속 주소)로 열어야 알림을 켤 수 있어요";
      if (typeof Notification !== "undefined" && Notification.permission === "denied")
        return "알림 권한이 거부돼 있어요 — 설정에서 허용해야 켜져요";
      return "";
    }
    function isStandalone() {
      // navigator·matchMedia 가 없는 환경(테스트 하네스, 구형 웹뷰)에서도 터지지 않아야 한다 —
      // 여기서 예외가 나면 그 아래 초기화가 통째로 멈춰 화면이 빈 채로 남는다.
      const nav = typeof navigator === "undefined" ? null : navigator;
      if (nav && nav.standalone) return true;
      return Boolean(typeof matchMedia === "function"
        && matchMedia("(display-mode: standalone)").matches);
    }
    function notifyOn() { return localStorage.getItem(NOTIFY_KEY) === "1"; }
    function updateNotifyButton() {
      const btn = document.getElementById("notifyBtn");
      if (!btn) return;
      const blocked = pushBlockedReason();
      const on = notifyOn() && !blocked;
      btn.textContent = on ? "\u{1F514}" : "\u{1F515}";
      btn.classList.toggle("active", on);
      btn.title = blocked || (on ? "알림 켜짐 — 누르면 꺼요" : "알림 꺼짐 — 누르면 켜요");
    }
    function urlBase64ToUint8Array(value) {
      const padded = (value + "=".repeat((4 - value.length % 4) % 4)).replace(/-/g, "+").replace(/_/g, "/");
      const raw = atob(padded);
      return Uint8Array.from([...raw].map(ch => ch.charCodeAt(0)));
    }
    async function enablePush() {
      const blocked = pushBlockedReason();
      if (blocked) { showToast(blocked); updateNotifyButton(); return; }
      const permission = await Notification.requestPermission();
      if (permission !== "granted") { showToast("알림 권한을 허용해야 켜져요"); updateNotifyButton(); return; }
      const registration = await navigator.serviceWorker.register("/sw.js", {scope: "/"});
      await registration.update().catch(() => {});   // 켜는 순간만큼은 최신 워커로
      await navigator.serviceWorker.ready;
      const keyResponse = await fetch("/mobile/api/push-key", {headers: headers()});
      const {key} = await keyResponse.json();
      if (!key) throw new Error("서버 키를 못 받았어요");
      const existing = await registration.pushManager.getSubscription();
      const subscription = existing || await registration.pushManager.subscribe({
        userVisibleOnly: true, applicationServerKey: urlBase64ToUint8Array(key),
      });
      await fetch("/mobile/api/push-subscribe", {
        method: "POST", headers: headers(true),
        body: JSON.stringify({endpoint: subscription.endpoint, label: navigator.platform || ""}),
      });
      localStorage.setItem(NOTIFY_KEY, "1");
      updateNotifyButton();
      showToast("알림을 켰어요 — 폰이 잠겨 있어도 와요");
    }
    async function disablePush() {
      localStorage.setItem(NOTIFY_KEY, "0");
      updateNotifyButton();
      try {
        const registration = await navigator.serviceWorker.getRegistration("/mobile");
        const subscription = registration && await registration.pushManager.getSubscription();
        if (subscription) {
          await fetch("/mobile/api/push-unsubscribe", {
            method: "POST", headers: headers(true),
            body: JSON.stringify({endpoint: subscription.endpoint}),
          });
          await subscription.unsubscribe();
        }
      } catch (e) { /* 이미 없으면 그만 — 끈 것은 로컬 표시가 진실이다 */ }
      showToast("알림을 껐어요");
    }
    const notifyBtn = document.getElementById("notifyBtn");
    if (notifyBtn) {
      notifyBtn.onclick = () => {
        (notifyOn() ? disablePush() : enablePush())
          .catch(error => { showToast(`알림 설정 실패 · ${String(error)}`); updateNotifyButton(); });
      };
      updateNotifyButton();
    }
    // 알림을 눌러 들어오면 그 세션을 연다(서비스워커가 열린 창에 알려준다).
    if (typeof navigator !== "undefined" && "serviceWorker" in navigator) {
      navigator.serviceWorker.addEventListener("message", event => {
        const data = event.data || {};
        if (data.type === "marina-open-session" && data.session) chooseSession(data.session);
      });
      // 켜둔 적이 있으면 조용히 다시 등록한다 — 서비스워커는 갱신돼야 고친 알림 로직이 걸린다.
      if (notifyOn() && !pushBlockedReason()) {
        // 서비스워커는 **스스로 갱신하지 않는다.** 등록만 다시 부르면 브라우저가 옛 워커를 그대로
        // 쓰는 경우가 있어, 고친 알림 코드가 폰에 영영 안 걸린다(형: 아이콘을 넣었는데 그대로).
        // update() 로 매번 새 파일을 확인하게 한다 — 서버가 no-cache 로 주므로 값싸다.
        navigator.serviceWorker.register("/sw.js", {scope: "/"})
          .then(registration => registration.update().catch(() => {}))
          .catch(() => {});
      }
    }
    // 설치 안내 — 주소창 숨김도 알림도 **홈 화면 추가** 한 번에 걸려 있다. iOS 사파리는 문서가
    // 스크롤될 때만 주소창을 숨기는데 마리나는 화면을 꽉 채운 고정 레이아웃이라 영영 안 숨는다.
    // 설치하면 주소창 자체가 없어진다. 이미 설치했거나 닫았으면 다시 띄우지 않는다.
    (function showInstallHint() {
      const hint = document.getElementById("installHint");
      if (!hint || isStandalone() || localStorage.getItem("marinaInstallHint") === "0") return;
      const nav = typeof navigator === "undefined" ? null : navigator;
      const iOS = Boolean(nav) && (/iPad|iPhone|iPod/.test(nav.userAgent || "")
        || (nav.platform === "MacIntel" && nav.maxTouchPoints > 1));
      if (!iOS) return;                       // 안드로이드·데스크톱은 브라우저가 알아서 안내한다
      hint.hidden = false;
      const close = document.getElementById("installHintClose");
      if (close) close.onclick = () => { hint.hidden = true; localStorage.setItem("marinaInstallHint", "0"); };
    })();
    // PUSH_OPT_IN_END
    setPollInterval(POLL_FALLBACK_MS);
    connectLive();
    document.addEventListener("visibilitychange", () => {
      // 화면을 끄면 스트림을 접는다(배터리·연결 수). 돌아오면 즉시 다시 붙고 한 번 당겨온다.
      if (document.visibilityState === "hidden") disconnectLive();
      else { liveBackoffMs = 1000; connectLive(); }
    });
    // CLI 버전은 하루 단위로만 바뀐다(서버도 30분 캐시) — 60초에 한 번이면 충분하다.
    loadCliUpdate();
    setInterval(loadCliUpdate, 60000);
    // 재방문 시 다음 폴(최대 3s) 기다리지 말고 즉시 갱신 — 탭 복귀·포커스·모바일 bfcache 복원 모두 커버(load 는 자체 loading 가드로 중복 방지).
    document.addEventListener("visibilitychange", quietPoll);
    window.addEventListener("focus", quietPoll);
    window.addEventListener("pageshow", quietPoll);
    load().then(() => {
      if (selectedSessionKey && (!history.state || history.state.view !== "chat")) history.pushState({view: "chat"}, "", location.href);
    }).catch(e => { statusEl.textContent = `실패 · ${String(e)}`; });
  </script>
</body>
</html>
"""
