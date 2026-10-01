#!/usr/bin/env python3
"""Discord 세션 — 워크트리 하나 = Discord 채널 하나 = tmux 안의 `claude --channels` 하나.

설계: docs/superpowers/specs/2026-10-01-discord-sessions-design.md
마리나는 실행 계층(worktree create · start)만 부른다. 대화 배달은 Claude Code Channels(공식 플러그인)가 한다.
데몬(python3.9)이 remove_worktree · idle_verdict 경로로 import 하므로 3.9 호환을 지킨다."""
from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import uuid
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

PLUGIN = "plugin:discord@claude-plugins-official"
API_DEFAULT = "https://discord.com/api/v10"
MARINA_SH = Path(__file__).resolve().parent / "marina.sh"
_TASK_RE = re.compile(r"[A-Za-z0-9._/-]+")
_KEEP_ENV = ("HOME", "PATH", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TMPDIR", "SSH_AUTH_SOCK")

CHANNEL_RULES = (
    "이 세션은 Discord 채널에 연결돼 있다. 상대는 Discord 만 보고 이 터미널은 보지 않는다.\n"
    "- 결과·질문·실패/막힘·완료는 반드시 discord reply 도구로 보낸다.\n"
    "- 긴 작업은 시작할 때 진행 메시지 하나를 reply 로 보내고 edit_message 로 갱신한다. "
    "끝나면 새 reply 를 보낸다(알림이 울리도록).\n"
    "- 질문은 번호 선택지 텍스트로 묻는다.\n"
    "- 이미지는 첨부한다. HTML 은 스크린샷과 열어볼 주소를 보낸다. 10MB 를 넘는 파일은 링크로 보낸다.\n"
    "- 터미널에서 직접 받은 지시의 답은 터미널에 둬도 된다."
)

CHAT_PROJECT = "chat"
CHAT_TOOLS = "WebSearch,WebFetch,Read,Write,Edit,Glob,Grep"
_REPLY_TOOL = "mcp__plugin_discord_discord__reply"
CHAT_RULES = (
    "이 세션은 Discord 채널에 연결된 일상 도우미다. 상대는 개발자가 아니고 Discord 만 본다.\n"
    "- 할 수 있는 일: 웹 검색·웹 페이지 읽기, 이 폴더 안에서 파일 만들기·고치기.\n"
    "- 답·질문·결과는 반드시 discord reply 도구로, 쉬운 말로 보낸다. 질문은 번호 선택지 텍스트로 묻는다.\n"
    "- 글 위주 결과(리서치·후보 비교·목록)는 파일 대신 Discord 서식 메시지로 바로 답한다: 제목은 **굵게**, "
    "목록·인용 사용. Discord 는 표를 못 그리니 표 대신 항목별 카드(이름 줄 + 들여쓴 세부 줄)로 쓴다. "
    "길면 메시지를 나눠 보낸다.\n"
    "- 배치가 중요한 결과(컨셉보드·기획안·슬라이드)만 HTML 로 만든다. CSS 는 파일 안에 넣는다. "
    "만든 결과물은 share_file 도구에 넘기고, 돌려받은 파일들을 reply 의 files 로 첨부한다(HTML 이면 미리보기 이미지가 함께 온다). "
    "버튼·클릭 같은 동작은 '파일을 받아서 브라우저로 열어 줘' 라고 안내한다.\n"
    "- 이 폴더 밖 파일은 읽거나 보낼 수 없다.\n"
    "- 상대가 보낸 첨부는 download_attachment 로 받아 읽는다.\n"
    "- 이 컴퓨터 주인의 다른 파일·설정·계정 정보는 묻더라도 다루지 않는다."
)
CHAT_LIMIT = 20
LOBBY_TASK = "lobby"
LOBBY_CHANNEL = "새-대화"
LOBBY_TOPIC = "새 대화방을 여는 곳 — \"○○ 얘기할 방 열어줘\" 라고 말하면 돼"
LOBBY_GUIDE = (
    "👋 **여기는 새 대화방을 여는 곳이야.**\n"
    "• \"웨딩 준비 얘기할 방 열어줘\" 처럼 말하면 CHAT 아래에 새 방을 만들어 줄게.\n"
    "• \"방 목록 보여줘\" 라고 하면 지금 있는 방을 알려줘.\n"
    "• 방마다 대화가 따로 기억돼. 주제가 바뀌면 새 방을 여는 게 좋아.\n"
    "• 방 안에서는 검색, 자료 정리, 문서·표 만들기를 부탁하면 돼. 만든 파일은 첨부로 보내 줄게."
)
LOBBY_RULES = (
    "이 세션은 Discord 의 '새-대화' 로비다. 하는 일은 새 대화방 열기와 방 목록 알려주기뿐이다. 상대는 개발자가 아니다.\n"
    "- 방을 열어 달라면 주제로 짧은 영문 소문자 이름(예: wedding-prep, 숫자·하이픈 가능)과 한글 제목을 정해 open_chat 을 부른다. "
    "이미 있으면 다른 이름을 고르거나 기존 방을 알려준다.\n"
    "- 결과(방 링크)는 discord reply 로 쉬운 말로 알린다. 사용법을 물으면 짧게 설명한다.\n"
    "- 그 밖의 부탁(검색·파일 등)은 새 방을 열어서 거기서 하라고 안내한다."
)


class SessionError(Exception):
    """사용자에게 그대로 보여줄 실패."""


# ── 경로·이름 ────────────────────────────────────────────────────────────────

def marina_home() -> Path:
    return Path(os.environ.get("MARINA_HOME") or "~/.marina").expanduser()


def channels_root() -> Path:
    return Path(os.environ.get("MARINA_CHANNELS_DIR") or "~/.claude/channels").expanduser()


def _check_task(task: str) -> None:
    if not _TASK_RE.fullmatch(task or "") or ".." in task:
        raise SessionError(f"작업 이름은 영문/숫자/./_/-(슬래시 포함)만 가능 — 공백·'..' 금지: {task!r}")


def worktree_dirname(task: str) -> str:
    """marina worktree create 의 폴더 이름 규칙(tr '/:' '--')과 같다."""
    _check_task(task)
    return re.sub(r"[/:]", "-", task)


def channel_name(task: str) -> str:
    """Discord 는 채널 이름을 소문자로 바꾼다 — 겹침 검사도 이 값으로 한다."""
    _check_task(task)
    return re.sub(r"[/:.]", "-", task).lower()


def tmux_name(project: str, task: str) -> str:
    return f"{project}-{channel_name(task)}"          # tmux 세션 이름엔 '.' ':' 불가


def rc_name(project: str, task: str) -> str:
    return f"{project}/{task}"


def state_dir(project: str, task: str) -> Path:
    return channels_root() / f"discord-{project}-{channel_name(task)}"


# ── 설정 discord.json ────────────────────────────────────────────────────────

def config_path() -> Path:
    return marina_home() / "discord.json"


def load_config() -> dict[str, Any]:
    p = config_path()
    if not p.is_file():
        raise SessionError(
            f"{p} 가 없어 — 예: {{\"guildId\": \"<서버ID>\", \"tokenFile\": \"~/.claude/channels/discord-token.env\", "
            f"\"projects\": {{\"<프로젝트>\": {{\"categoryId\": null, \"allow\": [\"<디스코드 사용자ID>\"]}}}}}}")
    try:
        cfg = json.loads(p.read_text(encoding="utf-8"))
    except ValueError as exc:
        raise SessionError(f"{p} 를 읽지 못했어: {exc}")
    if not isinstance(cfg, dict) or not cfg.get("guildId") or not cfg.get("tokenFile"):
        raise SessionError(f"{p} 에 guildId · tokenFile 이 필요해")
    if not isinstance(cfg.get("projects"), dict):
        cfg["projects"] = {}
    return cfg


def save_config(cfg: dict[str, Any]) -> None:
    p = config_path()
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, p)


