"""Mobile control surface: token-protected, minimal phone UI for sending prompts."""
from __future__ import annotations

import hmac
import json
import os
import re
import secrets
import shlex
import subprocess
import threading
import time
import urllib.parse
from pathlib import Path
from typing import Any

from marina_registry import discover_all_roots
from marina_sessions import CLAUDE_MODEL_CATALOG, activate_agent_payloads, agent_runtime_settings, agents_payload, safe_root, worktree_info
from marina_state import MARINA_HOME, PORT
from marina_term import _agent_cli, term_input, term_list, term_open


TOKEN_FILE = MARINA_HOME / "mobile-token"
CLAUDE_HOME = Path(os.environ.get("CLAUDE_HOME", str(Path.home() / ".claude")))
CODEX_USER_HOME = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
AGENTS_HOME = Path(os.environ.get("AGENTS_HOME", str(Path.home() / ".agents")))
PENDING_SETTINGS_FILE = MARINA_HOME / "mobile-pending-agent-settings.json"
CODEX_MODELS_FILE = CODEX_USER_HOME / "models_cache.json"
_SESSION_SETTINGS_LOCK = threading.Lock()
_AGENT_SEND_LOCK = threading.Lock()
AGENT_INPUT_SETTLE_S = 0.16
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


def _persist_pending_session_settings(root: Path, source: str, sid: str,
                                      value: dict[str, str]) -> None:
    key = _session_settings_key(root, source, sid)
    with _SESSION_SETTINGS_LOCK:
        payload = _read_json(PENDING_SETTINGS_FILE)
        payload[key] = value
        PENDING_SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True)
        temporary = PENDING_SETTINGS_FILE.with_name(f".{PENDING_SETTINGS_FILE.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
        try:
            temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            os.chmod(temporary, 0o600)
            os.replace(temporary, PENDING_SETTINGS_FILE)
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def mobile_update_session_settings(body: dict[str, Any]) -> dict[str, str]:
    root = safe_root(str(body.get("root") or ""))
    source = str(body.get("source") or "")
    sid = str(body.get("sid") or "")
    value = {"model": str(body.get("model") or ""), "effort": str(body.get("effort") or "")}
    _agent_cli(source, sid, model=value["model"], effort=value["effort"])
    with _AGENT_SEND_LOCK:
        tid = _live_agent_tid(root, source, sid)
        if tid and source == "codex" and not _native_agent_active(root, source, sid):
            try:
                if _apply_live_codex_settings(tid, value["model"], value["effort"]):
                    _clear_pending_session_settings(root, source, sid)
                    return {**value, "applyMode": "live"}
            except (OSError, ValueError):
                pass
        _persist_pending_session_settings(root, source, sid, value)
    return {**value, "applyMode": "pending"}


def _clear_pending_session_settings(root: Path, source: str, sid: str) -> None:
    key = _session_settings_key(root, source, sid)
    with _SESSION_SETTINGS_LOCK:
        payload = _read_json(PENDING_SETTINGS_FILE)
        if key not in payload:
            return
        payload.pop(key, None)
        temporary = PENDING_SETTINGS_FILE.with_name(f".{PENDING_SETTINGS_FILE.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
        try:
            temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            os.chmod(temporary, 0o600)
            os.replace(temporary, PENDING_SETTINGS_FILE)
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


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
        for m in CLAUDE_MODEL_CATALOG
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
_QUESTION_STALE_S = 900   # PostToolUse 로 지워지는 게 정상이나, 고아(세션 죽음 등) 방지용 상한


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
    if time.time() - float(data.get("ts") or 0) > _QUESTION_STALE_S:
        return None
    return {"questions": questions, "toolUseId": str(data.get("toolUseId") or "")}


def mobile_state(refresh: bool = False) -> dict[str, Any]:
    worktrees: list[dict[str, Any]] = []
    sessions: list[dict[str, Any]] = []
    terms = term_list().get("sessions", [])
    for root in discover_all_roots(refresh):
        try:
            info = worktree_info(root, refresh)
            root_terms = [t for t in terms if str(t.get("root") or "") == str(root)]
            agent_terms = {
                (str(t["agent"].get("source") or ""), str(t["agent"].get("sid") or "")): t
                for t in root_terms if isinstance(t.get("agent"), dict) and bool(t.get("alive", True))
            }
            active_agents = {
                (str(t["agent"].get("source") or ""), str(t["agent"].get("sid") or ""))
                for t in root_terms if isinstance(t.get("agent"), dict)
            }
            agents = activate_agent_payloads(agents_payload(root, refresh), active_agents)
            title = info.get("sessionTitle") or info.get("headSubject") or ""
            label = " · ".join(str(x) for x in (info.get("alias"), title, info.get("projectLabel"), info.get("id")) if x)
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
            for agent in agents:
                source = str(agent.get("source") or "")
                sid = str(agent.get("sid") or "")
                preview = str(agent.get("preview") or "")
                pending_question = mobile_pending_question(source, sid)
                # pending 질문 = 에이전트가 '작업 실행 중'이 아니라 '답을 기다리는 중' → blocked(응답 필요)로 표시(형 지적).
                status = "blocked" if pending_question else (agent.get("status") or "idle")
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
                    "statusReason": "pending_question" if pending_question else (agent.get("statusReason") or ""),
                    "tid": str((agent_terms.get((source, sid)) or {}).get("tid") or ""),
                    "controllable": bool((agent_terms.get((source, sid)) or {}).get("tid")),
                    "externalActive": _agent_process_active(source, sid),
                    "settings": {
                        "current": agent_runtime_settings(root, source, sid),
                        "pending": mobile_pending_session_settings(root, source, sid),
                    },
                    "pendingQuestion": pending_question,
                })
            for term in root_terms:
                tid = str(term.get("tid") or "")
                agent_target = term.get("agent") if isinstance(term.get("agent"), dict) else None
                if agent_target:
                    continue
                target = {"type": "term", "tid": tid}
                sessions.append({
                    "key": f"term:{tid}",
                    "kind": "term",
                    "root": str(root),
                    "title": term.get("fg") or term.get("cmd") or tid,
                    "subtitle": f"터미널 · {label or root.name}",
                    "preview": term.get("preview") or "",
                    "tid": tid,
                    "target": target,
                    "turns": [],
                    "ts": term.get("created") or 0,
                })
            if not agents and not root_terms:
                sessions.append({
                    "key": f"shell:{root}",
                    "kind": "shell",
                    "root": str(root),
                    "title": label or root.name,
                    "subtitle": "새 셸",
                    "preview": str(root),
                    "target": {"type": "shell"},
                    "turns": [],
                    "ts": 0,
                })
        except Exception as exc:
            worktrees.append({"root": str(root), "error": str(exc), "agents": []})
    sessions.sort(key=lambda s: int(float(s.get("ts") or 0)), reverse=True)
    return {"worktrees": worktrees, "terms": terms, "sessions": sessions, "agentOptions": mobile_agent_options(), "serverInstance": _SERVER_INSTANCE}


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
    resolved = root.resolve()
    for item in term_list().get("sessions", []):
        agent = item.get("agent") if isinstance(item.get("agent"), dict) else {}
        if (
            bool(item.get("alive", True))
            and str(item.get("root") or "") == str(resolved)
            and str(agent.get("source") or "") == source
            and str(agent.get("sid") or "") == sid
        ):
            return str(item.get("tid") or "")
    return ""


