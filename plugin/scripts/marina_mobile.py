"""Mobile control surface: token-protected, minimal phone UI for sending prompts."""
from __future__ import annotations

import hmac
import json
import os
import re
import secrets
import subprocess
import urllib.parse
from pathlib import Path
from typing import Any

from marina_registry import discover_all_roots
from marina_sessions import activate_agent_payloads, agent_activity, agent_transcript, agents_payload, safe_root, worktree_info
from marina_state import MARINA_HOME, PORT
from marina_term import term_input, term_list, term_open


TOKEN_FILE = MARINA_HOME / "mobile-token"
CLAUDE_HOME = Path(os.environ.get("CLAUDE_HOME", str(Path.home() / ".claude")))
CODEX_USER_HOME = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
AGENTS_HOME = Path(os.environ.get("AGENTS_HOME", str(Path.home() / ".agents")))


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return value if isinstance(value, dict) else {}


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


def _agent_history(root: Path, source: str, sid: str) -> dict[str, Any]:
    if not sid:
        return {"turns": [], "cursor": None, "hasMore": False}
    try:
        payload = agent_transcript(root, source, sid)
        turns = payload.get("turns", [])
        return {
            "turns": turns if isinstance(turns, list) else [],
            "cursor": payload.get("cursor"),
            "hasMore": bool(payload.get("hasMore")),
        }
    except Exception:
        return {"turns": [], "cursor": None, "hasMore": False}


def _agent_turns(root: Path, source: str, sid: str) -> list[dict[str, str]]:
    return _agent_history(root, source, sid)["turns"]


def _agent_subagents(root: Path, source: str, sid: str) -> list[dict[str, Any]]:
    if not sid:
        return []
    try:
        return agent_activity(root, source, sid)
    except Exception:
        return []


def mobile_state(refresh: bool = False) -> dict[str, Any]:
    worktrees: list[dict[str, Any]] = []
    sessions: list[dict[str, Any]] = []
    catalogs: dict[tuple[str, str], dict[str, list[dict[str, str]]]] = {}
    terms = term_list().get("sessions", [])
    for root in discover_all_roots(refresh):
        try:
            info = worktree_info(root, refresh)
            root_terms = [t for t in terms if str(t.get("root") or "") == str(root)]
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
                history = _agent_history(root, source, sid)
                turns = history["turns"]
                catalog_key = (str(root), source)
                if catalog_key not in catalogs:
                    try:
                        catalogs[catalog_key] = _native_catalog(root, source)
                    except Exception:
                        catalogs[catalog_key] = {"skills": [], "agents": []}
                preview = str(agent.get("preview") or "")
                if not preview and turns:
                    preview = str(turns[-1].get("text") or "")
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
                    "turns": turns,
                    "historyCursor": history["cursor"],
                    "hasMoreHistory": history["hasMore"],
                    "subagents": _agent_subagents(root, source, sid),
                    "catalog": catalogs[catalog_key],
                    "ts": agent.get("ts") or 0,
                    "status": agent.get("status") or "idle",
                    "statusTs": agent.get("statusTs") or agent.get("ts") or 0,
                    "statusReason": agent.get("statusReason") or "",
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
    return {"worktrees": worktrees, "terms": terms, "sessions": sessions}


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
        result = term_open(
            root,
            int(body.get("cols") or 80),
            int(body.get("rows") or 24),
            agent_source=str(target.get("source") or ""),
            agent_sid=str(target.get("sid") or ""),
            agent_prompt=text,
        )
        tid = str(result["tid"])
        opened = not bool(result.get("reused"))
        prompt_submitted = True
    else:
        result = term_open(root, int(body.get("cols") or 80), int(body.get("rows") or 24))
        tid = str(result["tid"])
        opened = True
    if not prompt_submitted:
        term_input(tid, _input_payload(text))
    return {"ok": True, "tid": tid, "opened": opened}


def render_mobile_html() -> str:
    return _MOBILE_HTML