def project_config(cfg: dict[str, Any], project: str) -> dict[str, Any]:
    pc = cfg["projects"].get(project)
    if not isinstance(pc, dict):
        raise SessionError(
            f"{config_path()} 의 projects 에 '{project}' 가 없어 — "
            f"\"{project}\": {{\"categoryId\": null, \"allow\": [\"<디스코드 사용자ID>\"]}} 로 추가해")
    return pc


def token_file(cfg: dict[str, Any]) -> Path:
    return Path(str(cfg["tokenFile"])).expanduser()


def read_token(cfg: dict[str, Any]) -> str:
    p = token_file(cfg)
    try:
        text = p.read_text(encoding="utf-8")
    except OSError:
        raise SessionError(f"토큰 파일이 없어: {p}")
    for line in text.splitlines():
        if line.startswith("DISCORD_BOT_TOKEN="):
            tok = line.split("=", 1)[1].strip()
            if tok:
                return tok
    raise SessionError(f"{p} 에 DISCORD_BOT_TOKEN= 줄이 없어")


def project_root(project: str) -> Path:
    p = marina_home() / "projects.json"
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise SessionError(f"{p} 를 읽지 못했어 — marina project add 로 프로젝트를 먼저 등록해")
    for item in data.get("projects", []) if isinstance(data, dict) else []:
        if str(item.get("id")) == project:
            return Path(os.path.realpath(os.path.expanduser(str(item.get("root") or ""))))
    raise SessionError(f"마리나에 등록되지 않은 프로젝트: {project} ('marina project ls' 로 확인)")


# ── 기록 sessions.json ───────────────────────────────────────────────────────

def sessions_path() -> Path:
    return marina_home() / "sessions.json"


