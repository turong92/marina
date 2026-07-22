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
import urllib.parse
from pathlib import Path
from typing import Any

from marina_registry import discover_all_roots
from marina_sessions import activate_agent_payloads, agent_runtime_settings, agents_payload, safe_root, worktree_info
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


def mobile_update_session_settings(body: dict[str, Any]) -> dict[str, str]:
    root = safe_root(str(body.get("root") or ""))
    source = str(body.get("source") or "")
    sid = str(body.get("sid") or "")
    value = {"model": str(body.get("model") or ""), "effort": str(body.get("effort") or "")}
    _agent_cli(source, sid, model=value["model"], effort=value["effort"])
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
    return value


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
    return {
        "codex": {"models": codex_models, "efforts": ["low", "medium", "high", "xhigh", "max", "ultra"], "manualModel": True},
        "claude": {"models": [], "efforts": ["low", "medium", "high", "xhigh", "max"], "manualModel": True},
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
                    "status": agent.get("status") or "idle",
                    "statusTs": agent.get("statusTs") or agent.get("ts") or 0,
                    "statusReason": agent.get("statusReason") or "",
                    "tid": str((agent_terms.get((source, sid)) or {}).get("tid") or ""),
                    "controllable": bool((agent_terms.get((source, sid)) or {}).get("tid")),
                    "settings": {
                        "current": agent_runtime_settings(root, source, sid),
                        "pending": mobile_pending_session_settings(root, source, sid),
                    },
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
    return {"worktrees": worktrees, "terms": terms, "sessions": sessions, "agentOptions": mobile_agent_options()}


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
                term_input(tid, _input_payload(text))
                return {"ok": True, "tid": tid, "opened": False, "steered": True}
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
    header { z-index: 4; display: grid; gap: 4px; padding: 4px 8px 6px; box-sizing: border-box; background: #fff; border-bottom: 1px solid #dde2ea; }
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
    #chatView { position: relative; display: none; min-height: 0; grid-template-rows: auto auto minmax(0, 1fr); gap: 8px; overflow: hidden; }
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
    .chat-title { font-size: 18px; font-weight: 900; line-height: 1.25; overflow-wrap: anywhere; }
    .chat-subtitle { color: #596070; font-size: 12px; line-height: 1.35; overflow-wrap: anywhere; }
    .turns { display: flex; min-height: 0; flex-direction: column; justify-content: flex-start; gap: 9px; overflow-y: auto; overscroll-behavior: contain; padding: 2px 1px 8px; }
    .olderMessagesBtn { display: none; align-self: center; width: auto; min-height: 32px; padding: 0 11px; border-color: #b9c6d8; color: #596070; font-size: 11px; }
    .turn { align-self: flex-start; max-width: 88%; padding: 9px 11px; border-radius: 8px; background: #eef2f7; font-size: 13px; line-height: 1.5; overflow-wrap: anywhere; }
    .turn.user { align-self: flex-end; background: #dcecff; }
    .turn.output { width: 100%; max-width: none; background: #111827; color: #e5e7eb; font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; }
    .turn a, .subagent-turn a { color: #0969da; text-decoration: underline; text-underline-offset: 2px; }
    .turn code, .subagent-turn code { padding: 1px 4px; border-radius: 4px; background: rgba(127, 127, 127, .14); font: .92em/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; }
    .turnToggle { display: block; margin: 6px 0 0; padding: 2px 0; border: 0; background: transparent; color: #526176; font-size: 11px; }
    .newMessagesBtn { position: absolute; left: 50%; bottom: 8px; z-index: 3; display: none; width: auto; min-height: 34px; padding: 0 12px; transform: translateX(-50%); border-color: #b9c6d8; background: #fff; box-shadow: 0 4px 14px rgb(23 25 31 / 14%); font-size: 12px; }
    .chatComposer { z-index: 3; display: flex; min-width: 0; flex-direction: column; gap: 6px; padding: 7px 10px max(8px, env(safe-area-inset-bottom)); background: #fff; border-top: 1px solid #dde2ea; box-sizing: border-box; }
    .composerRow { display: grid; grid-template-columns: minmax(0, 1fr) 44px; gap: 7px; align-items: end; }
    .chatComposer textarea { min-height: 44px; max-height: 132px; padding: 10px 11px; resize: none; overflow-y: auto; }
    .sendBtn { width: 44px; height: 44px; min-height: 44px; padding: 0; font-size: 20px; }
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
      .session-card { border-color: #303846; }
      .session-subtitle, .chat-subtitle { color: #a5adba; }
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
      .olderMessagesBtn { border-color: #3b4658; color: #a5adba; }
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
        <button class="servicesBtn" id="servicesBtn" type="button" aria-label="서비스 상태">서버 <span id="servicesCount">-/-</span></button>
      </div>
      <div class="source-tabs" id="sourceTabs" aria-label="세션 종류"></div>
    </header>
    <main>
      <section id="listView">
        <input class="search-input" id="sessionSearch" aria-label="세션 검색" placeholder="세션 검색" />
        <div class="session-list" id="sessionList"></div>
      </section>
      <section id="chatView">
        <div>
          <div class="chat-title" id="chatTitle">세션을 선택하세요</div>
          <div class="chat-subtitle" id="chatSubtitle"></div>
        </div>
        <label class="hiddenSelect">워크트리<select id="rootSelect"></select></label>
        <label class="hiddenSelect">대상<select id="targetSelect"></select></label>
        <button class="olderMessagesBtn" id="olderMessagesBtn" type="button">이전 메시지</button>
        <div class="turns" id="turns"></div>
        <button class="newMessagesBtn" id="newMessagesBtn" type="button">새 메시지</button>
      </section>
    </main>
    <div class="chatComposer" id="chatComposer" style="display:none">
      <div class="sessionControls">
        <button class="sessionControlBtn" id="settingsBtn" type="button">모델 · 기본값</button>
        <button class="sessionControlBtn" id="subagentSessionBtn" type="button" style="display:none">서브에이전트 <span id="subagentCount">0</span></button>
        <div class="status" id="status" aria-live="polite"></div>
        <button class="stopBtn" id="stopBtn" type="button" title="현재 응답 중단" aria-label="현재 응답 중단">&#9632;</button>
      </div>
      <div class="suggestions" id="suggestions" role="listbox"></div>
      <div class="composerRow">
        <textarea id="prompt" rows="1" placeholder="메시지" enterkeyhint="send"></textarea>
        <button class="primary sendBtn" id="sendBtn" type="button" title="보내기" aria-label="보내기">&#8593;</button>
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
    const catalogEndpoint = "/mobile/api/catalog";
    const login = document.getElementById("mobileLogin");
    const app = document.getElementById("mobileApp");
    const loginStatus = document.getElementById("loginStatus");
    const listView = document.getElementById("listView");
    const chatView = document.getElementById("chatView");
    const chatComposer = document.getElementById("chatComposer");
    const backBtn = document.getElementById("backBtn");
    const chatTitle = document.getElementById("chatTitle");
    const chatSubtitle = document.getElementById("chatSubtitle");
    const rootSelect = document.getElementById("rootSelect");
    const targetSelect = document.getElementById("targetSelect");
    const promptInput = document.getElementById("prompt");
    const sessionSearch = document.getElementById("sessionSearch");
    const sessionList = document.getElementById("sessionList");
    const projectTabs = document.getElementById("projectTabs");
    const sourceTabs = document.getElementById("sourceTabs");
    const turnsEl = document.getElementById("turns");
    const olderMessagesBtn = document.getElementById("olderMessagesBtn");
    const suggestionsEl = document.getElementById("suggestions");
    const newMessagesBtn = document.getElementById("newMessagesBtn");
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
    let servicesState = {root: "", running: 0, defined: 0, services: []};
    const autoPollMs = 3000;
    let loading = false;
    let sending = false;
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
    const expandedTurnIds = new Set();
    const collapsedTurnIds = new Set();
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
      listView.style.display = "flex";
      chatView.style.display = "none";
      chatComposer.style.display = "none";
      backBtn.style.display = "none";
      closeSubagents();
      closeInbox();
    }
    function showChat() {
      listView.style.display = "none";
      chatView.style.display = "grid";
      chatComposer.style.display = "flex";
      backBtn.style.display = "inline-block";
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
    function nearPageBottom() {
      return turnsEl.scrollTop + turnsEl.clientHeight >= turnsEl.scrollHeight - 120;
    }
    function scrollToLatest(behavior="auto") {
      turnsEl.scrollTo({top: turnsEl.scrollHeight, behavior});
      newMessagesBtn.style.display = "none";
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
      selectedSessionKey = key;
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
    function queuePendingTurn(key, text) {
      const session = (state.sessions || []).find(item => item.key === key);
      const cached = sessionHistory(session);
      const confirmedCount = ((cached && cached.turns) || (session && session.turns) || []).filter(turn => turn.role === "user" && String(turn.text || "") === text).length;
      const existing = pendingTurns[key] || [];
      const pendingCount = existing.filter(turn => String(turn.text || "") === text).length;
      pendingTurns[key] = existing.concat([{role: "user", text, baseline: confirmedCount + pendingCount}]).slice(-12);
    }
    function selectAgentAfterSend(text, target) {
      const root = selectedRoot();
      const current = selectedSession();
      const key = current && sameTarget(current.target, target) ? selectedSessionKey : agentSessionKey(target, root);
      selectedSessionKey = key;
      localStorage.setItem("marinaMobileSession", key);
      queuePendingTurn(key, text);
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
    function selectReturnedTerm(tid, text, target=null) {
      if (target && target.type === "agent") {
        selectAgentAfterSend(text, target);
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
    function sessionCard(session) {
      const source = sessionSource(session);
      const meta = sourceMeta[source];
      return `<button class="session-card ${session.key === selectedSessionKey ? "active" : ""}" type="button" data-key="${esc(session.key)}">
        <span class="session-card-top"><span class="source-badge ${source}">${meta.badge}</span><span class="session-title" data-session-title>${esc(session.title || session.key)}</span></span>
        <span class="session-subtitle" data-session-subtitle>${esc(session.subtitle || session.root || "")}</span>
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
        card.querySelector("[data-session-subtitle]").textContent = session.subtitle || session.root || "";
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
    function sessionHistory(session) {
      if (!session || session.kind !== "agent") return null;
      let history = historyCache[session.key];
      if (!history) {
        history = historyCache[session.key] = {
          turns: (session.turns || []).slice(), cursor: session.historyCursor ?? null,
          hasMore: Boolean(session.hasMoreHistory), loaded: Boolean(session.historyLoaded),
          loading: false, paged: false,
        };
      } else {
        history.turns = mergeHistoryTurns(history.turns, session.turns || []);
      }
      return history;
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
        history.turns = mergeHistoryTurns(history.turns, page.turns || []);
        if (!history.paged) {
          history.cursor = page.cursor ?? null;
          history.hasMore = Boolean(page.hasMore);
        }
        history.loaded = true;
        if (selectedSessionKey === session.key) {
          turnsStructureKey = "";
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
      olderMessagesBtn.disabled = true;
      olderMessagesBtn.textContent = "불러오는 중";
      const oldHeight = turnsEl.scrollHeight;
      const oldY = turnsEl.scrollTop;
      try {
        const params = new URLSearchParams({root: session.root, source: session.source, sid: session.sid, before: String(history.cursor)});
        const response = await fetch(`/mobile/api/transcript?${params}`, {headers: headers()});
        if (!response.ok) throw new Error(await response.text());
        const page = await response.json();
        history.turns = mergeHistoryTurns(history.turns, page.turns || []);
        history.cursor = page.cursor ?? null;
        history.hasMore = Boolean(page.hasMore);
        history.paged = true;
        turnsStructureKey = "";
        renderTurns(session);
        requestAnimationFrame(() => { turnsEl.scrollTop = oldY + turnsEl.scrollHeight - oldHeight; });
      } catch (error) {
        statusEl.textContent = `이전 메시지 실패 · ${String(error)}`;
      } finally {
        historyLoading = false;
        olderMessagesBtn.disabled = false;
        olderMessagesBtn.textContent = "이전 메시지";
      }
    }
    function renderTurns(session) {
      if (!session) {
        turnsEl.innerHTML = "";
        turnsStructureKey = "";
        newMessagesBtn.style.display = "none";
        olderMessagesBtn.style.display = "none";
        return;
      }
      const history = sessionHistory(session);
      const serverTurns = history ? history.turns : ((session && session.turns) || []);
      olderMessagesBtn.style.display = history && history.hasMore ? "block" : "none";
      const confirmedUsers = new Map();
      serverTurns.filter(t => t.role === "user").forEach(t => {
        const text = String(t.text || "");
        confirmedUsers.set(text, (confirmedUsers.get(text) || 0) + 1);
      });
      const pending = (pendingTurns[selectedSessionKey] || []).filter(t => (confirmedUsers.get(String(t.text || "")) || 0) <= Number(t.baseline || 0));
      pendingTurns[selectedSessionKey] = pending;
      const turns = history ? serverTurns.concat(pending) : serverTurns.concat(pending).slice(-40);
      if (session && session.kind === "term" && session.preview) {
        turns.push({role: "output", text: session.preview});
      }
      const nextKey = JSON.stringify(turns.map(t => [t.id || "", t.role, t.text]));
      if (nextKey === turnsStructureKey) return;
      const wasNearBottom = nearPageBottom();
      const hadTurns = Boolean(turnsStructureKey);
      turnsEl.innerHTML = turns.map((t, index) => {
        const text = String(t.text || "");
        const id = `${selectedSessionKey}:${t.id || index}:${t.role || "assistant"}`;
        const long = text.length > 420 || text.split("\n").length > 8;
        const recent = index >= turns.length - 2;
        const expanded = !long || expandedTurnIds.has(id) || (recent && !collapsedTurnIds.has(id));
        const body = expanded ? renderRichText(text) : `${renderRichText(text.slice(0, 280).trimEnd())}&hellip;`;
        const toggle = long ? `<button class="turnToggle" type="button" data-turn-toggle="${esc(id)}" data-expanded="${expanded ? "1" : "0"}">${expanded ? "접기" : "펼치기"}</button>` : "";
        const role = t.role === "user" ? "user" : t.role === "output" ? "output" : "assistant";
        return `<div class="turn ${role}"><div class="turnBody">${body}</div>${toggle}</div>`;
      }).join("");
      turnsStructureKey = nextKey;
      requestAnimationFrame(() => {
        if (!hadTurns || wasNearBottom) scrollToLatest();
        else newMessagesBtn.style.display = "block";
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
      return text;
    }
    function renderSessionControls(session) {
      const isAgent = Boolean(session && session.kind === "agent");
      settingsBtn.style.display = isAgent ? "inline-block" : "none";
      if (isAgent) {
        const current = (session.settings && session.settings.current) || {model: "", effort: ""};
        const pending = (session.settings && session.settings.pending) || {model: "", effort: ""};
        const currentLabel = `${current.model || "기본 모델"}${current.effort ? ` · ${current.effort}` : ""}`;
        const pendingLabel = pending.model || pending.effort ? ` → 다음 ${pending.model || "기본 모델"}${pending.effort ? ` · ${pending.effort}` : ""}` : "";
        settingsBtn.textContent = `${sourceMeta[sessionSource(session)].label} · ${currentLabel}${pendingLabel}`;
      }
      const running = isAgent && session.status === "working" && session.controllable;
      stopBtn.style.display = running ? "inline-block" : "none";
      if (!sending) statusEl.textContent = sessionStatusText(session);
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
      session.settings.pending = {model: result.model || "", effort: result.effort || ""};
      closeSettings();
      renderSessionControls(session);
      showToast("다음 resume 1회에 적용됩니다");
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
        showToast(`중단 실패 · ${String(error)}`);
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
      chatTitle.textContent = session ? (session.title || "세션") : "세션을 선택하세요";
      chatSubtitle.textContent = session ? (session.subtitle || session.root || "") : "";
      restoreDraft();
      renderTurns(session);
      renderSubagents(session);
      renderSessionControls(session);
      const source = sessionSource(session);
      promptInput.placeholder = source === "claude" ? "Claude에 메시지" : source === "codex" ? "Codex에 메시지" : "터미널에 입력";
      if (document.activeElement === promptInput) renderSuggestions();
      loadServices(false);
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
        showApp();
        render();
        await loadSessionMessages(selectedSession(), {refresh: Boolean(options.quiet)});
        if (!options.quiet && !selectedSession()) statusEl.textContent = "준비됨";
      } finally {
        loading = false;
      }
    }
    async function send() {
      const text = promptInput.value;
      if (sending) return;
      if (!text.trim()) {
        statusEl.textContent = "메시지를 입력하세요.";
        return;
      }
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
        const r = await fetch("/mobile/api/send", {method: "POST", headers: headers(true), body: JSON.stringify({root: requestContext.root, target, text})});
        if (!r.ok) throw new Error(await r.text());
        const d = await r.json();
        localStorage.removeItem(requestContext.draftKey);
        if (requestIsActive()) {
          promptInput.value = "";
          autoGrowComposer();
          closeSuggestions();
          failedSend = null;
          selectReturnedTerm(d.tid, text, target);
          statusEl.textContent = `보냄 · ${d.tid}`;
        }
        setTimeout(() => load({quiet: true}).catch(e => statusEl.textContent = String(e)), 500);
      } catch (error) {
        failedSend = requestContext;
        if (requestIsActive()) {
          statusEl.textContent = `전송 실패 · ${String(error)}`;
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
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
        event.preventDefault();
        send();
      }
    };
    promptInput.onfocus = () => {
      syncVisualViewport();
      requestAnimationFrame(() => scrollToLatest("auto"));
      setTimeout(() => scrollToLatest("auto"), 180);
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
    olderMessagesBtn.onclick = loadOlderMessages;
    turnsEl.onclick = event => {
      const toggle = event.target.closest("[data-turn-toggle]");
      if (!toggle) return;
      const id = toggle.getAttribute("data-turn-toggle") || "";
      if (toggle.getAttribute("data-expanded") === "1") {
        expandedTurnIds.delete(id);
        collapsedTurnIds.add(id);
      } else {
        collapsedTurnIds.delete(id);
        expandedTurnIds.add(id);
      }
      turnsStructureKey = "";
      renderTurns(selectedSession());
    };
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
      if (turnsEl.scrollTop < 72 && olderMessagesBtn.style.display !== "none") loadOlderMessages();
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
    setInterval(() => {
      if (document.visibilityState !== "hidden") load({quiet: true}).catch(e => statusEl.textContent = String(e));
    }, autoPollMs);
    load().then(() => {
      if (selectedSessionKey && (!history.state || history.state.view !== "chat")) history.pushState({view: "chat"}, "", location.href);
    }).catch(e => { statusEl.textContent = `실패 · ${String(e)}`; });
  </script>
</body>
</html>
"""