def _agent_process_active(source: str, sid: str) -> bool:
    """Find a resume process that outlived Marina's in-memory PTY registry."""
    if source not in ("claude", "codex") or not sid:
        return False
    try:
        result = subprocess.run(
            ["ps", "-axo", "command="], check=False, capture_output=True,
            text=True, timeout=1,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    for line in result.stdout.splitlines():
        try:
            argv = shlex.split(line)
        except ValueError:
            continue
        for index, token in enumerate(argv):
            if Path(token).name != source:
                continue
            tail = argv[index + 1:]
            if source == "codex" and "resume" in tail:
                resume_index = tail.index("resume")
                if sid in tail[resume_index + 1:]:
                    return True
            if source == "claude":
                if any(token == f"--resume={sid}" for token in tail):
                    return True
                if "--resume" in tail:
                    resume_index = tail.index("--resume")
                    if resume_index + 1 < len(tail) and tail[resume_index + 1] == sid:
                        return True
    return False


def _native_agent_active(root: Path, source: str, sid: str) -> bool:
    """Use native transcript lifecycle when desktop apps hide the SID from ps."""
    return any(
        str(item.get("source") or "") == source
        and str(item.get("sid") or "") == sid
        and str(item.get("status") or "") == "working"
        for item in agents_payload(root, refresh=True)
    )


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
                saved = mobile_pending_session_settings(root, source, sid)
                if (
                    source == "codex"
                    and (saved["model"] or saved["effort"])
                    and not _native_agent_active(root, source, sid)
                ):
                    if not _apply_live_codex_settings(tid, saved["model"], saved["effort"]):
                        raise ValueError("예약한 모델 설정을 현재 CLI에 적용할 수 없어요. 세션을 다시 열어주세요")
                    _clear_pending_session_settings(root, source, sid)
                delivery = _deliver_agent_input(tid, source, text, str(body.get("delivery") or ""))
                return {"ok": True, "tid": tid, "opened": False, "delivery": delivery}
            if _agent_process_active(source, sid) or _native_agent_active(root, source, sid):
                raise ValueError("이 세션은 다른 앱이나 터미널에서 실행 중입니다. 완료된 뒤 다시 보내주세요")
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
            prompt_submitted = True
            _clear_pending_session_settings(root, source, sid)
    else:
        result = term_open(root, int(body.get("cols") or 80), int(body.get("rows") or 24))
        tid = str(result["tid"])
        opened = True
    if not prompt_submitted:
        term_input(tid, _input_payload(text))
    return {"ok": True, "tid": tid, "opened": opened}


def mobile_answer(body: dict[str, Any]) -> dict[str, Any]:
    # ① 질문 선택지 응답: AskUserQuestion 셀렉터(Claude Code 인터랙티브 목록)를 PTY 화살표+Enter 로 구동.
    # _apply_live_codex_settings 와 동일한 방식 — 커서가 첫 옵션에서 시작한다고 가정하고 아래로 N칸 이동 후 확정.
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
        raise ValueError("실행 중인 에이전트가 없어요")
    if answer_text:
        # 기타(직접 입력): 셀렉터에 텍스트를 타이핑 후 확정 — best-effort(실 셀렉터 동작 검증 필요).
        term_input(tid, answer_text[:2000])
        _agent_input_pause()
        term_input(tid, "\r")
        return {"ok": True, "tid": tid, "text": True}
    try:
        option_index = int(body.get("optionIndex", 0))
    except (TypeError, ValueError):
        raise ValueError("optionIndex 필요")
    if option_index < 0 or option_index > 50:
        raise ValueError("optionIndex 범위")
    if option_index:
        term_input(tid, "\x1b[B" * option_index)
        _agent_input_pause()
    term_input(tid, "\r")
    return {"ok": True, "tid": tid, "optionIndex": option_index}


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
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Marina Mobile</title>
  <style>
    :root { color-scheme: light dark; font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; overflow: hidden; background: #f4f6f9; color: #17191f; }
    #mobileApp { --app-height: 100dvh; height: var(--app-height); min-height: 0; display: none; grid-template-rows: auto minmax(0, 1fr) auto; overflow: hidden; }
    #mobileLogin { min-height: 100vh; display: none; align-items: stretch; justify-content: center; flex-direction: column; padding: 24px; box-sizing: border-box; gap: 14px; }
    #mobileLogin form { display: flex; flex-direction: column; gap: 10px; }
    header { position: relative; z-index: 4; display: grid; gap: 4px; padding: 4px 8px 6px; box-sizing: border-box; background: #fff; border-bottom: 1px solid #dde2ea; }
    .shellRow { display: grid; grid-template-columns: 36px minmax(0, 1fr) auto; gap: 5px; align-items: center; min-height: 38px; }
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
    .servicesBtn { width: auto; min-width: 54px; min-height: 32px; padding: 0 8px; color: #303846; font-size: 11px; font-variant-numeric: tabular-nums; white-space: nowrap; }
    .shellActions { display: flex; align-items: center; gap: 3px; }
    .chatNavTitle { display: none; min-width: 0; overflow: hidden; font-size: 13px; font-weight: 900; text-overflow: ellipsis; white-space: nowrap; }
    .usageBtn { display: none; width: 32px; min-width: 32px; height: 32px; min-height: 32px; padding: 0; border-color: transparent; background: transparent; color: #4d5665; font-size: 18px; }
    #mobileApp[data-view="chat"] header { gap: 0; padding-bottom: 4px; }
    #mobileApp[data-view="chat"] .shellRow { grid-template-columns: 32px minmax(0, 1fr) 32px; min-height: 34px; }
    #mobileApp[data-view="chat"] #projectTabs, #mobileApp[data-view="chat"] #sourceTabs, #mobileApp[data-view="chat"] #servicesBtn { display: none; }
    #mobileApp[data-view="chat"] .chatNavTitle { display: block; }
    #mobileApp[data-view="chat"] .usageBtn.available { display: inline-flex; align-items: center; justify-content: center; }
    #mobileApp[data-view="chat"] main { padding: 6px 10px; }
    .search-input { min-height: 40px; }
    .session-list { display: flex; flex-direction: column; gap: 12px; }
    .session-group { display: flex; flex-direction: column; gap: 6px; }
    .session-group-title { display: flex; align-items: center; justify-content: space-between; padding: 0 2px; color: #596070; font-size: 11px; font-weight: 900; text-transform: uppercase; }
    .session-card { display: block; min-height: 88px; height: auto; padding: 10px 11px; text-align: left; color: inherit; border-color: #d8dee7; overflow: hidden; }
    .session-card.active { border-color: #0b63ce; box-shadow: 0 0 0 1px #0b63ce inset; }
    .session-card-top { display: flex; align-items: center; gap: 7px; min-width: 0; }
    .session-title { display: block; min-width: 0; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 850; line-height: 1.25; }
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
    .turnState { margin-top: 5px; color: #687083; font-size: 10px; font-weight: 750; }
    .turnState.failed { color: #c43d3d; cursor: pointer; text-decoration: underline; text-underline-offset: 2px; }
    .queuedTag { display: inline-block; margin-bottom: 4px; padding: 1px 6px; border-radius: 6px; background: rgba(11, 99, 206, .12); color: #0b63ce; font-size: 9px; font-weight: 850; }
    .queuedTag.consumed { background: rgba(107, 114, 128, .14); color: #6b7280; }
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
    .turnAttachments { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 6px; }
    .turnAttachments img { max-width: 180px; max-height: 180px; border-radius: 6px; object-fit: cover; }
    .turnAttachments a { font-size: 11px; }
    .liveQuestion:empty { display: none; }
    .liveQuestion { margin-bottom: 2px; }
    .questionCard { align-self: stretch; display: flex; flex-direction: column; gap: 8px; padding: 11px 12px; border: 1px solid #b9d4f2; border-radius: 10px; background: #f2f8ff; }
    .questionHeader { color: #0b63ce; font-size: 9px; font-weight: 850; text-transform: uppercase; letter-spacing: .04em; }
    .questionText { font-size: 13px; font-weight: 650; line-height: 1.45; }
    .questionOpts { display: flex; flex-direction: column; gap: 6px; }
    .questionOpt { display: flex; flex-direction: column; align-items: flex-start; gap: 2px; width: 100%; min-height: 40px; padding: 8px 11px; border: 1px solid #b9c6d8; border-radius: 8px; background: #fff; text-align: left; }
    .questionOpt:disabled { opacity: .55; }
    .questionOptLabel { font-size: 12px; font-weight: 800; color: #1f2733; }
    .questionOptDesc { font-size: 10px; color: #63708a; line-height: 1.4; }
    .questionMore { color: #63708a; font-size: 10px; }
    .questionOther { color: #4d5665; font-weight: 700; }
    .questionOtherRow { display: flex; gap: 6px; margin-top: 2px; }
    .questionOtherInput { flex: 1; min-height: 38px; max-height: 100px; padding: 8px 10px; resize: none; }
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
    .sheetBackdrop { position: fixed; inset: 0; z-index: 8; display: none; align-items: flex-end; background: rgb(10 14 20 / 38%); }
    .sheetBackdrop.open { display: flex; }
    .bottomSheet { width: 100%; max-height: 78vh; overflow: hidden; border-radius: 8px 8px 0 0; background: #fff; box-shadow: 0 -12px 34px rgb(0 0 0 / 18%); }
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
      body { background: #11151c; color: #f4f6f9; }
      header, select, textarea, input, button { background: #171d27; color: #f4f6f9; border-color: #303846; }
      label, p, .status { color: #a5adba; }
      .chatComposer { background: #171d27; border-color: #303846; }
      .attachBtn { background: #222c3a; color: #c4ccd8; border-color: #3a4453; }
      .attachChip { background: #1c2431; border-color: #343f4e; color: #c4ccd8; }
      .questionCard { background: #16202e; border-color: #2c4a6b; }
      .questionText { color: #e8edf4; }
      .questionOpt { background: #1c2431; border-color: #3a4453; }
      .questionOptLabel { color: #e8edf4; }
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
      .liveAction { color: #e3e7ed; }
      .session-preview { color: #d6dbe4; }
      .iconBtn, .servicesBtn { color: #d6dbe4; }
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
        <button class="iconBtn backBtn" id="backBtn" type="button" title="세션 목록" aria-label="세션 목록으로" style="display:none">&#8592;</button>
        <div class="project-strip" id="projectTabs" aria-label="프로젝트"></div>
        <div class="chatNavTitle" id="chatNavTitle"></div>
        <div class="shellActions">
          <button class="usageBtn" id="usageBtn" type="button" title="토큰 사용량" aria-label="토큰 사용량">&#9684;</button>
          <button class="servicesBtn" id="servicesBtn" type="button" aria-label="서비스 상태">서버 <span id="servicesCount">-/-</span></button>
        </div>
      </div>
      <div class="source-tabs" id="sourceTabs" aria-label="세션 종류"></div>
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
      <section id="listView">
        <input class="search-input" id="sessionSearch" aria-label="세션 검색" placeholder="세션 검색" />
        <div class="session-list" id="sessionList"></div>
      </section>
      <section id="chatView">
        <label class="hiddenSelect">워크트리<select id="rootSelect"></select></label>
        <label class="hiddenSelect">대상<select id="targetSelect"></select></label>
        <div class="historyStatus" id="historyStatus" aria-live="polite"></div>
        <div class="turns" id="turns"></div>
        <button class="newMessagesBtn" id="newMessagesBtn" type="button">새 메시지</button>
    <button class="updateBanner" id="updateBanner" type="button">새 버전 · 탭하여 새로고침</button>
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
        <div class="serviceList"><div id="serviceList"></div><div class="serviceUtilities"><button id="inboxMenuBtn" type="button">받은 작업 <span id="inboxCount">0</span></button><button id="refreshBtn" type="button">새로고침</button><button id="logoutBtn" type="button">로그아웃</button></div></div>
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
    <div class="toast" id="toast" role="status" aria-live="polite"></div>
  </div>
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
    const chatNavTitle = document.getElementById("chatNavTitle");
    const usageBtn = document.getElementById("usageBtn");
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
    const projectTabs = document.getElementById("projectTabs");
    const sourceTabs = document.getElementById("sourceTabs");
    const turnsEl = document.getElementById("turns");
    const historyStatus = document.getElementById("historyStatus");
    const suggestionsEl = document.getElementById("suggestions");
    const newMessagesBtn = document.getElementById("newMessagesBtn");
    const updateBanner = document.getElementById("updateBanner");
    updateBanner.onclick = () => location.reload();
    const liveQuestionEl = document.getElementById("liveQuestion");
    let questionAnsweredAt = 0;   // 탭 직후 잠깐 카드 숨김(낙관적) — 실제론 PostToolUse 훅이 상태파일 지워 사라짐
    // pending AskUserQuestion(훅이 잡은 라이브 소스)을 입력창 위에 카드로. 트랜스크립트엔 답 전까지 없으므로 이게 유일한 라이브 표시.
    function renderLiveQuestion(session) {
      const pq = session && session.pendingQuestion;
      const suppress = Date.now() - questionAnsweredAt < 4000;   // 방금 답함 — 상태파일 정리될 시간 줌
      if (!pq || !Array.isArray(pq.questions) || !pq.questions.length || suppress) {
        if (liveQuestionEl.innerHTML) liveQuestionEl.innerHTML = "";
        return;
      }
      const canAnswer = session.kind === "agent" && session.controllable && sessionSource(session) === "claude";
      const item = {name: "AskUserQuestion", detail: JSON.stringify({questions: pq.questions})};
      const html = renderQuestionCard(item, canAnswer);
      if (liveQuestionEl.innerHTML !== html) liveQuestionEl.innerHTML = html;
    }
    liveQuestionEl.addEventListener("click", event => {
      const opt = event.target.closest && event.target.closest("[data-answer-option]");
      if (opt) {
        const index = parseInt(opt.getAttribute("data-answer-option"), 10);
        if (!Number.isNaN(index)) { questionAnsweredAt = Date.now(); liveQuestionEl.innerHTML = ""; answerQuestion({optionIndex: index}); }
        return;
      }
      if (event.target.closest && event.target.closest("[data-answer-other]")) {
        const row = liveQuestionEl.querySelector("[data-question-other-row]");
        if (row) { row.style.display = "flex"; const ta = row.querySelector("textarea"); if (ta) ta.focus(); }
        return;
      }
      if (event.target.closest && event.target.closest("[data-answer-other-send]")) {
        const ta = liveQuestionEl.querySelector(".questionOtherInput");
        const text = ta ? ta.value.trim() : "";
        if (text) { questionAnsweredAt = Date.now(); liveQuestionEl.innerHTML = ""; answerQuestion({text}); }
        return;
      }
    });
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
    const servicesBtn = document.getElementById("servicesBtn");
    const servicesCount = document.getElementById("servicesCount");
    const servicesSheet = document.getElementById("servicesSheet");
    const serviceList = document.getElementById("serviceList");
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
    const autoPollMs = 3000;
    let loading = false;
    let sending = false;
    let optimisticWorkUntil = 0;   // send 직후 폴이 working 잡을 때까지 낙관적으로 '작업 중'+정지버튼 표시(가만있는 느낌 방지)
    let lastActivity = "";
    let sawActivity = false;
    let selectedSessionKey = localStorage.getItem("marinaMobileSession") || "";
    let selectedProjectId = localStorage.getItem("marinaMobileProject") || "";
    let sourceFilter = localStorage.getItem("marinaMobileSource") || "all";
    let sessionStructureKey = "";
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
    const historyCache = {};
    const activityCache = {};
    const catalogCache = {};
    const usageCache = {};
    const openTimelineDetailIds = new Set();
    let historyLoading = false;
    const sourceMeta = {
      codex: {label: "Codex", badge: "CX"},
      claude: {label: "Claude", badge: "CC"},
      terminal: {label: "Terminal", badge: "TERM"},
    };
    function showLogin(message="") {
      app.style.display = "none";
      login.style.display = "flex";
      loginStatus.textContent = message;
    }
    function showApp() {
      login.style.display = "none";
      app.style.display = "grid";
    }
    function showList() {
      app.setAttribute("data-view", "list");
      listView.style.display = "flex";
      chatView.style.display = "none";
      chatComposer.style.display = "none";
      backBtn.style.display = "none";
      closeUsagePanel();
      closeSubagents();
      closeInbox();
    }
    function showChat() {
      app.setAttribute("data-view", "chat");
      listView.style.display = "none";
      chatView.style.display = "grid";
      chatComposer.style.display = "flex";
      backBtn.style.display = "inline-block";
    }
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
      sessionStructureKey = "";
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
    function esc(value) {
      return String(value ?? "").replace(/[&<>"']/g, ch => ({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[ch]));
    }
    function renderInlineMarkdown(value) {
      return esc(value)
        .replace(/`([^`\n]+)`/g, "<code>$1</code>")
        .replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>")
        .replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<em>$2</em>");
    }
    function renderRichText(value) {
      const text = String(value ?? "");
      const pattern = /\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)|(https?:\/\/[^\s<>]+)/g;
      let html = "";
      let cursor = 0;
      for (const match of text.matchAll(pattern)) {
        html += renderInlineMarkdown(text.slice(cursor, match.index));
        const label = match[1] || match[3];
        let url = match[2] || match[3];
        let suffix = "";
        if (!match[2]) {
          const trailing = url.match(/[.,!?;:)]+$/);
          if (trailing) {
            suffix = trailing[0];
            url = url.slice(0, -suffix.length);
          }
        }
        html += `<a href="${esc(url)}" target="_blank" rel="noopener noreferrer">${renderInlineMarkdown(label.slice(0, label.length - suffix.length))}</a>${esc(suffix)}`;
        cursor = match.index + match[0].length;
      }
      html += renderInlineMarkdown(text.slice(cursor));
      return html.replace(/\n/g, "<br>");
    }
    function renderActivityCode(value, type) {
      const escaped = esc(String(value ?? ""));
      if (type !== "diff") return escaped;   // diff 활동만 unified-diff 색칠(다른 출력의 +/- 오탐 방지)
      return escaped.split("\n").map(line => {
        if (line.startsWith("@@")) return `<span class="diffHunk">${line}</span>`;
        if (line.startsWith("+") && !line.startsWith("+++")) return `<span class="diffAdd">${line}</span>`;
        if (line.startsWith("-") && !line.startsWith("---")) return `<span class="diffDel">${line}</span>`;
        return line;
      }).join("\n");
    }
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
    function sessionSource(session) {
      const raw = String((session && (session.source || (session.target && session.target.source))) || "").toLowerCase();
      if (raw === "codex") return "codex";
      if (raw === "claude") return "claude";
      return "terminal";
    }
    function rememberProjectForRoot(root) {
      const wt = worktreeForRoot(root);
      if (!wt) return;
      selectedProjectId = projectId(wt);
      localStorage.setItem("marinaMobileProject", selectedProjectId);
    }
    function selectedRoot() { return rootSelect.value || (state.worktrees[0] && state.worktrees[0].root) || ""; }
    function targetKey(root=selectedRoot()) { return `marinaMobileTarget:${root}`; }
    function selectedSession() { return (state.sessions || []).find(s => s.key === selectedSessionKey) || null; }
    function termKey(tid) { return `term:${tid}`; }
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
    function pendingDeliveryLabel(delivery, createdAt=0) {
      // queue/steer/started 는 서버가 이미 전달을 확정한 상태 — 에이전트가 현재 턴을 끝내야 트랜스크립트에
      // 나타나므로(긴 턴이면 수 분) 나이와 무관하게 제 라벨을 유지한다. 예전엔 10초 지나면 무조건
      // "전달 확인 안 됨" 으로 뒤집혀 큐 메시지가 오탐으로 실패처럼 보였다(형 피드백).
      if (delivery === "steer") return "현재 작업에 전달됨";
      if (delivery === "queue") return "작업 끝나면 전달돼요 · 대기열";
      if (delivery === "started") return "새 작업 시작 중";
      if (delivery === "failed") return "전송 안 됨 · 탭해서 다시 보내기";
      // delivery 미확정(서버 응답 전 pending)만 오래되면 실패로 표기.
      if (createdAt && Date.now() - Number(createdAt) > 15000) return "전달 확인 안 됨";
      return "전송 확인 중";
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
    function queuePendingTurn(key, text, delivery="pending") {
      const session = (state.sessions || []).find(item => item.key === key);
      const cached = sessionHistory(session);
      const norm = normUserText(text);
      const confirmed = confirmedUserCounts((cached && cached.turns) || (session && session.turns) || [], cached && cached.timeline);
      const confirmedCount = confirmed.get(norm) || 0;
      const existing = pendingTurns[key] || [];
      const pendingCount = existing.filter(turn => normUserText(turn.text) === norm).length;
      pendingTurns[key] = existing.concat([{role: "user", text, baseline: confirmedCount + pendingCount, pending: true, delivery, createdAt: Date.now()}]).slice(-12);
    }
    function selectAgentAfterSend(text, target, delivery="pending") {
      const root = selectedRoot();
      const current = selectedSession();
      const key = current && sameTarget(current.target, target) ? selectedSessionKey : agentSessionKey(target, root);
      selectedSessionKey = key;
      localStorage.setItem("marinaMobileSession", key);
      queuePendingTurn(key, text, delivery);
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
    function selectReturnedTerm(tid, text, target=null, delivery="pending") {
      if (target && target.type === "agent") {
        selectAgentAfterSend(text, target, delivery);
        return;
      }
      const root = selectedRoot();
      const key = ensureLiveTermSession(tid, root, text, target);
      queuePendingTurn(key, text);
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
      if (!projects.some(p => p.id === selectedProjectId)) {
        const current = selectedSession();
        const currentProject = current ? sessionProjectId(current) : "";
        selectedProjectId = projects.some(p => p.id === currentProject) ? currentProject : ((projects[0] && projects[0].id) || "");
        if (selectedProjectId) localStorage.setItem("marinaMobileProject", selectedProjectId);
      }
      const html = projects.map(p => `<button class="project-chip ${p.id === selectedProjectId ? "active" : ""}" type="button" data-project="${esc(p.id)}" title="${esc(p.label)}">${esc(p.label)}<span class="project-count">${p.count}</span></button>`).join("");
      updateHtmlIfChanged(projectTabs, html);
    }
    function projectSessions() {
      return (state.sessions || []).filter(s => !selectedProjectId || sessionProjectId(s) === selectedProjectId);
    }
    function renderSourceTabs() {
      const sessions = projectSessions();
      const counts = {all: sessions.length, codex: 0, claude: 0, terminal: 0};
      sessions.forEach(s => counts[sessionSource(s)] += 1);
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
    function runtimeLabel(runtime, includeSource="") {
      const parts = [includeSource, displayModel(runtime && runtime.model), runtime && runtime.effort].filter(Boolean);
      return parts.join(" · ");
    }
    function sessionSubtitle(session) {
      const current = session && session.settings && session.settings.current;
      const runtime = runtimeLabel(current);
      return [session.subtitle || session.root || "", runtime].filter(Boolean).join(" · ");
    }
    function sessionCard(session) {
      const source = sessionSource(session);
      const meta = sourceMeta[source];
      return `<button class="session-card ${session.key === selectedSessionKey ? "active" : ""}" type="button" data-key="${esc(session.key)}">
        <span class="session-card-top"><span class="source-badge ${source}">${meta.badge}</span><span class="session-title" data-session-title>${esc(session.title || session.key)}</span></span>
        <span class="session-subtitle" data-session-subtitle>${esc(sessionSubtitle(session))}</span>
        <span class="session-preview" data-session-preview>${esc(session.preview || "(최근 작업 없음)")}</span>
      </button>`;
    }
    function renderSessions() {
      const q = sessionSearch.value.trim().toLowerCase();
      const sessions = projectSessions().filter(s => {
        if (sourceFilter !== "all" && sessionSource(s) !== sourceFilter) return false;
        return !q || [s.title, s.subtitle, s.preview, s.root].some(v => String(v || "").toLowerCase().includes(q));
      }).slice(0, 40);
      if (!sessions.length) {
        const emptyKey = `empty|${selectedProjectId}|${sourceFilter}|${q}`;
        if (sessionStructureKey !== emptyKey) {
          sessionList.innerHTML = `<div class="empty-state">${q ? "검색 결과가 없습니다." : "이 분류에 열린 세션이 없습니다."}</div>`;
          sessionStructureKey = emptyKey;
        }
        return;
      }
      const sources = sourceFilter === "all" ? ["codex", "claude", "terminal"] : [sourceFilter];
      const structure = sessions.map(s => `${sessionSource(s)}:${s.key}`).sort().join("|");
      const nextStructureKey = `${selectedProjectId}|${sourceFilter}|${q}|${structure}`;
      if (sessionStructureKey !== nextStructureKey) {
        sessionList.innerHTML = sources.map(source => {
          const grouped = sessions.filter(s => sessionSource(s) === source);
          if (!grouped.length) return "";
          const meta = sourceMeta[source];
          return `<section class="session-group"><div class="session-group-title"><span>${meta.label}</span><span>${grouped.length}</span></div>${grouped.map(sessionCard).join("")}</section>`;
        }).join("");
        sessionStructureKey = nextStructureKey;
        return;
      }
      const cards = new Map([...sessionList.querySelectorAll("[data-key]")].map(card => [card.getAttribute("data-key"), card]));
      sessions.forEach(session => {
        const card = cards.get(session.key);
        if (!card) return;
        card.classList.toggle("active", session.key === selectedSessionKey);
        card.querySelector("[data-session-title]").textContent = session.title || session.key;
        card.querySelector("[data-session-subtitle]").textContent = sessionSubtitle(session);
        card.querySelector("[data-session-preview]").textContent = session.preview || "(최근 작업 없음)";
      });
    }
    function mergeHistoryTurns(existing, incoming) {
      const out = existing.slice();
      const ids = new Set(out.filter(turn => turn.id).map(turn => turn.id));
      const legacy = new Set(out.filter(turn => !turn.id).map(turn => `${turn.role}\n${turn.text}`));
      for (const turn of incoming || []) {
        if (turn.id) {
          if (ids.has(turn.id)) continue;
          ids.add(turn.id);
        } else {
          const key = `${turn.role}\n${turn.text}`;
          if (legacy.has(key)) continue;
          legacy.add(key);
        }
        out.push(turn);
      }
      if (out.every(turn => /^\d+:\d+$/.test(String(turn.id || "")))) {
        out.sort((a, b) => Number(a.id.split(":", 1)[0]) - Number(b.id.split(":", 1)[0]));
      }
      return out;
    }
    function timelineFromTurns(turns) {
      return (turns || []).map((turn, index) => ({
        ...turn, kind: "message", id: turn.id || `legacy:message:${index}:${turn.role || "assistant"}`,
      }));
    }
    function mergeTimelineItems(existing, incoming, prepend=false) {
      const ordered = prepend ? (incoming || []).concat(existing || []) : (existing || []).concat(incoming || []);
      const seen = new Set();
      return ordered.filter((item, index) => {
        const id = String(item.id || `legacy:${item.kind || "message"}:${item.role || ""}:${index}:${item.text || item.label || ""}`);
        if (seen.has(id)) return false;
        seen.add(id);
        return true;
      });
    }
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
    const activityTypeLabels = {skill: "Skill", command: "명령", diff: "Diff", file: "파일", agent: "에이전트", progress: "진행", tool: "도구"};
    function conversationExchanges(items) {
      const exchanges = [];
      let current = null;
      (items || []).forEach((item, index) => {
        // 큐 메시지는 진행 중 턴에 끼어든 steering — 새 exchange 를 시작하지 않고 현재 exchange 에 인라인으로 붙는다
        // (안 그러면 실제 작업/답이 마지막 큐 메시지 exchange 로 쏠려 원 메시지가 답 없이 남음 — 형 지적).
        const startsExchange = item.kind === "message" && item.role === "user" && !item.queued;
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
    function exchangeSections(exchange) {
      const items = (exchange && exchange.items) || [];
      const user = exchange && exchange.user;
      let assistantIndex = -1;
      for (let index = items.length - 1; index >= 0; index -= 1) {
        if (items[index].kind === "message" && items[index].role === "assistant") { assistantIndex = index; break; }
      }
      const isQueuedMsg = it => it.kind === "message" && it.role === "user" && it.queued;
      const queued = items.filter(it => it !== user && isQueuedMsg(it));   // 진행 중 끼어든 큐 메시지 → 인라인 말풍선
      const activities = items.filter((item, index) => item !== user && index !== assistantIndex && !isQueuedMsg(item)).map((item, index) => {
        if (item.kind === "activity") return item;
        return {id: `progress:${item.id || index}`, kind: "activity", activityType: "progress", label: "진행 메모", detail: item.text || "", result: "", status: "completed"};
      });
      return {user, queued, activities, assistant: assistantIndex >= 0 ? items[assistantIndex] : null};
    }
    function exchangeRuntime(exchange, session=null, allowFallback=false) {
      const items = ((exchange && exchange.items) || []).slice().reverse();
      const item = items.find(value => value && (value.model || value.effort));
      if (item) return {model: item.model || "", effort: item.effort || ""};
      if (allowFallback && session && session.settings) return session.settings.current || {model: "", effort: ""};
      return {model: "", effort: ""};
    }
    function renderTurnMeta(exchange, session, allowFallback=false, alignRight=false) {
      const runtime = exchangeRuntime(exchange, session, allowFallback);
      const label = runtimeLabel(runtime);   // 소스접두 없이 브랜드 포함 모델명(+effort) — "Claude Opus 4.8 · high"
      // 응답 전(내 메시지 밑)=우측(내 말풍선 쪽), 응답 후(Claude 응답 밑)=좌측(응답 말풍선 쪽).
      return label ? `<div class="turnMeta${alignRight ? " right" : ""}">${esc(label)}</div>` : "";
    }
    function renderLiveAction(exchange, sections, session, isLatest) {
      if (!isLatest || !session || session.status !== "working") return "";
      const running = sections.activities.filter(item => item.status === "running");
      // 실제 '실행 중'인 활동이 있을 때만 스피너. 활동 없이 대기/응답만 남은 상태를 실행 중처럼 보이게 하지 않기(형 지적).
      const current = running[running.length - 1];
      if (!current) return "";
      const label = current.label || current.name || activityTypeLabels[current.activityType] || "작업 중";
      const runtime = exchangeRuntime(exchange, session, true);
      const meta = runtimeLabel(runtime);
      const target = sections.activities.length ? `group:exchange:${exchange.id}` : "";
      return `<button class="liveAction" type="button" data-live-action="${esc(target)}"><span class="liveActionDot"></span><span class="liveActionLabel">${esc(label)}</span><span class="liveActionMeta">${esc(meta)}</span></button>`;
    }
    const UPLOAD_PATH_RE = /(?:^|\s)(\/[^\s]*\/mobile-uploads\/[^\s]+)/g;
    function extractAttachments(text) {
      const items = [];
      let stripped = text;
      for (const match of text.matchAll(UPLOAD_PATH_RE)) {
        const path = match[1];
        const name = path.split("/").pop().replace(/^[0-9a-f]{16}-/, "");
        items.push({path, name, url: uploadServeUrl(path), isImage: IMAGE_EXT_RE.test(path)});
        stripped = stripped.replace(path, "");
      }
      return {items, stripped: stripped.replace(/\n{3,}/g, "\n\n").trim()};
    }
    function renderTurnAttachments(items) {
      if (!items.length) return "";
      const cells = items.map(a => a.isImage
        ? `<a href="${esc(a.url)}" target="_blank" rel="noopener noreferrer"><img src="${esc(a.url)}" alt="${esc(a.name)}" loading="lazy" /></a>`
        : `<a href="${esc(a.url)}" target="_blank" rel="noopener noreferrer">${esc(a.name)}</a>`).join("");
      return `<div class="turnAttachments">${cells}</div>`;
    }
    function renderTimelineMessage(item) {
      const text = String(item.text || "");
      const role = item.role === "user" ? "user" : item.role === "output" ? "output" : "assistant";
      const {items: attachments, stripped} = extractAttachments(text);
      const pendingState = item.pending ? `<div class="turnState${item.failed ? " failed" : ""}"${item.failed ? ` data-resend-text="${esc(item.text || "")}"` : ""}>${esc(pendingDeliveryLabel(item.delivery, item.createdAt))}</div>` : "";
      const queuedBadge = item.queued
        ? `<span class="queuedTag${item.queuedConsumed ? " consumed" : ""}">⏱ ${item.queuedConsumed ? "대기열에서 전달됨" : "대기열 · 대기 중"}</span>`
        : "";
      return `<div class="turn ${role}${item.pending ? " pending" : ""}${item.queued ? " queued" : ""}" data-timeline-message-id="${esc(item.id || "")}">${queuedBadge}<div class="turnBody">${renderRichText(stripped)}</div>${renderTurnAttachments(attachments)}${pendingState}</div>`;
    }
    function timelineDetailAttrs(id) {
      const value = String(id || "detail");
      return `data-timeline-detail="${esc(value)}"${openTimelineDetailIds.has(`${selectedSessionKey}:${value}`) ? " open" : ""}`;
    }
    function renderActivityGroup(items, stableId="") {
      if (!items.length) return "";
      const counts = {};
      items.forEach(item => { const key = item.activityType || "tool"; counts[key] = (counts[key] || 0) + 1; });
      const categories = ["skill", "command", "diff", "file", "agent"].filter(key => counts[key]).map(key => `${activityTypeLabels[key]} ${counts[key]}`);
      const summary = [`작업 ${items.length}`, ...categories].join(" · ");
      const rows = items.map(item => {
        const type = item.activityType || "tool";
        const status = ["running", "failed"].includes(item.status) ? item.status : "completed";
        const detail = String(item.detail || "");
        const result = String(item.result || "");
        const body = [
          detail ? `<span class="activityBodyLabel">입력</span><pre class="activityCode">${renderActivityCode(detail, type)}</pre>` : "",
          result ? `<span class="activityBodyLabel">결과</span><pre class="activityCode">${renderActivityCode(result, type)}</pre>` : "",
        ].join("");
        return `<details class="activityItem ${status}" data-activity-detail ${timelineDetailAttrs(`item:${item.id || item.label || "activity"}`)}><summary><span class="activityDot"></span><span class="activityLabel">${esc(item.label || item.name || activityTypeLabels[type] || "작업")}</span><span class="activityType">${esc(activityTypeLabels[type] || "도구")}</span></summary>${body ? `<div class="activityBody">${body}</div>` : ""}</details>`;
      }).join("");
      const groupId = stableId ? `group:${stableId}` : `group:${items[0].id || "first"}`;
      return `<details class="activityGroup" ${timelineDetailAttrs(groupId)}><summary>${esc(summary)}</summary><div class="activityList">${rows}</div></details>`;
    }
    function renderTimelineSequence(items) {
      const html = [];
      let activities = [];
      const flush = () => { if (activities.length) html.push(renderActivityGroup(activities)); activities = []; };
      (items || []).forEach(item => {
        if (item.kind === "activity") activities.push(item);
        else { flush(); html.push(renderTimelineMessage(item)); }
      });
      flush();
      return html.join("");
    }
    function questionsFromActivity(item) {
      if (!item || item.name !== "AskUserQuestion") return null;
      try {
        const parsed = JSON.parse(item.detail || "{}");
        const questions = parsed.questions || (parsed.input && parsed.input.questions);
        return Array.isArray(questions) && questions.length ? questions : null;
      } catch (e) { return null; }
    }
    function pendingQuestionActivity(sections) {
      return (sections.activities || []).find(item =>
        item.name === "AskUserQuestion" && item.status !== "completed" && questionsFromActivity(item));
    }
    function renderQuestionCard(item, interactive) {
      const questions = questionsFromActivity(item);
      if (!questions) return "";
      const first = questions[0] || {};
      const options = Array.isArray(first.options) ? first.options : [];
      const header = first.header ? `<div class="questionHeader">${esc(first.header)}</div>` : "";
      const q = first.question ? `<div class="questionText">${renderRichText(String(first.question))}</div>` : "";
      const more = questions.length > 1 ? `<div class="questionMore">외 ${questions.length - 1}개 질문 — 첫 질문에 응답합니다</div>` : "";
      const buttons = options.map((opt, index) => {
        const label = esc(String(opt.label || opt.value || `옵션 ${index + 1}`));
        const desc = opt.description ? `<span class="questionOptDesc">${esc(String(opt.description))}</span>` : "";
        const attrs = interactive ? `data-answer-option="${index}"` : "disabled";
        return `<button class="questionOpt" type="button" ${attrs}><span class="questionOptLabel">${label}</span>${desc}</button>`;
      }).join("");
      // 기타(직접 입력) — AskUserQuestion 은 항상 자유 입력을 허용한다.
      const other = interactive
        ? `<button class="questionOpt questionOther" type="button" data-answer-other>&#9998; 기타 (직접 입력)</button>`
          + `<div class="questionOtherRow" data-question-other-row style="display:none"><textarea class="questionOtherInput" rows="1" placeholder="직접 입력..." enterkeyhint="send"></textarea><button class="primary questionOtherSend" type="button" data-answer-other-send>보내기</button></div>`
        : "";
      const note = interactive ? "" : `<div class="questionMore">이 세션이 실행 중일 때만 응답할 수 있어요</div>`;
      return `<div class="questionCard">${header}${q}<div class="questionOpts">${buttons}${other}</div>${more}${note}</div>`;
    }
    function renderConversationSequence(exchange, session, isLatest=false) {
      const sections = exchangeSections(exchange);
      const question = pendingQuestionActivity(sections);
      const canAnswer = Boolean(isLatest && session && session.kind === "agent" && session.controllable
        && sessionSource(session) === "claude");
      const body = [
        sections.user ? renderTimelineMessage(sections.user) : "",
        (sections.queued || []).map(renderTimelineMessage).join(""),   // 원 메시지 바로 뒤에 큐 메시지들 인라인
        renderActivityGroup(sections.activities, `exchange:${exchange.id}`),
        sections.assistant ? renderTimelineMessage(sections.assistant) : "",
        question ? renderQuestionCard(question, canAnswer) : "",
        renderTurnMeta(exchange, session, isLatest, !sections.assistant),
        renderLiveAction(exchange, sections, session, isLatest),
      ].join("");
      return `<section class="conversationSequence" data-exchange-id="${esc(exchange.id)}">${body}</section>`;
    }
    function pendingKeyPart(it) {
      // pending(대기열/전송중) 항목은 delivery 라벨·시간기반 실패표기가 갱신돼야 하므로 렌더키에 상태+시간버킷을 싣는다.
      if (!it || !it.pending) return 0;
      return [it.delivery || "", Math.floor((Date.now() - (it.createdAt || 0)) / 4000)];
    }
    function exchangeRenderKey(exchange, session, isLatest) {
      // 이 exchange 하나의 렌더에 영향을 주는 것만: 항목들 + (최신일 때만) 세션 라이브 상태.
      return JSON.stringify([
        isLatest,
        isLatest ? [session.status, session.controllable] : 0,
        (exchange.items || []).map(it => [it.id || "", it.kind, it.role, it.text, it.activityType, it.label, it.status, it.detail, it.result, it.model, it.effort, pendingKeyPart(it)]),
      ]);
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
        if (!node || node.dataset.exchangeKey !== key) {
          const holder = document.createElement("div");
          holder.innerHTML = renderConversationSequence(exchange, session, isLatest);
          const fresh = holder.firstElementChild;
          fresh.dataset.exchangeKey = key;
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
    function renderTurns(session) {
      if (!session) {
        turnsEl.innerHTML = "";
        turnsStructureKey = "";
        newMessagesBtn.style.display = "none";
        historyStatus.style.display = "none";
        return;
      }
      const history = sessionHistory(session);
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
      const present = t => (confirmedUsers.get(normUserText(t.text)) || 0) > 0 || containedIn(normUserText(t.text));   // 트랜스크립트에 조금이라도 있으면 = 소비됨
      const latestConfirmedAt = Math.max(0, ...rawPending.filter(isConfirmed).map(t => Number(t.createdAt || 0)));
      const ghost = t => Boolean(latestConfirmedAt && Number(t.createdAt || 0) < latestConfirmedAt);   // 뒤엣것이 소비됨 → 앞선 건 소비/드롭
      const pending = rawPending.flatMap(t => {
        if (isConfirmed(t)) return [];                       // 정상 소비 → 제거
        if (ghost(t)) {
          if (present(t)) return [];                         // 트랜스크립트에 있음(소비됨, baseline 만 어긋남) → 제거
          return [{...t, failed: true, delivery: "failed"}]; // 진짜 미전달 → 조용히 드롭 금지, 빨갛게 남겨 형이 알게
        }
        return [t];                                          // 아직 정상 대기(working 중 등)
      });
      pendingTurns[selectedSessionKey] = pending;
      const pendingTimeline = pending.map((turn, index) => ({...turn, kind: "message", id: turn.id || `pending:${index}:${turn.text || ""}`}));
      const timeline = history ? serverTimeline.concat(pendingTimeline) : serverTimeline.concat(pendingTimeline).slice(-40);
      if (session && session.kind === "term" && session.preview) {
        timeline.push({kind: "message", role: "output", text: session.preview, id: "terminal-preview"});
      }
      const nextKey = JSON.stringify([session.status, timeline.map(item => [item.id || "", item.kind, item.role, item.text, item.activityType, item.label, item.status, item.detail, item.result, item.model, item.effort, pendingKeyPart(item)])]);
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
      if (!subagents.length) {
        const message = activity && !activity.loaded ? "불러오는 중..." : "이 세션의 작업 에이전트 기록이 없습니다.";
        updateHtmlIfChanged(subagentList, `<div class="empty-state">${message}</div>`);
        return;
      }
      const statusLabel = {running: "실행 중", completed: "완료", failed: "실패", stopped: "중지"};
      const openSubagentIds = new Set([...subagentList.querySelectorAll("details[open]")].map(item => item.getAttribute("data-subagent-id")));
      const previousScrollTop = subagentList.scrollTop;
      const html = subagents.map(agent => {
        const turns = (agent.turns || []).map(turn => `<div class="subagent-turn ${turn.role === "user" ? "user" : "assistant"}">${renderRichText(turn.text || "")}</div>`).join("");
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
      servicesCount.textContent = `${servicesState.running || 0}/${servicesState.defined || 0}`;
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
      const root = selectedRoot();
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
        servicesCount.textContent = "!";
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
          body: JSON.stringify({root: selectedRoot(), service, action}),
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
    function openServices() {
      closeInbox();
      closeSettings();
      servicesSheet.classList.add("open");
      servicesSheet.setAttribute("aria-hidden", "false");
      loadServices(true);
    }
    function sessionStatusText(session) {
      if (!session || session.kind !== "agent") return "";
      const labels = {working: "작업 중", blocked: "응답 필요", waiting: "응답 대기", completed: "완료", failed: "실패", interrupted: "중단됨", idle: "대기"};
      let text = labels[session.status] || session.status || "대기";
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
      showToast(result.applyMode === "live" ? "현재 CLI에 적용했습니다" : "다음 Marina 연결에 적용합니다");
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
      const root = selectedRoot();
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
          if (fileSuggestionKey === key && selectedSessionKey === sessionKey && selectedRoot() === root && sessionSource(selectedSession()) === source) {
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
      renderInbox();
      const session = selectedSession();
      if (session) showChat();
      else showList();
      chatNavTitle.textContent = session ? (session.title || "세션") : "";
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
        const r = await fetch("/mobile/api/state", {headers: headers()});
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
        // 데몬 재시작(새 버전) 감지 → full-reload 를 강제하지 않고 배너만 띄운다(형 탭할 때 리로드).
        // 재방문 폴링마다 location.reload() 를 때리면 스크롤·작업중 상태가 다 풀렸음.
        if (state.serverInstance) {
          if (serverInstance && serverInstance !== state.serverInstance) updateBanner.style.display = "block";
          else if (!serverInstance) serverInstance = state.serverInstance;
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
    const IMAGE_EXT_RE = /\.(png|jpe?g|gif|webp|bmp|heic|svg)$/i;
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
      const root = selectedRoot();
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
    attachBtn.onclick = () => fileInput.click();
    fileInput.onchange = () => { if (fileInput.files && fileInput.files.length) uploadFiles([...fileInput.files]); fileInput.value = ""; };
    attachStrip.onclick = event => {
      const del = event.target.closest("[data-attach-del]");
      if (!del) return;
      pendingAttachments = pendingAttachments.filter(a => a.id !== del.getAttribute("data-attach-del"));
      renderAttachStrip();
    };
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
      const requestContext = {root: selectedRoot(), sessionKey: selectedSessionKey, text, target, draftKey: activeDraftKey};
      const requestIsActive = () => selectedSessionKey === requestContext.sessionKey && selectedRoot() === requestContext.root;
      statusEl.textContent = selectedSession() && selectedSession().controllable ? "지시 추가 중..." : "보내는 중...";
      sending = true;
      sendBtn.disabled = true;
      retryBtn.style.display = "none";
      try {
        const r = await fetch("/mobile/api/send", {method: "POST", headers: headers(true), body: JSON.stringify({root: requestContext.root, target, text: outgoingText})});
        if (!r.ok) throw new Error(await responseError(r));
        const d = await r.json();
        localStorage.removeItem(requestContext.draftKey);
        if (requestIsActive()) {
          pendingAttachments = [];
          renderAttachStrip();
          promptInput.value = "";
          autoGrowComposer();
          closeSuggestions();
          failedSend = null;
          followLatest = true;
          selectReturnedTerm(d.tid, text, target, d.delivery || (target.type === "agent" ? "started" : "sent"));
          statusEl.textContent = target.type === "agent" ? pendingDeliveryLabel(d.delivery || "started") : `보냄 · ${d.tid}`;
          if (target.type === "agent") optimisticWorkUntil = Date.now() + 6000;   // 착수 즉시 작업중 느낌
        }
        setTimeout(() => load({quiet: true}).catch(() => {}), 500);
        setTimeout(() => load({quiet: true}).catch(() => {}), 1500);   // working 상태 빨리 잡기
      } catch (error) {
        failedSend = requestContext;
        if (requestIsActive()) {
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
    promptInput.onkeydown = event => {
      if (event.key === "Escape") {
        closeSuggestions();
        return;
      }
      // 옵션 B: 엔터=줄바꿈(기본). 전송은 ↑ 버튼으로만. 단, 멘션/스킬 제안이 열려 있으면 엔터로 첫 제안 채택.
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing && suggestionsEl.classList.contains("open")) {
        const first = suggestionsEl.querySelector("[data-insert]");
        if (first) { event.preventDefault(); insertSuggestion(first.getAttribute("data-insert") || ""); }
      }
    };
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
      if (selectedSession() && sessionProjectId(selectedSession()) !== selectedProjectId) leaveChat(false);
      renderProjectTabs();
      renderSourceTabs();
      renderSessions();
      loadServices(true);
    };
    sourceTabs.onclick = event => {
      const btn = event.target.closest("[data-source]");
      if (!btn || !sourceTabs.contains(btn)) return;
      sourceFilter = btn.getAttribute("data-source") || "all";
      localStorage.setItem("marinaMobileSource", sourceFilter);
      if (selectedSession() && sourceFilter !== "all" && sessionSource(selectedSession()) !== sourceFilter) leaveChat(false);
      renderSourceTabs();
      renderSessions();
    };
    sessionList.onclick = event => {
      const btn = event.target.closest("[data-key]");
      if (!btn || !sessionList.contains(btn)) return;
      chooseSession(btn.getAttribute("data-key"));
    };
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
    backBtn.onclick = () => leaveChat(true);
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
    sendBtn.onclick = () => send();
    retryBtn.onclick = () => {
      if (!failedSend || failedSend.sessionKey !== selectedSessionKey || failedSend.root !== selectedRoot()) { clearFailedSend(); return; }
      promptInput.value = failedSend.text;
      saveDraft();
      autoGrowComposer();
      send();
    };
    newMessagesBtn.onclick = scrollToLatest;
    turnsEl.addEventListener("toggle", event => {
      const detail = event.target.closest && event.target.closest("details[data-timeline-detail]");
      if (!detail || !turnsEl.contains(detail)) return;
      const key = `${selectedSessionKey}:${detail.getAttribute("data-timeline-detail") || "detail"}`;
      if (detail.open) openTimelineDetailIds.add(key);
      else openTimelineDetailIds.delete(key);
    }, true);
    async function answerQuestion(payload) {
      const session = selectedSession();
      if (!session || session.kind !== "agent") return;
      const value = currentTargetValue();
      if (!value.startsWith("agent:")) return;
      const [, source, sid] = value.split(":");
      statusEl.textContent = "응답 전송 중...";
      try {
        const body = {root: selectedRoot(), target: {type: "agent", source, sid}};
        if (payload && payload.text != null) body.text = payload.text;
        else body.optionIndex = (payload && payload.optionIndex) || 0;
        const r = await fetch("/mobile/api/answer", {method: "POST", headers: headers(true), body: JSON.stringify(body)});
        if (!r.ok) throw new Error(await responseError(r));
        followLatest = true;
        setTimeout(() => load({quiet: true}).catch(() => {}), 400);
      } catch (error) {
        statusEl.textContent = `응답 실패 · ${String(error)}`;
        showToast(`응답 실패 · ${String(error)}`);
      }
    }
    turnsEl.addEventListener("click", event => {
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
        if (!Number.isNaN(index)) { answer.disabled = true; answerQuestion({optionIndex: index}); }
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
    servicesBtn.onclick = openServices;
    document.getElementById("servicesCloseBtn").onclick = closeServices;
    servicesSheet.onclick = event => { if (event.target === servicesSheet) closeServices(); };
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
    sessionSearch.oninput = renderSessions;
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
    setInterval(quietPoll, autoPollMs);
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