def load_sessions() -> list[dict[str, Any]]:
    """깨졌거나 없으면 빈 목록 — 데몬 경로(idle_verdict)에서 예외를 내면 안 된다."""
    try:
        data = json.loads(sessions_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    items = data.get("sessions") if isinstance(data, dict) else None
    return [s for s in items if isinstance(s, dict)] if isinstance(items, list) else []


def save_sessions(items: list[dict[str, Any]]) -> None:
    p = sessions_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps({"sessions": items}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, p)


def find_session(ref: str, items: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    """'<프로젝트>/<작업>' 정확 일치를 먼저, 없으면 작업 이름 일치. 여러 개면 모호."""
    items = load_sessions() if items is None else items
    hits = [s for s in items if f"{s.get('project')}/{s.get('task')}" == ref] \
        or [s for s in items if s.get("task") == ref]
    if not hits:
        raise SessionError(f"세션을 찾지 못했어: {ref} ('marina session ls' 로 확인)")
    if len(hits) > 1:
        names = ", ".join(f"{s.get('project')}/{s.get('task')}" for s in hits)
        raise SessionError(f"'{ref}' 가 여러 프로젝트에 있어 모호해 — <프로젝트>/<작업> 으로 지정해: {names}")
    return hits[0]


# ── Discord REST ─────────────────────────────────────────────────────────────

class DiscordError(SessionError):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code


def _explain(code: int, method: str, path: str) -> str:
    if code == 401:
        return "Discord 가 토큰을 거부했어(401) — discord.json 의 tokenFile 을 확인해"
    if code == 403:
        return "봇 권한이 부족해(403) — 서버 설정 → 역할 → 봇 역할에서 '채널 관리하기'를 켜"
    if code == 404:
        return f"Discord 에서 대상을 찾지 못했어(404): {method} {path}"
    return f"Discord API 오류 {code}: {method} {path}"


class Discord:
    def __init__(self, token: str, base: str | None = None):
        self.token = token
        self.base = (base or os.environ.get("MARINA_DISCORD_API") or API_DEFAULT).rstrip("/")

    def _req(self, method: str, path: str, body: Any = None) -> Any:
        data = None if body is None else json.dumps(body).encode()
        for attempt in range(4):
            req = urllib.request.Request(self.base + path, data=data, method=method, headers={
                "Authorization": f"Bot {self.token}",
                "Content-Type": "application/json",
                "User-Agent": "DiscordBot (https://github.com/sumin/marina, 1)",
            })
            try:
                with urllib.request.urlopen(req, timeout=float(os.environ.get("MARINA_DISCORD_TIMEOUT") or 15)) as resp:
                    raw = resp.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as exc:
                raw = exc.read() or b"{}"
                if exc.code == 429 and attempt < 3:
                    try:
                        wait = float(json.loads(raw).get("retry_after", 1))
                    except (ValueError, AttributeError):
                        wait = 1.0
                    time.sleep(min(max(wait, 0.0), 10.0))
                    continue
                raise DiscordError(exc.code, _explain(exc.code, method, path))
            except urllib.error.URLError as exc:
                raise SessionError(f"Discord 에 연결하지 못했어: {exc.reason}")
            except OSError as exc:      # 응답 대기 중 타임아웃·연결 끊김은 URLError 가 아니다
                raise SessionError(f"Discord 응답을 받지 못했어: {exc}")
        raise DiscordError(429, "Discord 가 계속 요청을 늦추라고 해(429) — 잠시 뒤 다시 해")

    def list_channels(self, guild: str) -> list[dict[str, Any]]:
        return self._req("GET", f"/guilds/{guild}/channels") or []

    def create_category(self, guild: str, name: str, overwrites: list[dict[str, Any]] | None = None) -> str:
        body: dict[str, Any] = {"name": name, "type": 4}
        if overwrites is not None:
            body["permission_overwrites"] = overwrites
        return str(self._req("POST", f"/guilds/{guild}/channels", body)["id"])

    def me(self) -> str:
        return str(self._req("GET", "/users/@me")["id"])

    def list_roles(self, guild: str) -> list[dict[str, Any]]:
        return self._req("GET", f"/guilds/{guild}/roles") or []

    def create_text_channel(self, guild: str, name: str, parent: str, topic: str = "") -> str:
        body: dict[str, Any] = {"name": name, "type": 0, "parent_id": parent}
        if topic:
            body["topic"] = topic
        return str(self._req("POST", f"/guilds/{guild}/channels", body)["id"])

    def delete_channel(self, cid: str) -> None:
        self._req("DELETE", f"/channels/{cid}")

    def add_reaction(self, cid: str, mid: str, emoji: str) -> None:
        self._req("PUT", f"/channels/{cid}/messages/{mid}/reactions/{urllib.parse.quote(emoji)}/@me")

    def remove_reaction(self, cid: str, mid: str, emoji: str) -> None:
        self._req("DELETE", f"/channels/{cid}/messages/{mid}/reactions/{urllib.parse.quote(emoji)}/@me")

    def send_message(self, cid: str, content: str) -> None:
        # 본문의 @everyone·역할 멘션이 서버 알림이 되지 않게(로비 리뷰 L1)
        self._req("POST", f"/channels/{cid}/messages", {"content": content, "allowed_mentions": {"parse": []}})


def ensure_category(dc: Discord, cfg: dict[str, Any], project: str) -> str:
    """프로젝트 카테고리 ID. 저장된 ID 가 Discord 에 없으면(직접 지움) 새로 만들고 discord.json 을 고친다."""
    pc = project_config(cfg, project)
    cid = str(pc.get("categoryId") or "")
    if cid and any(str(c.get("id")) == cid and c.get("type") == 4 for c in dc.list_channels(cfg["guildId"])):
        return cid
    cid = dc.create_category(cfg["guildId"], project.upper())
    pc["categoryId"] = cid
    save_config(cfg)
    return cid


_VIEW = 1 << 10
_TALK = _VIEW | (1 << 11) | (1 << 16) | (1 << 15) | (1 << 14) | (1 << 6)   # 보기·쓰기·기록·첨부·링크·반응


def ensure_chat_category(dc: Discord, cfg: dict[str, Any]) -> tuple[str, bool]:
    """CHAT 카테고리. 채팅 채널은 허용 목록이 비어 '보이면 명령 가능'이므로 서버 기본값에 기대지 않고
    만들 때부터 @everyone 을 막고 봇·chat 역할만 연다(봇에 역할 관리 권한이 없어도 생성 시엔 된다).
    돌려주는 bool = chat 역할을 찾아 열었는지."""
    pc = cfg["projects"][CHAT_PROJECT]
    cid = str(pc.get("categoryId") or "")
    guild = str(cfg["guildId"])
    role = next((str(r["id"]) for r in dc.list_roles(guild) if r.get("name") == CHAT_PROJECT), "")
    found = next((c for c in dc.list_channels(guild) if cid and str(c.get("id")) == cid and c.get("type") == 4), None)
    if found:
        ow = {str(o.get("id")): o for o in found.get("permission_overwrites") or []}
        if not int((ow.get(guild) or {}).get("deny") or 0) & _VIEW:
            raise SessionError("CHAT 카테고리가 @everyone 에게 보여 — Discord 에서 CHAT 카테고리 권한의 "
                               "@everyone '채널 보기'를 끄거나, 카테고리를 지우면 막힌 채로 새로 만들어")
        return cid, bool(role) and bool(int((ow.get(role) or {}).get("allow") or 0) & _VIEW)
    ow = [{"id": guild, "type": 0, "allow": "0", "deny": str(_VIEW)},       # @everyone 역할 ID = 서버 ID
          {"id": dc.me(), "type": 1, "allow": str(_TALK), "deny": "0"}]
    if role:
        ow.append({"id": role, "type": 0, "allow": str(_TALK), "deny": "0"})
    cid = dc.create_category(guild, CHAT_PROJECT.upper(), ow)
    pc["categoryId"] = cid
    save_config(cfg)
    return cid, bool(role)


ARCHIVE_CHANNEL = "자료실"
ARCHIVE_TOPIC = "대화방에서 받은 결과물을 모아 두는 곳 — 여기선 대화하지 않아. 검색 → 미디어/파일 탭으로 모아 보기"


def ensure_archive(dc: Discord, cfg: dict[str, Any], project: str, category: str) -> str:
    """카테고리의 #자료실(세션 없음, 봇이 결과물을 모아 올림). 지워졌으면 다시 만든다."""
    pc = cfg["projects"][project]
    cid = str(pc.get("archiveChannelId") or "")
    if cid and cid in channel_ids(dc, str(cfg["guildId"])):
        return cid
    cid = dc.create_text_channel(str(cfg["guildId"]), ARCHIVE_CHANNEL, category, ARCHIVE_TOPIC)
    pc["archiveChannelId"] = cid
    save_config(cfg)
    return cid


def find_text_channel(dc: Discord, guild: str, parent: str, name: str) -> str | None:
    for c in dc.list_channels(guild):
        if c.get("type") == 0 and str(c.get("parent_id") or "") == str(parent) \
                and str(c.get("name") or "").lower() == name:
            return str(c["id"])
    return None


def channel_ids(dc: Discord, guild: str) -> set[str]:
    return {str(c.get("id")) for c in dc.list_channels(guild)}


# ── tmux ─────────────────────────────────────────────────────────────────────

def _tmux_exe() -> str:
    """launchd 데몬 PATH(/usr/bin:/bin)엔 homebrew tmux 가 없다 — 못 찾으면 워크트리를 지워도
    claude 가 계속 돈다(최종 리뷰 C1). which 다음 흔한 설치 경로로 폴백."""
    found = shutil.which("tmux")
    if found:
        return found
    for cand in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"):
        if os.access(cand, os.X_OK):
            return cand
    return ""


def _tmux_base() -> list[str]:
    """테스트는 MARINA_TMUX_SOCKET 으로 전용 소켓을 쓴다 — 형의 tmux 와 섞이지 않게."""
    sock = os.environ.get("MARINA_TMUX_SOCKET")
    exe = _tmux_exe() or "tmux"
    return [exe, "-L", sock] if sock else [exe]


def _tmux(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(_tmux_base() + list(args), capture_output=True, text=True)


def tmux_alive(name: str) -> bool:
    if not name or not _tmux_exe():
        return False
    return _tmux("has-session", "-t", f"={name}").returncode == 0


def clean_env_prefix(extra: dict[str, str]) -> list[str]:
    """화이트리스트 env 만 넘긴다. Claude 세션 안에서 부르면 CLAUDECODE·CLAUDE_CODE_* 를 물려받아
    자식 세션이 되고 트랜스크립트 저장이 꺼진다(실측 2026-09-10)."""
    out = ["/usr/bin/env", "-i"]
    out += [f"{k}={os.environ[k]}" for k in _KEEP_ENV if os.environ.get(k)]
    out.append("TERM=xterm-256color")
    out += [f"{k}={v}" for k, v in extra.items()]
    return out


def claude_argv(project: str, task: str, resume: bool = False) -> list[str]:
    argv = ["claude"]
    if resume:
        argv.append("--continue")
    argv += ["--channels", PLUGIN,
             "--remote-control", rc_name(project, task),
             "--append-system-prompt", CHANNEL_RULES,
             "--settings", str(state_dir(project, task) / "settings.json"),
             # 가변 인자라 뒤따르는 값을 삼킨다 — 맨 끝에 둔다(marina_term 실측 2026-09-10)
             "--disallowedTools", "AskUserQuestion"]
    return argv


def chat_argv(project: str, task: str, session_id: str, resume: bool = False, from_id: str = "") -> list[str]:
    """채팅 세션(실측 2026-10-01): 형 로그인 그대로 쓰되 --restricted 로 사용자 설정·메모리를 무시하고
    파일 도구를 폴더 안에 가둔다. 묻지 않고 거절 + 허용 목록(settings) + 허용 도구만(Bash 없음).
    받은 첨부는 상태 폴더 inbox 에 떨어지므로 그 폴더만 더한다.
    채팅 세션은 한 폴더를 함께 쓰므로 --continue(폴더의 최근 대화) 대신 자기 대화 ID 로 잇는다.
    from_id = 기존 대화의 복사본으로 시작(--fork-session — 원본을 다른 곳이 열고 있어도 안전, 실측)."""
    sdir = state_dir(project, task)
    argv = ["claude"]
    if resume:
        argv += ["--resume", session_id]
    elif from_id:
        argv += ["--resume", from_id, "--fork-session", "--session-id", session_id]
    else:
        argv += ["--session-id", session_id]
    argv += ["--channels", PLUGIN, "--restricted",
             "--permission-mode", "dontAsk",
             "--tools", CHAT_TOOLS,
             "--add-dir", str(sdir / "inbox"),
             "--append-system-prompt", CHAT_RULES,
             "--mcp-config", str(sdir / "mcp.json"),     # 마리나 도구(채팅: share_file, 로비: open_chat)
             "--settings", str(sdir / "settings.json"),
             "--disallowedTools", "AskUserQuestion"]
    return argv


def transcript_path(cwd: Path, session_id: str) -> Path:
    """claude 가 대화 기록을 두는 곳 — 폴더 키는 실제 경로의 영숫자 외 문자를 '-' 로(실측)."""
    root = Path(os.environ.get("MARINA_CLAUDE_PROJECTS") or "~/.claude/projects").expanduser()
    return root / re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(str(cwd))) / f"{session_id}.jsonl"


def lobby_argv(project: str, task: str, session_id: str, resume: bool = False) -> list[str]:
    """로비: 내장 도구 없이 마리나 MCP(open_chat·list_chats)와 Discord 도구만."""
    argv = chat_argv(project, task, session_id, resume=resume)
    argv[argv.index("--tools") + 1] = ""
    argv[argv.index("--append-system-prompt") + 1] = LOBBY_RULES
    return argv


def session_argv(s: dict[str, Any], resume: bool = False) -> list[str]:
    if s.get("kind") in ("chat", "chat-lobby"):
        sid = str(s.get("sessionId") or "")
        if not sid:
            raise SessionError("sessionId 가 없는 옛 기록이야 — rm 후 다시 만들어")
        # 아무도 말을 안 건 채 껐다 켜면 기록이 없어 --resume 이 실패한다(복사본도 첫 메시지 때 생긴다, 실측)
        # → 같은 ID 로 새로 시작하되, 옮긴 대화면 다시 복사본으로
        has = transcript_path(Path(str(s["root"])), sid).is_file()
        if s.get("kind") == "chat-lobby":
            return lobby_argv(str(s["project"]), str(s["task"]), sid, resume=resume and has)
        return chat_argv(str(s["project"]), str(s["task"]), sid, resume=resume and has,
                         from_id="" if has else str(s.get("forkedFrom") or ""))
    return claude_argv(str(s["project"]), str(s["task"]), resume=resume)


def tmux_start(name: str, cwd: Path, argv: list[str], env_extra: dict[str, str], notify_ref: str = "") -> None:
    run = list(argv)
    if notify_ref:
        # claude 가 스스로 끝나면 채널에 알린다. kill-session(stop·rm)은 셸째 죽어 알리지 않는다.
        notify = shlex.join([sys.executable, str(Path(__file__).resolve()), "notify-exit", notify_ref])
        # 알림은 떼어 보내 셸이 바로 끝나게 한다("기동 직후 죽음"을 tmux_alive 가 놓치지 않게).
        # nohup 은 셸 종료 시 tmux 의 HUP 과 경쟁해 같이 죽었다(실측) — 부모가 먼저 HUP 를 무시하고 띄운다.
        run = ["/bin/sh", "-c", f'"$@"; code=$?; trap "" HUP; {notify} "$code" >/dev/null 2>&1 </dev/null &', "sh"] + run
    cmd = shlex.join(clean_env_prefix(env_extra) + run)
    r = _tmux("new-session", "-d", "-s", name, "-x", "200", "-y", "50", "-c", str(cwd), cmd)
    if r.returncode != 0:
        raise SessionError(f"tmux 실행 실패: {(r.stderr or r.stdout).strip()}")
    time.sleep(float(os.environ.get("MARINA_SESSION_BOOT_WAIT") or 2.0))
    if not tmux_alive(name):
        raise SessionError(f"claude 가 바로 꺼졌어 — 직접 확인: cd {shlex.quote(str(cwd))} && claude --channels {PLUGIN}")

def tmux_stop(name: str) -> None:
    if tmux_alive(name):
        _tmux("kill-session", "-t", f"={name}")


# ── 상태 폴더 · 마리나 실행 계층 ─────────────────────────────────────────────

def write_state_dir(path: Path, channel_id: str, allow: list[str], token_path: Path) -> None:
    """채널 플러그인의 DISCORD_STATE_DIR. 토큰은 복사하지 않고 심링크 — 기본 폴더에 토큰을 두면
    열린 모든 Claude 세션이 같은 봇으로 접속한다(실측 2026-10-01)."""
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    # 최상위 allowFrom = DM 허용 목록. 같은 봇을 쓰는 모든 세션이 DM 을 동시에 받으므로 비운다(최종 리뷰 I1).
    access = {"dmPolicy": "allowlist", "allowFrom": [],
              "groups": {channel_id: {"requireMention": False, "allowFrom": list(allow)}},
              "ackReaction": "👀", "replyToMode": "first"}
    (path / "access.json").write_text(json.dumps(access, ensure_ascii=False) + "\n", encoding="utf-8")
    env = path / ".env"
    if env.is_symlink() or env.exists():
        env.unlink()
    env.symlink_to(token_path)


def remove_state_dir(path: Path) -> None:
    shutil.rmtree(path, ignore_errors=True)


_CHANNEL_TAG = re.compile(r'<channel source=\\?"plugin:discord:discord\\?" chat_id=\\?"(\d+)\\?" message_id=\\?"([^"\\]+)')


def write_settings(sdir: Path, chat_root: Path | None = None, lobby: bool = False) -> Path:
    """채널 세션 전용 설정(--settings). 사용자 설정과 합쳐진다.
    Stop 훅 = 턴이 끝나면 👀→✅. enabledPlugins = 사용자 범위에서 플러그인을 꺼도 이 세션에서만 켜지게."""
    # 버전 캐시 경로가 지워지면 exit 2 가 claude 종료를 막는다 → 실패해도 0(최종 리뷰 I2). start 가 다시 쓴다.
    cmd = shlex.join([sys.executable, str(Path(__file__).resolve()), "hook-stop"]) + " || true"
    settings = {"enabledPlugins": {"discord@claude-plugins-official": True},
                "hooks": {"Stop": [{"hooks": [{"type": "command", "command": cmd, "timeout": 15}]}]}}
    if chat_root is not None:
        # 플러그인은 첨부 경로에서 자기 상태 폴더만 막는다 — 폴더 밖 파일은 훅으로 막는다(실측).
        guard = shlex.join([sys.executable, str(Path(__file__).resolve()), "hook-chat-guard",
                            str(chat_root), str(sdir / "inbox")])
        # 판정기가 어떤 이유로든 죽으면(파이썬 경로 바뀜 등) exit 2 = 도구 호출을 막는다(리뷰 I1)
        guard += " || exit 2"
        real = os.path.realpath(str(chat_root))
        settings["permissions"] = {
            "allow": ["Read", "Glob", "Grep", "Write", "Edit", "WebSearch", "WebFetch"]
                     + [f"mcp__plugin_discord_discord__{t}" for t in
                        ("reply", "react", "edit_message", "fetch_messages", "download_attachment")]
                     + (["mcp__marina__open_chat", "mcp__marina__list_chats"] if lobby else ["mcp__marina__share_file"]),
            # 다음 기동 때 실행될 수 있는 폴더 안 설정 파일은 못 쓰게(리뷰 I2). '//' = 절대 경로
            "deny": [f"Edit(/{real}/{f})" for f in (".mcp.json", ".claude/**", "CLAUDE.md", "CLAUDE.local.md")]}
        settings["hooks"]["PreToolUse"] = [{"matcher": f"{_REPLY_TOOL}|WebFetch|Write|Edit",
                                            "hooks": [{"type": "command", "command": guard, "timeout": 15}]}]
    if chat_root is not None:
        mcp = {"mcpServers": {"marina": {"command": sys.executable,
                                         "args": [str(Path(__file__).resolve()), "mcp-lobby" if lobby else "mcp-chat"]}}}
        (sdir / "mcp.json").write_text(json.dumps(mcp, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    f = sdir / "settings.json"
    f.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return f


_CHAT_CONFIG_NAMES = (".mcp.json", "claude.md", "claude.local.md")


def _deny(reason: str) -> dict[str, Any]:
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                   "permissionDecisionReason": reason}}


def _inside(path: str, bases: list[str]) -> bool:
    real = os.path.realpath(path)
    return any(real == b or real.startswith(b + os.sep) for b in bases)


def _public_host(host: str) -> bool:
    """모든 해석 주소가 공인(global)일 때만 True — 루프백·사설·링크로컬·tailnet(100.64/10) 거절."""
    try:
        infos = socket.getaddrinfo(host, None)
    except (OSError, UnicodeError):
        return False
    addrs = {i[4][0].split("%")[0] for i in infos}
    return bool(addrs) and all(ipaddress.ip_address(a).is_global for a in addrs)


def chat_guard(root: Path, inbox: Path, payload: dict[str, Any]) -> dict[str, Any] | None:
    """채팅 세션 PreToolUse. 답장 첨부는 채팅 폴더·받은 첨부(inbox) 안 절대 경로만,
    웹 읽기는 공인 주소만. 거절이면 결정을 돌려준다."""
    ti = payload.get("tool_input") or {}
    if payload.get("tool_name") in ("Write", "Edit"):
        # deny 규칙은 대소문자(APFS 는 구분 안 함)·하위 폴더를 놓친다 — 경로 구성요소로 본다(리뷰 I-b)
        parts = [x.casefold() for x in Path(str(ti.get("file_path") or "")).parts]
        if ".claude" in parts or (parts and parts[-1] in _CHAT_CONFIG_NAMES):
            return _deny(f"설정 파일은 만들거나 고칠 수 없어: {ti.get('file_path')}")
        return None
    if payload.get("tool_name") == "WebFetch":
        url = urllib.parse.urlsplit(str(ti.get("url") or ""))
        if url.scheme not in ("http", "https") or not url.hostname or not _public_host(url.hostname):
            return _deny(f"이 컴퓨터·내부망 주소는 열 수 없어: {ti.get('url')}")
        return None
    files = ti.get("files") or []
    if not isinstance(files, list):
        return _deny("첨부 목록 형식이 이상해")
    bases = [os.path.realpath(str(root)), os.path.realpath(str(inbox))]
    for f in files:
        if not isinstance(f, str) or not os.path.isabs(f) or not _inside(f, bases):
            return _deny(f"채팅 폴더 밖 파일은 보낼 수 없어: {f}")
    return None


def claude_json_path() -> Path:
    return Path(os.environ.get("MARINA_CLAUDE_JSON") or "~/.claude.json").expanduser()


def ensure_trusted(folder: Path) -> None:
    """새 폴더는 신뢰 확인창에서 멈추고 그동안 플러그인이 안 뜬다(실측). 하위 폴더는 상위 신뢰를 물려받는다."""
    p = Path(os.path.realpath(str(claude_json_path())))     # dotfiles 심링크를 일반 파일로 바꾸지 않게
    key = os.path.realpath(str(folder))                     # claude 는 실제 경로로 찾는다
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise SessionError(f"{p} 를 읽지 못했어 — claude 를 한 번 실행해 로그인했는지 확인해")
    projects = data.get("projects") if isinstance(data, dict) else None
    if not isinstance(projects, dict):
        raise SessionError(f"{p} 형식이 예상과 달라(projects 없음) — claude 를 한 번 실행한 뒤 다시 해")
    entry = projects.setdefault(key, {})
    if not isinstance(entry, dict):
        raise SessionError(f"{p} 의 {key} 항목 형식이 예상과 달라")
    if entry.get("hasTrustDialogAccepted") is True:
        return
    entry["hasTrustDialogAccepted"] = True
    # 읽기→쓰기 사이를 최소로. 다른 claude 가 그 사이 쓴 변경은 잃을 수 있다(한 번, 키 하나 추가할 때만).
    tmp = p.with_name(f".{p.name}.marina-{os.getpid()}-{time.time_ns()}")
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        os.replace(tmp, p)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


def chat_home() -> Path:
    return marina_home() / "chat"


def session_env(sdir: Path) -> dict[str, str]:
    """claude 는 깨끗한 env 로 뜨므로, 훅·알림이 마리나 상태를 찾을 변수를 넣어 준다."""
    env = {"DISCORD_STATE_DIR": str(sdir), "MARINA_HOME": str(marina_home())}
    for k in ("MARINA_DISCORD_API", "MARINA_CHANNELS_DIR"):
        if os.environ.get(k):
            env[k] = os.environ[k]
    return env


def last_inbound_message(transcript: Path, channel_id: str) -> str | None:
    """세션 기록 끝 2MB 에서 이 채널에서 받은 마지막 메시지 ID(JSON 이스케이프 \" 도 허용)."""
    try:
        data = transcript.read_bytes()[-2_000_000:].decode("utf-8", "replace")
    except OSError:
        return None
    last = None
    for m in _CHANNEL_TAG.finditer(data):
        if m.group(1) == channel_id:
            last = m.group(2)
    return last


def _hook_target(payload: dict[str, Any], items: list[dict[str, Any]]) -> dict[str, Any] | None:
    """상태 폴더로 찾고, 없으면 cwd 로 짐작 — 채팅 세션은 모두 같은 폴더라 짐작하지 않는다."""
    sdir = os.environ.get("DISCORD_STATE_DIR") or ""
    root = Path(str(payload.get("cwd") or "/nonexistent")).resolve()
    return next((x for x in items if sdir and x.get("stateDir") == sdir), None) \
        or next((x for x in items if x.get("kind") not in ("chat", "chat-lobby") and _same_root(x, root)), None)


def hook_stop(payload: dict[str, Any]) -> None:
    items = load_sessions()
    s = _hook_target(payload, items)
    if not s or not s.get("channelId"):
        return
    mid = last_inbound_message(Path(str(payload.get("transcript_path") or "/nonexistent")), str(s["channelId"]))
    if not mid:
        return
    cfg = load_config()
    dc = Discord(read_token(cfg))
    dc.add_reaction(str(s["channelId"]), mid, "✅")
    try:
        dc.remove_reaction(str(s["channelId"]), mid, "👀")
    except DiscordError:
        pass


def notify_exit(ref: str, code: str) -> None:
    try:
        s = find_session(ref)
    except SessionError:
        return                                   # 기동 실패(기록 전) · 이미 rm 된 세션
    if not s.get("channelId"):
        return
    cfg = load_config()
    Discord(read_token(cfg)).send_message(
        str(s["channelId"]), f"⚠ 세션이 꺼졌어 (종료 코드 {code}) — 다시 켜기: `marina session start {ref}`")


def _run_marina(args: list[str], cwd: Path | None = None, timeout: int = 300) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(MARINA_SH)] + args, cwd=str(cwd) if cwd else None,
                          capture_output=True, text=True, timeout=timeout)