_MOBILE_HTML = r"""<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Marina Mobile</title>
  <style>
    :root { color-scheme: light dark; font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; background: #f4f6f9; color: #17191f; }
    #mobileApp { min-height: 100vh; display: none; flex-direction: column; }
    #mobileLogin { min-height: 100vh; display: none; align-items: stretch; justify-content: center; flex-direction: column; padding: 24px; box-sizing: border-box; gap: 14px; }
    #mobileLogin form { display: flex; flex-direction: column; gap: 10px; }
    header { position: sticky; top: 0; z-index: 4; display: grid; grid-template-columns: 40px minmax(0, 1fr) 40px; align-items: center; min-height: 48px; padding: 3px 8px; box-sizing: border-box; background: #fff; border-bottom: 1px solid #dde2ea; }
    h1 { grid-column: 2; margin: 0; font-size: 15px; line-height: 1.2; text-align: center; }
    h2 { margin: 0; font-size: 22px; }
    p { margin: 0; color: #596070; line-height: 1.45; }
    main { display: flex; flex-direction: column; gap: 10px; padding: 10px 12px 16px; }
    label { display: flex; flex-direction: column; gap: 6px; font-size: 12px; font-weight: 700; color: #596070; }
    select, textarea, input, button { width: 100%; box-sizing: border-box; border: 1px solid #ccd3dd; border-radius: 8px; background: #fff; color: #17191f; font: inherit; }
    input { min-height: 42px; padding: 0 11px; }
    select, button { min-height: 42px; padding: 0 11px; }
    textarea { min-height: 92px; padding: 11px; resize: vertical; line-height: 1.45; }
    button { font-weight: 800; color: #0b63ce; }
    button.primary { background: #0b63ce; border-color: #0b63ce; color: white; }
    button:focus-visible, input:focus-visible, textarea:focus-visible { outline: 2px solid #0b63ce; outline-offset: 2px; }
    .iconBtn { width: 40px; height: 40px; min-height: 40px; padding: 0; border-color: transparent; background: transparent; color: #303846; font-size: 20px; line-height: 1; }
    .backBtn { grid-column: 1; }
    .menuWrap { grid-column: 3; position: relative; width: 40px; height: 40px; }
    .menuPanel { position: absolute; top: 43px; right: 0; display: none; width: 180px; padding: 5px; background: #fff; border: 1px solid #d8dee7; border-radius: 8px; box-shadow: 0 8px 24px rgb(23 25 31 / 14%); }
    .menuPanel.open { display: flex; flex-direction: column; gap: 2px; }
    .menuPanel button { min-height: 38px; padding: 0 10px; border: 0; text-align: left; color: #303846; }
    .menuPanel button span { float: right; min-width: 18px; color: #747d8b; font-variant-numeric: tabular-nums; text-align: right; }
    #listView, #chatView { display: flex; flex-direction: column; gap: 10px; }
    #chatView { display: none; min-height: calc(100dvh - 74px); padding-bottom: 104px; box-sizing: border-box; }
    .hiddenSelect { display: none !important; }
    .project-strip { display: flex; gap: 6px; margin: 0 -12px; padding: 0 12px 2px; overflow-x: auto; scrollbar-width: none; }
    .project-strip::-webkit-scrollbar { display: none; }
    .project-chip { flex: 0 0 auto; width: auto; max-width: 220px; min-height: 34px; padding: 0 11px; border-radius: 17px; color: #596070; font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .project-chip.active { background: #17191f; border-color: #17191f; color: #fff; }
    .project-count { margin-left: 5px; opacity: .7; font-variant-numeric: tabular-nums; }
    .source-tabs { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 4px; padding: 3px; background: #e8ecf2; border-radius: 8px; }
    .source-tab { min-width: 0; min-height: 34px; padding: 0 4px; border: 0; background: transparent; color: #596070; font-size: 11px; }
    .source-tab.active { background: #fff; color: #17191f; box-shadow: 0 1px 3px rgb(23 25 31 / 10%); }
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
    .turns { display: flex; flex: 1; flex-direction: column; justify-content: flex-end; gap: 9px; padding-top: 2px; }
    .olderMessagesBtn { display: none; align-self: center; width: auto; min-height: 32px; padding: 0 11px; border-color: #b9c6d8; color: #596070; font-size: 11px; }
    .turn { align-self: flex-start; max-width: 88%; padding: 9px 11px; border-radius: 8px; background: #eef2f7; font-size: 13px; line-height: 1.5; overflow-wrap: anywhere; }
    .turn.user { align-self: flex-end; background: #dcecff; }
    .turn.output { width: 100%; max-width: none; background: #111827; color: #e5e7eb; font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; }
    .turn a, .subagent-turn a { color: #0969da; text-decoration: underline; text-underline-offset: 2px; }
    .newMessagesBtn { position: fixed; left: 50%; bottom: 112px; z-index: 3; display: none; width: auto; min-height: 34px; padding: 0 12px; transform: translateX(-50%); border-color: #b9c6d8; background: #fff; box-shadow: 0 4px 14px rgb(23 25 31 / 14%); font-size: 12px; }
    .chatComposer { position: fixed; left: 0; right: 0; bottom: 0; z-index: 3; display: flex; flex-direction: column; gap: 6px; padding: 8px 12px max(10px, env(safe-area-inset-bottom)); background: #fff; border-top: 1px solid #dde2ea; box-sizing: border-box; }
    .composerRow { display: grid; grid-template-columns: minmax(0, 1fr) 44px; gap: 7px; align-items: end; }
    .chatComposer textarea { min-height: 44px; max-height: 132px; padding: 10px 11px; resize: none; overflow-y: auto; }
    .sendBtn { width: 44px; height: 44px; min-height: 44px; padding: 0; font-size: 20px; }
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
    @media (prefers-color-scheme: dark) {
      body { background: #11151c; color: #f4f6f9; }
      header, select, textarea, input, button { background: #171d27; color: #f4f6f9; border-color: #303846; }
      label, p, .status { color: #a5adba; }
      .chatComposer { background: #171d27; border-color: #303846; }
      .session-card { border-color: #303846; }
      .session-subtitle, .chat-subtitle { color: #a5adba; }
      .session-preview { color: #d6dbe4; }
      .iconBtn, .menuPanel button { color: #d6dbe4; }
      .menuPanel { background: #171d27; border-color: #303846; box-shadow: 0 8px 24px rgb(0 0 0 / 35%); }
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
      .newMessagesBtn, .suggestions, .bottomSheet, .inboxGroup { background: #171d27; border-color: #303846; }
      .suggestion + .suggestion, .sheetHeader, .subagentItem, .inboxItem { border-color: #303846; }
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
      <button class="iconBtn backBtn" id="backBtn" type="button" title="세션 목록" aria-label="세션 목록으로" style="display:none">&#8592;</button>
      <h1>Marina</h1>
      <div class="menuWrap">
        <button class="iconBtn" id="menuBtn" type="button" title="메뉴" aria-label="메뉴" aria-expanded="false">&#9776;</button>
        <div class="menuPanel" id="menuPanel">
          <button id="inboxMenuBtn" type="button">받은 작업 <span id="inboxCount">0</span></button>
          <button id="subagentMenuBtn" type="button" style="display:none">작업 에이전트 <span id="subagentCount">0</span></button>
          <button id="refreshBtn" type="button">새로고침</button>
          <button id="notifyBtn" type="button">알림</button>
          <button id="logoutBtn" type="button">로그아웃</button>
        </div>
      </div>
    </header>
    <main>
      <section id="listView">
        <div class="project-strip" id="projectTabs" aria-label="프로젝트"></div>
        <div class="source-tabs" id="sourceTabs" aria-label="세션 종류"></div>
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
      <div class="suggestions" id="suggestions" role="listbox"></div>
      <div class="composerRow">
        <textarea id="prompt" rows="1" placeholder="메시지" enterkeyhint="send"></textarea>
        <button class="primary sendBtn" id="sendBtn" type="button" title="보내기" aria-label="보내기">&#8593;</button>
      </div>
      <div class="composerMeta"><div class="status" id="status" aria-live="polite"></div><button class="retryBtn" id="retryBtn" type="button">다시 보내기</button></div>
    </div>
    <div class="sheetBackdrop" id="subagentSheet" aria-hidden="true">
      <section class="bottomSheet" role="dialog" aria-modal="true" aria-labelledby="subagentSheetTitle">
        <div class="sheetHeader"><strong id="subagentSheetTitle">작업 에이전트</strong><button class="iconBtn sheetClose" id="subagentCloseBtn" type="button" title="닫기" aria-label="닫기">&#215;</button></div>
        <div class="subagentList" id="subagentList"></div>
      </section>
    </div>
    <div class="sheetBackdrop" id="inboxSheet" aria-hidden="true">
      <section class="bottomSheet" role="dialog" aria-modal="true" aria-labelledby="inboxSheetTitle">
        <div class="sheetHeader"><strong id="inboxSheetTitle">받은 작업</strong><button class="iconBtn sheetClose" id="inboxCloseBtn" type="button" title="닫기" aria-label="닫기">&#215;</button></div>
        <div class="inboxList" id="inboxList"></div>
      </section>
    </div>
  </div>
  <script>
    const urlToken = new URL(location.href).searchParams.get("token");
    if (urlToken) {
      localStorage.setItem("marinaMobileToken", urlToken);
      history.replaceState(null, "", location.pathname);
    }
    const token = () => localStorage.getItem("marinaMobileToken") || "";
    const headers = (json=false) => ({ ...(json ? {"content-type":"application/json"} : {}), "x-marina-mobile-token": token() });
    const catalogEndpoint = "/mobile/api/catalog";
    const login = document.getElementById("mobileLogin");
    const app = document.getElementById("mobileApp");
    const loginStatus = document.getElementById("loginStatus");
    const listView = document.getElementById("listView");
    const chatView = document.getElementById("chatView");
    const chatComposer = document.getElementById("chatComposer");
    const backBtn = document.getElementById("backBtn");
    const menuBtn = document.getElementById("menuBtn");
    const menuPanel = document.getElementById("menuPanel");
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
    const subagentMenuBtn = document.getElementById("subagentMenuBtn");
    const subagentCount = document.getElementById("subagentCount");
    const subagentSheet = document.getElementById("subagentSheet");
    const subagentList = document.getElementById("subagentList");
    const inboxMenuBtn = document.getElementById("inboxMenuBtn");
    const inboxCount = document.getElementById("inboxCount");
    const inboxSheet = document.getElementById("inboxSheet");
    const inboxList = document.getElementById("inboxList");
    const statusEl = document.getElementById("status");
    let state = {worktrees: [], terms: []};
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
    const inboxReadKey = "marinaAgentInboxRead";
    let inboxRead;
    try {
      const value = JSON.parse(localStorage.getItem(inboxReadKey) || "[]");
      inboxRead = new Set(Array.isArray(value) ? value : []);
    } catch (_) { inboxRead = new Set(); }
    const pendingTurns = {};
    const historyCache = {};
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
      app.style.display = "flex";
    }
    function showList() {
      listView.style.display = "flex";
      chatView.style.display = "none";
      chatComposer.style.display = "none";
      backBtn.style.display = "none";
      closeMenu();
      closeSubagents();
      closeInbox();
    }
    function showChat() {
      listView.style.display = "none";
      chatView.style.display = "flex";
      chatComposer.style.display = "flex";
      backBtn.style.display = "inline-block";
    }
    function closeMenu() {
      menuPanel.classList.remove("open");
      menuBtn.setAttribute("aria-expanded", "false");
    }
    function closeSubagents() {
      subagentSheet.classList.remove("open");
      subagentSheet.setAttribute("aria-hidden", "true");
    }
    function closeInbox() {
      inboxSheet.classList.remove("open");
      inboxSheet.setAttribute("aria-hidden", "true");
    }
    function logout() {
      localStorage.removeItem("marinaMobileToken");
      localStorage.removeItem("marinaMobileDraft");
      Object.keys(localStorage).filter(key => key.startsWith("marinaMobileDraft:")).forEach(key => localStorage.removeItem(key));
      state = {worktrees: [], terms: []};
      rootSelect.innerHTML = "";
      targetSelect.innerHTML = "";
      promptInput.value = "";
      sessionList.innerHTML = "";
      sessionStructureKey = "";
      turnsStructureKey = "";
      turnsEl.innerHTML = "";
      Object.keys(historyCache).forEach(key => delete historyCache[key]);
      showList();
      showLogin("로그아웃했습니다.");
    }
    function esc(value) {
      return String(value ?? "").replace(/[&<>"']/g, ch => ({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[ch]));
    }
    function renderRichText(value) {
      const text = String(value ?? "");
      const pattern = /\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)|(https?:\/\/[^\s<>]+)/g;
      let html = "";
      let cursor = 0;
      for (const match of text.matchAll(pattern)) {
        html += esc(text.slice(cursor, match.index));
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
        html += `<a href="${esc(url)}" target="_blank" rel="noopener noreferrer">${esc(label.slice(0, label.length - suffix.length))}</a>${esc(suffix)}`;
        cursor = match.index + match[0].length;
      }
      html += esc(text.slice(cursor));
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
      return window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 120;
    }
    function scrollToLatest() {
      window.scrollTo({top: document.documentElement.scrollHeight, behavior: "smooth"});
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
    function notifyChange(text) {
      if (!text || text === "(터미널 없음)") return;
      if ("vibrate" in navigator) navigator.vibrate(40);
      if ("Notification" in window && Notification.permission === "granted") {
        new Notification("Marina", { body: text.slice(-140) });
      }
    }
    async function enableNotify() {
      if (!("Notification" in window)) {
        statusEl.textContent = "브라우저 알림 미지원";
        return;
      }
      const permission = Notification.permission === "default" ? await Notification.requestPermission() : Notification.permission;
      statusEl.textContent = permission === "granted" ? "알림 켜짐" : "알림 꺼짐";
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
      closeMenu();
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
      render();
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
      const confirmedCount = ((session && session.turns) || []).filter(turn => turn.role === "user" && String(turn.text || "") === text).length;
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
          hasMore: Boolean(session.hasMoreHistory),
        };
      } else {
        history.turns = mergeHistoryTurns(history.turns, session.turns || []);
      }
      return history;
    }
    async function loadOlderMessages() {
      const session = selectedSession();
      const history = sessionHistory(session);
      if (!session || !history || !history.hasMore || historyLoading || history.cursor == null) return;
      historyLoading = true;
      olderMessagesBtn.disabled = true;
      olderMessagesBtn.textContent = "불러오는 중";
      const oldHeight = document.documentElement.scrollHeight;
      const oldY = window.scrollY;
      try {
        const params = new URLSearchParams({root: session.root, source: session.source, sid: session.sid, before: String(history.cursor)});
        const response = await fetch(`/mobile/api/transcript?${params}`, {headers: headers()});
        if (!response.ok) throw new Error(await response.text());
        const page = await response.json();
        history.turns = mergeHistoryTurns(history.turns, page.turns || []);
        history.cursor = page.cursor ?? null;
        history.hasMore = Boolean(page.hasMore);
        turnsStructureKey = "";
        renderTurns(session);
        requestAnimationFrame(() => window.scrollTo({top: oldY + document.documentElement.scrollHeight - oldHeight}));
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
      turnsEl.innerHTML = turns.map(t => `<div class="turn ${t.role === "user" ? "user" : t.role === "output" ? "output" : "assistant"}">${renderRichText(t.text || "")}</div>`).join("");
      turnsStructureKey = nextKey;
      requestAnimationFrame(() => {
        if (!hadTurns || wasNearBottom) scrollToLatest();
        else newMessagesBtn.style.display = "block";
      });
    }
    function renderSubagents(session) {
      const subagents = (session && session.subagents) || [];
      subagentCount.textContent = String(subagents.length);
      subagentMenuBtn.style.display = session && session.kind === "agent" ? "block" : "none";
      if (!subagents.length) {
        updateHtmlIfChanged(subagentList, '<div class="empty-state">이 세션의 작업 에이전트 기록이 없습니다.</div>');
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
    function openSubagents() {
      closeMenu();
      renderSubagents(selectedSession());
      subagentSheet.classList.add("open");
      subagentSheet.setAttribute("aria-hidden", "false");
    }
    function inboxEventId(session) {
      return `${session.source || ""}:${session.sid || ""}:${session.status || "idle"}:${session.statusTs || session.ts || 0}`;
    }
    function inboxSessions() {
      const actionable = new Set(["waiting", "completed", "failed"]);
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
      const statusLabel = {waiting: "응답 대기", completed: "완료", failed: "실패"};
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
      closeMenu();
      closeSubagents();
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
    function suggestionItems(trigger) {
      const session = selectedSession();
      const source = sessionSource(session);
      const catalog = (session && session.catalog) || {skills: [], agents: []};
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
      const source = sessionSource(session);
      promptInput.placeholder = source === "claude" ? "Claude에 메시지" : source === "codex" ? "Codex에 메시지" : "터미널에 입력";
      const sessionTurns = (session && session.turns) || [];
      const activityText = sessionTurns.length ? String(sessionTurns[sessionTurns.length - 1].text || "") : String((session && session.preview) || "");
      if (sawActivity && activityText && activityText !== lastActivity) notifyChange(activityText);
      lastActivity = activityText;
      sawActivity = true;
      if (document.activeElement === promptInput) renderSuggestions();
    }
    async function load(options={}) {
      if (!token()) {
        showLogin("mobile token을 입력하세요.");
        return;
      }
      if (options.quiet && isEditing()) return;
      if (loading) return;
      loading = true;
      try {
        if (!options.quiet) statusEl.textContent = "불러오는 중...";
        const r = await fetch("/mobile/api/state", {headers: headers()});
        if (r.status === 403) {
          localStorage.removeItem("marinaMobileToken");
          showLogin("token이 맞지 않거나 mobile이 꺼져 있습니다.");
          return;
        }
        if (!r.ok) throw new Error(await r.text());
        state = await r.json();
        showApp();
        render();
        if (!options.quiet) statusEl.textContent = "준비됨";
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
      statusEl.textContent = "보내는 중...";
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
    menuBtn.onclick = event => {
      event.stopPropagation();
      const open = !menuPanel.classList.contains("open");
      menuPanel.classList.toggle("open", open);
      menuBtn.setAttribute("aria-expanded", open ? "true" : "false");
    };
    menuPanel.onclick = event => event.stopPropagation();
    document.addEventListener("click", closeMenu);
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
      renderProjectTabs();
      renderSourceTabs();
      renderSessions();
    };
    sourceTabs.onclick = event => {
      const btn = event.target.closest("[data-source]");
      if (!btn || !sourceTabs.contains(btn)) return;
      sourceFilter = btn.getAttribute("data-source") || "all";
      localStorage.setItem("marinaMobileSource", sourceFilter);
      renderSourceTabs();
      renderSessions();
    };
    sessionList.onclick = event => {
      const btn = event.target.closest("[data-key]");
      if (!btn || !sessionList.contains(btn)) return;
      chooseSession(btn.getAttribute("data-key"));
    };
    document.getElementById("refreshBtn").onclick = () => { closeMenu(); load().catch(e => statusEl.textContent = String(e)); };
    backBtn.onclick = () => { saveDraft(); clearFailedSend(); selectedSessionKey = ""; activeDraftKey = ""; turnsStructureKey = ""; localStorage.removeItem("marinaMobileSession"); showList(); renderProjectTabs(); renderSourceTabs(); renderSessions(); };
    document.getElementById("logoutBtn").onclick = () => { closeMenu(); logout(); };
    document.getElementById("notifyBtn").onclick = () => { closeMenu(); enableNotify().catch(e => statusEl.textContent = String(e)); };
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
    inboxMenuBtn.onclick = openInbox;
    inboxList.onclick = event => {
      const item = event.target.closest("[data-inbox-id]");
      if (item) selectInboxSession(item.getAttribute("data-inbox-id"));
    };
    document.getElementById("inboxCloseBtn").onclick = closeInbox;
    inboxSheet.onclick = event => { if (event.target === inboxSheet) closeInbox(); };
    subagentMenuBtn.onclick = openSubagents;
    document.getElementById("subagentCloseBtn").onclick = closeSubagents;
    subagentSheet.onclick = event => { if (event.target === subagentSheet) closeSubagents(); };
    rootSelect.onchange = () => { rememberRoot(); render(); };
    targetSelect.onchange = () => { rememberTarget(); render(); };
    sessionSearch.oninput = renderSessions;
    window.addEventListener("scroll", () => {
      if (window.scrollY < 72 && olderMessagesBtn.style.display !== "none") loadOlderMessages();
    }, {passive: true});
    setInterval(() => {
      if (document.visibilityState !== "hidden") load({quiet: true}).catch(e => statusEl.textContent = String(e));
    }, autoPollMs);
    load().catch(e => { statusEl.textContent = `실패 · ${String(e)}`; });
  </script>
</body>
</html>
"""