def worktree_create(project: str, task: str, base: str = "") -> Path:
    r = _run_marina(["worktree", "create", task] + ([base] if base else []) + ["--project", project])
    out = (r.stdout or "") + (r.stderr or "")
    if r.returncode != 0:
        raise SessionError("워크트리 생성 실패: " + out.strip()[-800:])
    m = re.search(r"✓ 워크트리:\s*(.+)", out)
    if not m:
        raise SessionError("워크트리 경로를 출력에서 찾지 못했어: " + out.strip()[-400:])
    return Path(m.group(1).strip())


def marina_start(root: Path) -> str:
    """실행 환경 시작. 실패해도 세션은 연다 — 실행 환경은 나중에 켜도 된다. 성공이면 빈 문자열."""
    try:
        r = _run_marina(["start", "--all"], cwd=root, timeout=900)
    except subprocess.TimeoutExpired:
        return "marina start 가 15분 안에 끝나지 않았어 — marina status 로 확인해"
    if r.returncode == 0:
        return ""
    return "marina start 실패(세션은 열었어): " + (r.stderr or r.stdout or "").strip()[-400:]


# ── 명령 ─────────────────────────────────────────────────────────────────────

def preflight(cfg: dict[str, Any], dc: Discord, project: str, task: str) -> dict[str, Any]:
    """아무것도 만들기 전에 전부 본다 — 하나라도 걸리면 SessionError."""
    pc = project_config(cfg, project)
    root = project_root(project)
    tf = token_file(cfg)
    if not tf.is_file():
        raise SessionError(f"토큰 파일이 없어: {tf}")
    if not _tmux_exe():
        raise SessionError("'tmux' 를 찾지 못했어 (brew install tmux)")
    if not shutil.which("claude"):
        raise SessionError("'claude' 를 찾지 못했어 (PATH 확인)")
    wt = root / ".claude" / "worktrees" / worktree_dirname(task)
    name, sdir, chan = tmux_name(project, task), state_dir(project, task), channel_name(task)
    if wt.exists():
        raise SessionError(f"워크트리가 이미 있어: {wt}")
    if tmux_alive(name):
        raise SessionError(f"tmux 세션이 이미 있어: {name}")
    if sdir.exists():
        raise SessionError(f"상태 폴더가 이미 있어: {sdir}")
    if any(s.get("project") == project and s.get("task") == task for s in load_sessions()):
        raise SessionError(f"세션 기록이 이미 있어: {project}/{task}")
    dc.list_channels(cfg["guildId"])      # 토큰·서버 확인 — 워크트리를 만들기 전에(첫 실행에도)
    cat = str(pc.get("categoryId") or "")
    if cat and find_text_channel(dc, cfg["guildId"], cat, chan):
        raise SessionError(f"Discord 채널이 이미 있어: #{chan}")
    return {"root": root, "worktree": wt, "tmux": name, "stateDir": sdir, "channel": chan}


def cmd_new_chat(name: str, from_id: str = "", title: str = "", lobby: bool = False) -> dict[str, Any]:
    """워크트리 없는 채팅 세션. 모든 채팅 세션이 chat 폴더 하나(마리나 모바일 chat 방과 같은 곳)를 함께 쓴다 —
    그동안 만든 파일을 어느 채널에서든 본다. from_id 를 주면 그 대화의 복사본으로 이어 간다."""
    project = CHAT_PROJECT
    if name.startswith("."):
        raise SessionError(f"채팅 이름은 '.' 으로 시작할 수 없어: {name!r}")
    if not lobby and name == LOBBY_TASK:
        raise SessionError(f"'{LOBBY_TASK}' 는 로비 이름이라 쓸 수 없어")
    if not lobby and sum(1 for s in load_sessions() if s.get("kind") == "chat") >= CHAT_LIMIT:
        raise SessionError(f"채팅방은 최대 {CHAT_LIMIT}개까지야 — 안 쓰는 방을 정리한 뒤 다시 해")
    if from_id:
        try:
            if str(uuid.UUID(from_id)) != from_id.lower():
                raise ValueError
        except ValueError:
            raise SessionError(f"대화 ID 형식이 아니야(UUID): {from_id!r}")
        if not transcript_path(chat_home(), from_id.lower()).is_file():
            raise SessionError(f"chat 폴더의 대화가 아니야(기록 없음): {from_id}")
    cfg = load_config()
    if not isinstance(cfg["projects"].get(project), dict):
        cfg["projects"][project] = {"categoryId": None, "allow": []}     # 허용 목록 비움 = chat 역할로만
        save_config(cfg)
    dc = Discord(read_token(cfg))
    tmux, sdir = tmux_name(project, name), state_dir(project, name)
    chan = LOBBY_CHANNEL if lobby else channel_name(name)
    folder = chat_home()
    tf = token_file(cfg)
    if not tf.is_file():
        raise SessionError(f"토큰 파일이 없어: {tf}")
    if not _tmux_exe():
        raise SessionError("'tmux' 를 찾지 못했어 (brew install tmux)")
    if not shutil.which("claude"):
        raise SessionError("'claude' 를 찾지 못했어 (PATH 확인)")
    if tmux_alive(tmux):
        raise SessionError(f"tmux 세션이 이미 있어: {tmux}")
    if sdir.exists():
        raise SessionError(f"상태 폴더가 이미 있어: {sdir}")
    if any(s.get("project") == project and s.get("task") == name for s in load_sessions()):
        raise SessionError(f"세션 기록이 이미 있어: {project}/{name}")
    dc.list_channels(cfg["guildId"])
    cat = str(cfg["projects"][project].get("categoryId") or "")
    if cat and find_text_channel(dc, cfg["guildId"], cat, chan):
        raise SessionError(f"Discord 채널이 이미 있어: #{chan}")
    folder.mkdir(parents=True, exist_ok=True)
    os.chmod(folder, 0o700)
    ensure_trusted(chat_home())
    folder = Path(os.path.realpath(str(folder)))
    record = {"project": project, "task": name, "kind": "chat-lobby" if lobby else "chat", "root": str(folder),
              "tmux": tmux, "stateDir": str(sdir), "rcName": "", "sessionId": str(uuid.uuid4()),
              "createdAt": int(time.time())}
    if title:
        record["title"] = title
    if from_id:
        record["forkedFrom"] = from_id.lower()
    channel_id = ""
    role_ok = True
    try:
        cat, role_ok = ensure_chat_category(dc, cfg)
        ensure_archive(dc, cfg, project, cat)
        channel_id = dc.create_text_channel(cfg["guildId"], chan, cat, LOBBY_TOPIC if lobby else title)
        write_state_dir(sdir, channel_id, cfg["projects"][project].get("allow") or [], tf)
        (sdir / "inbox").mkdir(exist_ok=True)
        write_settings(sdir, chat_root=folder, lobby=lobby)
        argv = lobby_argv(project, name, record["sessionId"]) if lobby else \
            chat_argv(project, name, record["sessionId"], from_id=from_id.lower())
        tmux_start(tmux, folder, argv, chat_env(sdir), notify_ref=f"{project}/{name}")
    except Exception as exc:
        remove_state_dir(sdir)
        if channel_id:
            try:
                dc.delete_channel(channel_id)
            except SessionError:
                pass
        raise SessionError(str(exc))
    record["channelId"] = channel_id
    items = load_sessions()
    items.append(record)
    save_sessions(items)
    warning = "" if role_ok else (
        "Discord 에 'chat' 역할이 없어 CHAT 카테고리를 봇과 관리자만 볼 수 있어 — "
        "역할을 만든 뒤 CHAT 카테고리 권한에 chat 역할(채널 보기·메시지 보내기·기록 보기)을 추가해")
    try:   # 첫 안내 — 실패해도 방은 연다
        dc.send_message(channel_id, LOBBY_GUIDE if lobby else welcome_text(title or name, bool(from_id)))
    except SessionError as exc:
        warning = (warning + " / " if warning else "") + f"안내 메시지 실패: {exc}"
    return dict(record, url=f"https://discord.com/channels/{cfg['guildId']}/{channel_id}", warning=warning)


def welcome_text(title: str, forked: bool) -> str:
    lines = [f"💬 **여기는 '{title}' 대화방이야.** 그냥 편하게 말 걸면 돼."]
    if forked:
        lines.append("• 예전에 하던 대화를 그대로 기억하고 있어. 이어서 얘기하면 돼.")
    lines += ["• 검색, 자료 정리, 문서·표 만들기를 부탁해 봐. 만든 파일은 첨부로 보내 줄게.",
              "• 다른 주제는 #새-대화 에서 새 방을 열어 줘."]
    return "\n".join(lines)


def chat_env(sdir: Path) -> dict[str, str]:
    return dict(session_env(sdir), ENABLE_CLAUDEAI_MCP_SERVERS="false")   # 형의 claude.ai 커넥터 끔


_OPEN_CHAT_SCHEMA = {
    "type": "object",
    "properties": {"name": {"type": "string", "description": "채널 이름: 영문 소문자·숫자·하이픈 (예: wedding-prep)"},
                   "title": {"type": "string", "description": "한글 제목 (예: 웨딩 준비)"}},
    "required": ["name", "title"]}
_LOBBY_TOOLS = [
    {"name": "open_chat", "description": "CHAT 카테고리에 새 대화방(채널+세션)을 연다. 방 링크를 돌려준다.",
     "inputSchema": _OPEN_CHAT_SCHEMA},
    {"name": "list_chats", "description": "지금 있는 대화방 목록(이름·제목·링크).",
     "inputSchema": {"type": "object", "properties": {}}}]
_SLUG = re.compile(r"[a-z0-9][a-z0-9-]{0,40}")


def lobby_tool(name: str, args: dict[str, Any]) -> str:
    """로비 MCP 도구 실행. 실패는 SessionError(사용자에게 그대로 보일 문장)."""
    cfg = load_config()
    link = "https://discord.com/channels/" + str(cfg["guildId"]) + "/{}"
    if name == "list_chats":
        rows = [f"- {s.get('title') or s['task']} ({s['task']}): {link.format(s.get('channelId'))}"
                for s in load_sessions() if s.get("kind") == "chat"]
        return "\n".join(rows) or "아직 대화방이 없어"
    if name == "open_chat":
        slug, title = str(args.get("name") or ""), str(args.get("title") or "").strip()
        if not _SLUG.fullmatch(slug):
            raise SessionError("방 이름은 영문 소문자·숫자·하이픈만 (예: wedding-prep)")
        if not title or len(title) > 80:
            raise SessionError("제목이 필요해(80자 이내)")
        if re.search(r"[@<>\n\r`]", title):
            raise SessionError("제목에 @ < > ` 줄바꿈은 쓸 수 없어")
        r = cmd_new_chat(slug, title=title)
        return f"열었어: {title} → {r['url']}" + (f"\n(참고: {r['warning']})" if r.get("warning") else "")
    raise SessionError(f"없는 도구: {name}")


_CHAT_TOOLS_MCP = [
    {"name": "share_file",
     "description": "만든 결과물을 Discord 로 보낼 준비를 한다. HTML 이면 미리보기 이미지를 만들고, #자료실 에도 모아 올린다. "
                    "돌려받은 파일 경로들을 reply 의 files 로 첨부해라.",
     "inputSchema": {"type": "object",
                     "properties": {"path": {"type": "string", "description": "이 폴더 안 파일 경로(상대·절대)"},
                                    "title": {"type": "string", "description": "결과물 제목(자료실 표시용)"}},
                     "required": ["path"]}}]


def chat_tool(name: str, args: dict[str, Any]) -> str:
    """채팅 세션 MCP 도구. 실패는 SessionError."""
    if name != "share_file":
        raise SessionError(f"없는 도구: {name}")
    import marina_share
    sdir = os.environ.get("DISCORD_STATE_DIR") or ""
    rec = next((s for s in load_sessions() if sdir and s.get("stateDir") == sdir), None)
    if not rec:
        raise SessionError("이 세션의 기록을 찾지 못했어")
    root = Path(os.path.realpath(str(rec["root"])))
    raw = str(args.get("path") or "")
    if not raw:
        raise SessionError("path 가 필요해")
    path = Path(os.path.realpath(raw if os.path.isabs(raw) else str(root / raw)))
    if not str(path).startswith(str(root) + os.sep) or not path.is_file():
        raise SessionError(f"이 폴더 안 파일만 공유할 수 있어: {raw}")
    parts_cf = [x.casefold() for x in path.relative_to(root).parts]
    if ".claude" in parts_cf or parts_cf[-1] in _CHAT_CONFIG_NAMES:
        raise SessionError(f"설정 파일은 공유할 수 없어: {raw}")
    files, notes = [path], []
    if path.suffix.lower() in (".html", ".htm"):
        prev, why = marina_share.render_html(path, root, root / "미리보기")
        if not prev:
            notes.append(f"미리보기를 만들지 못했어({why}) — HTML 파일만 보내")
        else:
            files = [prev] + files
            if why:
                notes.append(why)
    title = str(args.get("title") or path.stem).replace("@", "").replace("\n", " ")[:80]
    cfg = load_config()
    arch = str((cfg["projects"].get(CHAT_PROJECT) or {}).get("archiveChannelId") or "")
    if arch:
        room = str(rec.get("title") or rec.get("task")).replace("@", "")
        big = [f for f in files if f.stat().st_size > 10 * 1024 * 1024]
        try:
            marina_share.upload_message(Discord(read_token(cfg)).base, read_token(cfg), arch,
                                        f"📎 [{room}] {title}\n원래 방: <#{rec.get('channelId')}>",
                                        [f for f in files if f not in big])
            notes.append("#자료실 에도 올렸어")
        except Exception as exc:
            notes.append(f"#자료실 올리기 실패: {exc}")
    return "reply 의 files 로 첨부할 파일:\n" + "\n".join(str(f) for f in files) + \
        ("\n" + "\n".join(notes) if notes else "")


def mcp_lobby(stdin: Any = None, stdout: Any = None) -> None:
    mcp_serve(_LOBBY_TOOLS, lobby_tool, stdin, stdout)


def mcp_chat(stdin: Any = None, stdout: Any = None) -> None:
    mcp_serve(_CHAT_TOOLS_MCP, chat_tool, stdin, stdout)


def mcp_serve(tools: list[dict[str, Any]], handler: Any, stdin: Any = None, stdout: Any = None) -> None:
    """최소 MCP 서버(stdio, 한 줄 JSON-RPC)."""
    stdin, stdout = stdin or sys.stdin, stdout or sys.stdout
    def send(obj: dict[str, Any]) -> None:
        stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        stdout.flush()
    for line in stdin:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if not isinstance(msg, dict):
            continue
        mid, method, params = msg.get("id"), msg.get("method"), msg.get("params") or {}
        if mid is None:
            continue                                      # 알림엔 답하지 않는다
        if method == "initialize":
            result: Any = {"protocolVersion": params.get("protocolVersion") or "2025-06-18",
                           "capabilities": {"tools": {}}, "serverInfo": {"name": "marina", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": tools}
        elif method == "tools/call":
            try:
                text, err = handler(str(params.get("name")), params.get("arguments") or {}), False
            except SessionError as exc:
                text, err = str(exc), True
            except Exception as exc:                       # 서버는 죽지 않는다
                text, err = f"실패: {exc}", True
            result = {"content": [{"type": "text", "text": text}], "isError": err}
        elif method == "ping":
            result = {}
        else:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"unknown method {method}"}})
            continue
        send({"jsonrpc": "2.0", "id": mid, "result": result})


def cmd_new(project: str, task: str, base: str = "", start: bool = True, from_id: str = "",
            title: str = "") -> dict[str, Any]:
    if project == CHAT_PROJECT:
        return cmd_new_chat(task, from_id, title=title)
    if from_id:
        raise SessionError("--from 은 채팅 세션(new chat <이름>)에서만 쓸 수 있어")
    cfg = load_config()
    dc = Discord(read_token(cfg))
    plan = preflight(cfg, dc, project, task)
    wt = worktree_create(project, task, base)
    warning = marina_start(wt) if start else ""
    sdir: Path = plan["stateDir"]
    channel_id = ""
    try:
        cat = ensure_category(dc, cfg, project)
        channel_id = dc.create_text_channel(cfg["guildId"], plan["channel"], cat)
        write_state_dir(sdir, channel_id, project_config(cfg, project).get("allow") or [], token_file(cfg))
        write_settings(sdir)
        tmux_start(plan["tmux"], wt, claude_argv(project, task), session_env(sdir), notify_ref=f"{project}/{task}")
    except Exception as exc:
        remove_state_dir(sdir)
        if channel_id:
            try:
                dc.delete_channel(channel_id)
            except SessionError:
                pass
        raise SessionError(f"{exc}\n워크트리는 남겨 뒀어: {wt} (필요 없으면 대시보드에서 삭제)")
    record = {"project": project, "task": task, "root": str(wt), "channelId": channel_id,
              "tmux": plan["tmux"], "stateDir": str(sdir), "rcName": rc_name(project, task),
              "createdAt": int(time.time())}
    items = load_sessions()
    items.append(record)
    save_sessions(items)
    return dict(record, url=f"https://discord.com/channels/{cfg['guildId']}/{channel_id}", warning=warning)


def cmd_ls() -> list[dict[str, Any]]:
    items = load_sessions()
    ids: set[str] | None = None
    if items:
        try:
            cfg = load_config()
            ids = channel_ids(Discord(read_token(cfg)), cfg["guildId"])
        except SessionError:
            ids = None                       # Discord 를 못 봐도 목록은 보여준다
    return [dict(s, alive=tmux_alive(str(s.get("tmux") or "")),
                 channel=None if ids is None else str(s.get("channelId")) in ids) for s in items]


def cmd_start(ref: str = "", all_: bool = False) -> tuple[list[str], list[str]]:
    targets = load_sessions() if all_ else [find_session(ref)]
    started: list[str] = []
    failed: list[str] = []
    for s in targets:
        label = f"{s.get('project')}/{s.get('task')}"
        name = str(s.get("tmux") or "")
        chat = s.get("kind") in ("chat", "chat-lobby")
        if tmux_alive(name):
            continue
        root = Path(str(s.get("root") or ""))
        if not s.get("root") or not root.is_dir():
            failed.append(f"{label}: {'폴더' if chat else '워크트리'}가 없어 건너뜀")
            continue
        try:
            sdir = Path(str(s.get("stateDir") or ""))
            if s.get("stateDir") and sdir.is_dir():
                # 업데이트로 바뀐 스크립트 경로를 다시 적는다
                write_settings(sdir, chat_root=root if chat else None, lobby=s.get("kind") == "chat-lobby")
            if chat:
                ensure_trusted(chat_home())
            tmux_start(name, root, session_argv(s, resume=True),
                       chat_env(sdir) if chat else session_env(sdir), notify_ref=label)
            started.append(label)
        except SessionError as exc:
            failed.append(f"{label}: {exc}")
    return started, failed


def teardown(s: dict[str, Any]) -> list[str]:
    """tmux · 채널 · 상태 폴더 · 기록을 지운다(워크트리는 안 건드림). 채널 404 는 이미 지워진 것."""
    warnings: list[str] = []
    tmux_stop(str(s.get("tmux") or ""))
    if s.get("channelId"):
        try:
            cfg = load_config()
            Discord(read_token(cfg)).delete_channel(str(s["channelId"]))
        except DiscordError as exc:
            if exc.code != 404:
                warnings.append(f"채널 삭제 실패: {exc}")
        except Exception as exc:          # 무슨 실패든 나머지 정리는 끝까지 한다
            warnings.append(f"채널 삭제 실패: {exc}")
    if s.get("stateDir"):
        remove_state_dir(Path(str(s["stateDir"])))
    save_sessions([x for x in load_sessions()
                   if not (x.get("project") == s.get("project") and x.get("task") == s.get("task"))])
    return warnings


def _same_root(s: dict[str, Any], target: Path) -> bool:
    return bool(s.get("root")) and Path(str(s["root"])).resolve() == target


def teardown_for_root(root: Path) -> list[str]:
    """remove_worktree 가 부른다. 절대 예외를 올리지 않는다 — 워크트리 삭제를 막으면 안 된다."""
    warnings: list[str] = []
    try:
        target = Path(root).resolve()
        for s in load_sessions():
            if _same_root(s, target):
                warnings += teardown(s)
    except Exception as exc:
        warnings.append(f"세션 정리 실패: {exc}")
    return warnings


def has_live_session(root: Path) -> bool:
    """idle_verdict(데몬)가 부른다. 절대 예외를 올리지 않는다."""
    try:
        target = Path(root).resolve()
        return any(_same_root(s, target) and tmux_alive(str(s.get("tmux") or "")) for s in load_sessions())
    except Exception:
        return False


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="marina session",
                                 description="워크트리 하나 = Discord 채널 하나 = tmux 안의 claude 하나")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("new")
    p.add_argument("project")
    p.add_argument("task")
    p.add_argument("--base", default="")
    p.add_argument("--no-start", action="store_true")
    p.add_argument("--from", dest="from_id", default="", help="채팅 세션: 이어 갈 기존 대화 ID(복사본으로)")
    p.add_argument("--title", default="", help="채팅 세션: 한글 제목(채널 설명·첫 안내)")
    sub.add_parser("lobby", help="CHAT 카테고리에 #새-대화 로비를 연다")
    sub.add_parser("mcp-lobby")
    sub.add_parser("mcp-chat")
    p = sub.add_parser("ls")
    p.add_argument("--json", action="store_true")
    for name in ("attach", "stop", "rm"):
        sub.add_parser(name).add_argument("ref")
    p = sub.add_parser("start")
    p.add_argument("ref", nargs="?", default="")
    p.add_argument("--all", action="store_true")
    sub.add_parser("hook-stop")
    p = sub.add_parser("hook-chat-guard")
    p.add_argument("root")
    p.add_argument("inbox")
    p = sub.add_parser("notify-exit")
    p.add_argument("ref")
    p.add_argument("code")
    a = ap.parse_args(argv)
    if a.cmd == "hook-stop":
        try:   # 훅은 어떤 실패에도 세션을 방해하지 않는다
            hook_stop(json.loads(sys.stdin.read() or "{}"))
        except Exception:
            pass
        return 0
    if a.cmd == "mcp-lobby":
        mcp_lobby()
        return 0
    if a.cmd == "mcp-chat":
        mcp_chat()
        return 0
    if a.cmd == "hook-chat-guard":
        # 판정 실패는 거절로(첨부를 막는 쪽이 안전) — 잘못된 입력이면 exit 2 로 도구 호출을 막는다
        try:
            decision = chat_guard(Path(a.root), Path(a.inbox), json.loads(sys.stdin.read() or "{}"))
        except Exception as exc:
            print(f"첨부 확인 실패: {exc}", file=sys.stderr)
            return 2
        if decision:
            print(json.dumps(decision, ensure_ascii=False))
        return 0
    if a.cmd == "notify-exit":
        try:   # 알림 실패가 아무것도 막지 않게
            notify_exit(a.ref, a.code)
        except Exception:
            pass
        return 0
    try:
        if a.cmd == "lobby":
            if any(s.get("kind") == "chat-lobby" for s in load_sessions()):
                raise SessionError("로비가 이미 있어 ('marina session ls' 로 확인)")
            r = cmd_new_chat(LOBBY_TASK, lobby=True)
            print(f"✓ 로비: #{LOBBY_CHANNEL}")
            print(f"  Discord: {r['url']}")
            if r["warning"]:
                print("  ⚠ " + r["warning"], file=sys.stderr)
        elif a.cmd == "new":
            r = cmd_new(a.project, a.task, a.base, start=not a.no_start, from_id=a.from_id, title=a.title)
            print(f"✓ 세션: {r['project']}/{r['task']}")
            print(f"  Discord: {r['url']}")
            if r.get("kind") == "chat":
                print(f"  폴더: {r['root']}")
                if not r["warning"]:
                    print("  CHAT 카테고리는 chat 역할에게만 보여 — 여기에 들일 사람에게 Discord 에서 chat 역할만 붙이면 돼")
            else:
                print(f"  Remote Control: {r['rcName']}  (claude.ai/code · 모바일 앱)")
            print(f"  들여다보기: marina session attach {r['project']}/{r['task']}  (나오기: Ctrl-b d)")
            if r["warning"]:
                print("  ⚠ " + r["warning"], file=sys.stderr)
        elif a.cmd == "ls":
            rows = cmd_ls()
            if a.json:
                print(json.dumps(rows, ensure_ascii=False, indent=2))
            elif not rows:
                print("세션 없음")
            for s in ([] if a.json else rows):
                ch = "채널 ?" if s["channel"] is None else ("채널 있음" if s["channel"] else "채널 없음")
                print(f"{s['project']}/{s['task']}\t{'켜짐' if s['alive'] else '꺼짐'}\t{ch}\t{s['root']}")
        elif a.cmd == "attach":
            s = find_session(a.ref)
            os.execvp("tmux", _tmux_base() + ["attach", "-t", f"={s['tmux']}"])
        elif a.cmd == "start":
            if not a.all and not a.ref:
                raise SessionError("start <작업> 또는 start --all")
            started, failed = cmd_start(a.ref, a.all)
            for x in started:
                print(f"✓ 시작: {x}")
            for x in failed:
                print(f"✗ {x}", file=sys.stderr)
            return 1 if failed else 0
        elif a.cmd == "stop":
            s = find_session(a.ref)
            tmux_stop(str(s["tmux"]))
            print(f"✓ 정지: {s['project']}/{s['task']}")
        elif a.cmd == "rm":
            s = find_session(a.ref)
            for x in teardown(s):
                print("⚠ " + x, file=sys.stderr)
            kept = f"폴더는 그대로: {s['root']}" if s.get("kind") in ("chat", "chat-lobby") else "워크트리는 그대로"
            print(f"✓ 정리: {s['project']}/{s['task']} ({kept})")
    except SessionError as exc:
        print(f"marina session: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
