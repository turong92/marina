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
import tempfile
import unicodedata
import sys
import threading
import time
import urllib.error
import uuid
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

PLUGIN = "plugin:discord@claude-plugins-official"
API_DEFAULT = "https://discord.com/api/v10"
_TASK_RE = re.compile(r"[A-Za-z0-9._/-]+")
_KEEP_ENV = ("HOME", "PATH", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TMPDIR", "SSH_AUTH_SOCK")

CHANNEL_RULES = (
    "이 세션은 Discord 채널에 연결돼 있다. 상대는 Discord 만 보고 이 터미널은 보지 않는다.\n"
    "- 결과·질문·실패/막힘·완료는 반드시 discord reply 도구로 보낸다.\n"
    "- 아직 안 끝난 중간 보고(어디까지 했다·지금 무엇을 한다)는 무조건 progress 도구(message_id = 지시 메시지 ID)로 "
    "스레드에 한 줄 남긴다(알림 없음). 백그라운드 작업 알림 등 상대 메시지 없이 이어서 일할 때는 상대의 마지막 메시지 ID 를 쓴다.\n"
    "- 채널 reply 는 일이 끝났을 때(최종 결과·완료·실패) 또는 상대의 답이 필요할 때만 새로 보낸다(알림이 울리도록). 짧은 답은 progress 없이 reply 만.\n"
    "- Discord 로 '/<이름> …' 이 오면 그 이름의 스킬을 Skill 도구로 실행한다. 단 정확히 '/compact'·'/model <이름>'·'/effort <단계>' 는 "
    "마리나가 입력창에 직접 친다 — '[마리나] … 직접 실행한다' 안내가 같이 오면 그대로 두고, 안내 없이 왔으면(작업 중에 끼어든 경우) 쉬는 중에 다시 보내 달라고 답한다.\n"
    "- '[Discord 추천 버튼]' · '[Discord 슬래시]' 로 시작하는 입력은 Discord 사용자가 버튼·슬래시 명령을 쓴 것이다 — "
    "'/이름 …' 이면 그 스킬을 Skill 도구로 실행하고, 답은 Discord reply 로 한다.\n"
    "- 지시에 대한 끝 보고·답은 reply_to = 그 지시 메시지 ID 로 단다(✅ 대신 '이 지시가 끝났다'는 표시). 여러 메시지를 한 번에 처리했으면 마지막 것에.\n"
    "- 선택지가 있는 질문은 AskUserQuestion 도구로 묻는다 — Discord 에 버튼으로 뜨고 상대가 누르면 답이 들어온다.\n"
    "- 이미지는 첨부한다. HTML 은 스크린샷과 열어볼 주소를 보낸다. 10MB 를 넘는 파일은 링크로 보낸다.\n"
    "- 상대가 볼 결과물(스펙·계획·보고서 md, HTML·목업·차트, 스크린샷·이미지)을 만들거나 크게 고치면 시키지 않아도 share_file 도구에 넘긴다 — "
    "돌려받은 미리보기 파일을 reply 로 첨부하고 열어보기 주소를 reply 본문에 넣는다(폰에서 바로 열리고, 프로젝트 #자료실 에도 모인다).\n"
    "- 사람이 직접 실행해야 하는 명령(사람 확인이 박힌 래퍼 — 예 `cloud prod db --admin`)은 `!` 부탁 대신 ask_terminal 도구에 넘긴다 "
    "(Discord 에 [터미널에서 열기] 버튼이 뜨고, 상대가 열어 Enter 를 친다). 래퍼의 안전장치를 우회해 직접 붙지 않는다.\n"
    "- 터미널에서 직접 받은 지시의 답은 터미널에 둬도 된다."
)

CHAT_PROJECT = "chat"
CHAT_TOOLS = "WebSearch,WebFetch,Read,Write,Edit,Glob,Grep"
_REPLY_TOOL = "mcp__plugin_discord_discord__reply"
CHAT_RULES = (
    "이 세션은 Discord 채널에 연결된 일상 도우미다. 상대는 개발자가 아니고 Discord 만 본다.\n"
    "- 할 수 있는 일: 웹 검색·웹 페이지 읽기, 이 폴더 안에서 파일 만들기·고치기.\n"
    "- 답·질문·결과는 반드시 discord reply 도구로, 쉬운 말로 보낸다. 질문은 번호 선택지 텍스트로 묻는다.\n"
    "- 오래 걸리는 부탁은 단계마다 progress 도구(message_id = 부탁 메시지 ID)로 진행 상황을 남기고, 결과는 reply 로 보낸다.\n"
    "- 글 위주 결과(리서치·후보 비교·목록)는 파일 대신 Discord 서식 메시지로 바로 답한다: 제목은 **굵게**, "
    "목록·인용 사용. Discord 는 표를 못 그리니 표 대신 항목별 카드(이름 줄 + 들여쓴 세부 줄)로 쓴다. "
    "길면 메시지를 나눠 보낸다.\n"
    "- 배치가 중요한 결과(컨셉보드·기획안·슬라이드)만 HTML 로 만든다. CSS 는 파일 안에 넣는다. "
    "HTML·md 결과물을 만들면 시키지 않아도 share_file 도구에 넘기고, 돌려받은 미리보기 파일을 reply 의 files 로 첨부하고 "
    "열어보기 주소를 reply 본문에 넣는다 — 그 주소를 누르면 폰에서 바로 열리고 버튼·클릭도 된다.\n"
    "- 이 폴더 밖 파일은 읽거나 보낼 수 없다.\n"
    "- 상대가 보낸 첨부는 download_attachment 로 받아 읽는다.\n"
    "- 이 컴퓨터 주인의 다른 파일·설정·계정 정보는 묻더라도 다루지 않는다."
)
CHAT_LIMIT = 20
LOBBY_KINDS = ("chat-lobby", "dev-lobby")
CHAT_KINDS = ("chat",) + LOBBY_KINDS          # 제한 세션(--restricted)으로 뜨는 종류
DEV_LOBBY_CHANNEL = "새-작업"
DEV_LOBBY_TOPIC = "새 작업(워크트리+채널)을 여는 곳 — \"○○ 작업 열어줘\" 라고 말하면 돼"
DEV_LOBBY_GUIDE = (
    "🛠 **여기는 새 작업을 여는 곳이야.**\n"
    "• \"로그인 버그 고치는 작업 열어줘\" 처럼 말하면 새 워크트리와 채널을 만들고 세션을 띄워.\n"
    "• \"작업 목록 보여줘\" 라고 하면 지금 있는 작업 채널을 알려줘.\n"
    "• 서비스는 자동으로 안 켜. 작업 채널에서 `marina start` 하라고 하면 돼.\n"
    "• 결과물(스크린샷·HTML)은 #자료실 에 모여."
)
DEV_LOBBY_RULES = (
    "이 세션은 Discord 의 '새-작업' 로비다. 하는 일은 새 개발 작업(워크트리+채널) 열기와 작업 목록 알려주기뿐이다.\n"
    "- 작업을 열어 달라면 짧은 영문 소문자 이름(예: login-fix, 숫자·하이픈 가능)과 한글 제목을 정해 open_chat 을 부른다. "
    "이미 있으면 다른 이름을 고르거나 기존 채널을 알려준다.\n"
    "- 결과(채널 링크)는 discord reply 로 알린다. 그 밖의 부탁은 작업 채널에서 하라고 안내한다."
)
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

    def post_panel(self, cid: str, content: str, components: list[dict[str, Any]]) -> str:
        """버튼이 달린 메시지를 올리고 ID 를 돌려준다(고정 패널용)."""
        r = self._req("POST", f"/channels/{cid}/messages",
                      {"content": content, "components": components, "allowed_mentions": {"parse": []}})
        return str((r or {}).get("id") or "")

    def post_message(self, cid: str, content: str) -> str:
        """send_message 와 같되 메시지 ID 를 돌려준다."""
        r = self._req("POST", f"/channels/{cid}/messages", {"content": content, "allowed_mentions": {"parse": []}})
        return str((r or {}).get("id") or "")

    def pin(self, cid: str, mid: str) -> None:
        self._req("PUT", f"/channels/{cid}/pins/{mid}")

    def message_exists(self, cid: str, mid: str) -> bool:
        try:
            self._req("GET", f"/channels/{cid}/messages/{mid}")
            return True
        except DiscordError as exc:
            if exc.code == 404:
                return False
            raise


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


def tmux_leave_mode(name: str) -> None:
    """창이 tmux 보기·복사 모드면 빠져나온다 — 그 상태에선 send-keys 가 Claude 가 아니라 보기 모드로 가서
    입력·Esc 가 통째로 사라진다(실사용: run-shell 출력이 창을 보기 모드로 바꿔 이 세션만 입력이 안 먹었다)."""
    if name and _tmux("display-message", "-p", "-t", name, "#{pane_in_mode}").stdout.strip() == "1":
        _tmux("send-keys", "-t", name, "-X", "cancel")


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


def claude_argv(project: str, task: str, resume: bool = False, session_id: str = "", from_id: str = "",
                first: str = "") -> list[str]:
    """first = 첫 지시(argv 초기 프롬프트 — 부팅 중 TUI 는 타이핑을 삼킨다, 2026-09-10). 마지막 원소 하나로만 넘긴다.
    session_id 가 있으면(옮겨 온 대화) 자기 ID 로 잇는다 — 같은 워크트리의 다른 대화(--continue)를 집지 않게.
    from_id = 그 대화의 복사본으로 시작(--fork-session)."""
    argv = ["claude"]
    if session_id:
        if resume:
            argv += ["--resume", session_id]
        elif from_id:
            argv += ["--resume", from_id, "--fork-session", "--session-id", session_id]
        else:
            argv += ["--session-id", session_id]
    elif resume:
        argv.append("--continue")
    argv += ["--channels", PLUGIN,
             "--remote-control", rc_name(project, task),
             "--append-system-prompt", CHANNEL_RULES,
             "--mcp-config", str(state_dir(project, task) / "mcp.json"),   # share_file(결과물 → #자료실)
             # AskUserQuestion 은 켠다 — 질문이 채널에 버튼으로 뜬다(봇 3단계, marina_discord_ask)
             "--settings", str(state_dir(project, task) / "settings.json")]
    if first:
        argv.append(first)
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


def lobby_argv(project: str, task: str, session_id: str, resume: bool = False, dev: bool = False) -> list[str]:
    """로비: 내장 도구 없이 마리나 MCP(open_chat·list_chats)와 Discord 도구만."""
    argv = chat_argv(project, task, session_id, resume=resume)
    argv[argv.index("--tools") + 1] = ""
    argv[argv.index("--append-system-prompt") + 1] = DEV_LOBBY_RULES if dev else LOBBY_RULES
    return argv


def find_transcript(session_id: str) -> Path | None:
    root = Path(os.environ.get("MARINA_CLAUDE_PROJECTS") or "~/.claude/projects").expanduser()
    hits = list(root.glob(f"*/{session_id}.jsonl"))
    # 사본이 여럿이면(이동 잔재·백업) 가장 최근 것(리뷰 3)
    return max(hits, key=lambda p: p.stat().st_mtime) if hits else None


def conversation_home(path: Path) -> str:
    """대화를 이어받을 폴더 = 기록이 저장된 폴더 키와 같은 cwd. 대화 중 하위 폴더로 cd 하거나
    워크트리를 옮겨 다닐 수 있다 — claude 는 띄운(옮겨 간) 폴더 키 아래에 기록을 두고, --resume 은 거기서만 찾는다."""
    want = path.parent.name
    found = ""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"cwd"' not in line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                cwd = str(row.get("cwd") or "") if isinstance(row, dict) else ""
                if cwd and re.sub(r"[^A-Za-z0-9]", "-", cwd) == want:
                    found = cwd
    except OSError:
        pass
    return found

def _check_uuid(value: str) -> str:
    try:
        if str(uuid.UUID(value)) == value.lower():
            return value.lower()
    except ValueError:
        pass
    raise SessionError(f"대화 ID 형식이 아니야(UUID): {value!r}")


def session_argv(s: dict[str, Any], resume: bool = False) -> list[str]:
    if s.get("kind") in CHAT_KINDS or not s.get("sessionId"):
        return session_argv_simple(s, resume)
    return session_launch(s, resume)[1]


def session_argv_simple(s: dict[str, Any], resume: bool = False) -> list[str]:
    if s.get("kind") in CHAT_KINDS:
        sid = str(s.get("sessionId") or "")
        if not sid:
            raise SessionError("sessionId 가 없는 옛 기록이야 — rm 후 다시 만들어")
        # 아무도 말을 안 건 채 껐다 켜면 기록이 없어 --resume 이 실패한다(복사본도 첫 메시지 때 생긴다, 실측)
        # → 같은 ID 로 새로 시작하되, 옮긴 대화면 다시 복사본으로
        has = transcript_path(Path(str(s["root"])), sid).is_file()
        if s.get("kind") in LOBBY_KINDS:
            return lobby_argv(str(s["project"]), str(s["task"]), sid, resume=resume and has,
                              dev=s.get("kind") == "dev-lobby")
        return chat_argv(str(s["project"]), str(s["task"]), sid, resume=resume and has,
                         from_id="" if has else str(s.get("forkedFrom") or ""))
    return claude_argv(str(s["project"]), str(s["task"]), resume=resume)       # 보통 개발 세션: --continue


def session_launch(s: dict[str, Any], resume: bool = False) -> tuple[Path, list[str]]:
    """(띄울 폴더, 인자). 옮겨 온 개발 대화는 기록을 전역에서 찾는다 — 세션 안에서 다른 워크트리로 옮겨 가면
    기록도 그 폴더 키로 옮겨 가고 --resume 은 거기서만 찾는다(리뷰 2). 기록이 아직 없을 때만 다시 fork."""
    root = Path(str(s.get("root") or ""))
    sid = str(s.get("sessionId") or "")
    if s.get("kind") in CHAT_KINDS or not sid:
        return root, session_argv_simple(s, resume)
    tr = find_transcript(sid)
    home = conversation_home(tr) if tr else ""
    if tr and not home and tr.parent.name == re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(str(root))):
        home = str(root)                        # 기록에 cwd 줄이 아직 없어도 저장 폴더가 곧 세션 폴더
    if tr and home and Path(home).is_dir():
        return Path(home), claude_argv(str(s["project"]), str(s["task"]), resume=resume, session_id=sid)
    return root, claude_argv(str(s["project"]), str(s["task"]), resume=False, session_id=sid,
                             from_id=str(s.get("forkedFrom") or ""))


def tmux_start(name: str, cwd: Path, argv: list[str], env_extra: dict[str, str], notify_ref: str = "") -> None:
    run = list(argv)
    if notify_ref:
        # claude 가 스스로 끝나면 채널에 알린다. kill-session(stop·rm)은 셸째 죽어 알리지 않는다.
        notify = shlex.join(_hook_entry() + ["notify-exit", notify_ref])
        # 알림은 떼어 보내 셸이 바로 끝나게 한다("기동 직후 죽음"을 tmux_alive 가 놓치지 않게).
        # nohup 은 셸 종료 시 tmux 의 HUP 과 경쟁해 같이 죽었다(실측) — 부모가 먼저 HUP 를 무시하고 띄운다.
        run = ["/bin/sh", "-c", f'"$@"; code=$?; trap "" HUP; {notify} "$code" >/dev/null 2>&1 </dev/null &', "sh"] + run
    cmd = shlex.join(clean_env_prefix(env_extra) + run)
    r = _tmux("new-session", "-d", "-s", name, "-x", "200", "-y", "50", "-c", str(cwd), cmd)
    if r.returncode != 0:
        raise SessionError(f"tmux 실행 실패: {(r.stderr or r.stdout).strip()}")
    dashboard_signal()
    time.sleep(float(os.environ.get("MARINA_SESSION_BOOT_WAIT") or 2.0))
    if not tmux_alive(name):
        raise SessionError(f"claude 가 바로 꺼졌어 — 직접 확인: cd {shlex.quote(str(cwd))} && claude --channels {PLUGIN}")

def tmux_stop(name: str) -> None:
    if tmux_alive(name):
        _tmux("kill-session", "-t", f"={name}")
        dashboard_signal()


# ── 상태 폴더 · 마리나 실행 계층 ─────────────────────────────────────────────

def write_state_dir(path: Path, channel_id: str, allow: list[str], token_path: Path) -> None:
    """채널 플러그인의 DISCORD_STATE_DIR. 토큰은 복사하지 않고 심링크 — 기본 폴더에 토큰을 두면
    열린 모든 Claude 세션이 같은 봇으로 접속한다(실측 2026-10-01)."""
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    # 최상위 allowFrom = DM 허용 목록. 같은 봇을 쓰는 모든 세션이 DM 을 동시에 받으므로 비운다(최종 리뷰 I1).
    access = {"dmPolicy": "allowlist", "allowFrom": [],
              "groups": {channel_id: {"requireMention": False, "allowFrom": list(allow)}},
              "replyToMode": "first"}    # 도착 👀(ackReaction)는 끈다 — 실제로 받으면 훅이 단다
    (path / "access.json").write_text(json.dumps(access, ensure_ascii=False) + "\n", encoding="utf-8")
    env = path / ".env"
    if env.is_symlink() or env.exists():
        env.unlink()
    env.symlink_to(token_path)


def remove_state_dir(path: Path) -> None:
    shutil.rmtree(path, ignore_errors=True)


_CHANNEL_TAG = re.compile(r'<channel source=\\?"plugin:discord:discord\\?" chat_id=\\?"(\d+)\\?" message_id=\\?"([^"\\]+)')


SLASH_ALLOWED = ("/compact",)
_SLASH_ARG = re.compile(r"/(model|effort) [A-Za-z0-9._\[\]-]{1,40}")   # 인자 한 단어 필수(없으면 선택 창이 떠 막힌다)


def slash_emoji(cmd: str) -> str:
    return "🗜️" if cmd == "/compact" else "⚙️"


def slash_allowed(cmd: str) -> bool:
    """입력창에 직접 칠 수 있는 명령. /clear 류는 막는다. 스킬(/이름)은 Claude 가 Skill 도구로 — 여기 없다."""
    return cmd in SLASH_ALLOWED or bool(_SLASH_ARG.fullmatch(cmd))
_CHANNEL_MSG = re.compile(r'<channel source=\\?"plugin:discord:discord\\?" chat_id=\\?"(\d+)\\?" message_id=\\?"([^"\\]+)[^>]*>(.*?)</channel>', re.S)


def slash_command(prompt: str, channel: str | None = None) -> "tuple[str, str] | None":
    """Discord 로 온 메시지가 정확히 허용된 명령(/compact)이면 (메시지 ID, 명령). 글자로 와서 Claude 는 실행할 수 없다."""
    hits = [m for m in _CHANNEL_MSG.finditer(prompt or "") if channel is None or m.group(1) == channel]
    if not hits:
        return None
    body = hits[-1].group(3).strip()
    return (hits[-1].group(2), body) if slash_allowed(body) else None


def _session_from_env() -> "dict[str, Any] | None":
    sdir = os.environ.get("DISCORD_STATE_DIR") or ""
    s = next((x for x in load_sessions() if sdir and x.get("stateDir") == sdir), None)
    return s if s and s.get("channelId") else None


def hook_reply_to(payload: dict[str, Any]) -> "dict[str, Any] | None":
    """답장 도구에 reply_to 가 빠졌으면 그 턴에 받은 마지막 지시 메시지로 채운다 — 답장이 곧 끝 표시(✅ 없음).
    규칙 문구만으론 Claude 가 잊는다(실사용) — 훅이 기계적으로."""
    s = _session_from_env()
    inp = payload.get("tool_input") or {}
    if not s or s.get("kind") in CHAT_KINDS or payload.get("tool_name") != _REPLY_TOOL or not isinstance(inp, dict):
        return None
    if inp.get("reply_to") or str(inp.get("chat_id") or "") != str(s["channelId"]):
        return None
    ids = inbound_messages(Path(str(payload.get("transcript_path") or "/nonexistent")), str(s["channelId"]))
    if not ids:
        return None
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
                                   "updatedInput": dict(inp, reply_to=ids[-1])}}


def clear_suggest(sd: Path, ch: str, dc: "Discord") -> None:
    """[▶ 추천] 버튼 떼기 — 다음 지시가 오면 바로(늦게 바뀌는 표시 금지)."""
    try:
        (sd / "suggest-cleared-at").write_text(f"{time.time()}\n")   # 늦게 끝나는 추천 대기자가 보고 물러난다(리뷰 I4)
    except OSError:
        pass
    f = sd / "suggest.json"
    try:
        sug = json.loads(f.read_text(encoding="utf-8"))
        f.unlink()
    except (OSError, ValueError):
        return
    try:
        dc._req("PATCH", f"/channels/{ch}/messages/{sug.get('msg')}", {"components": []})
    except SessionError:
        pass


_SENT_IDS = re.compile(r"sent (?:\d+ parts )?\(ids?: ([\d, ]+)\)")


def last_reply_id(transcript: Path) -> str:
    """이번 턴(마지막 지시 이후)에 답장 도구가 보낸 마지막 메시지 ID. 여러 조각이면 마지막 조각(리뷰 I6)."""
    try:
        lines = transcript.read_bytes()[-1_000_000:].decode("utf-8", "replace").splitlines()
    except OSError:
        return ""
    reply_uses: set[str] = set()
    last = ""
    for raw in lines:
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        content = (row.get("message") or {}).get("content") if isinstance(row, dict) else None
        if row.get("type") == "user" and (isinstance(content, str) or (isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "text" for b in content))):
            last = ""                                   # 새 지시 = 새 턴
        if not isinstance(content, list):
            continue
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "tool_use" and b.get("name") == _REPLY_TOOL:
                reply_uses.add(str(b.get("id")))
            elif b.get("type") == "tool_result" and str(b.get("tool_use_id")) in reply_uses:
                for t in ([b["content"]] if isinstance(b.get("content"), str) else
                          [str(x.get("text") or "") for x in b.get("content") or [] if isinstance(x, dict)]):
                    m = _SENT_IDS.search(t)
                    if m:
                        last = [x.strip() for x in m.group(1).split(",") if x.strip()][-1]
    return last


def _spawn_suggest(tmux: str, ch: str, msg: str) -> None:
    bot = Path(__file__).resolve().with_name("marina_discord_bot.py")
    subprocess.Popen([sys.executable, str(bot), "suggest", tmux, ch, msg, str(time.time())],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


PERM_WAIT = 300.0


def _turn_from_terminal(transcript: Path, ch: str) -> bool:
    """이번 턴을 연 입력이 터미널에서 직접 친 말인가(Discord 메시지·백그라운드 알림이 아님) — 그땐 터미널 권한 창이 맞다."""
    try:
        lines = transcript.read_bytes()[-1_000_000:].decode("utf-8", "replace").splitlines()
    except OSError:
        return False
    for raw in reversed(lines):
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(row, dict) or row.get("type") != "user":
            continue
        c = (row.get("message") or {}).get("content")
        texts = [c] if isinstance(c, str) else [str(b.get("text") or "") for b in c or []
                                                if isinstance(b, dict) and b.get("type") == "text"]
        if not texts:
            continue                     # 도구 결과 — 더 위로
        t = "\n".join(texts)
        return not any(m.group(1) == ch for m in _CHANNEL_TAG.finditer(t)) and "<task-notification>" not in t
    return False


def hook_permission(payload: dict[str, Any], wait: float = PERM_WAIT, poll: float = 1.0) -> "dict[str, Any] | None":
    """권한 창 대신 채널에 [허용][거부]. 누를 때까지 기다린다(그동안 터미널 창은 숨겨짐 — 하네스 문서). 시간이 지나면 결정 없이
    돌려줘 원래 권한 창으로. 명령 원문은 안 보낸다(도구 이름·설명만). AskUserQuestion 은 질문 버튼이,
    ExitPlanMode 는 계획을 봐야 하니 터미널이 맡는다. 터미널에서 직접 친 지시도 터미널 창으로(리뷰 I7)."""
    start = time.time()
    s = _session_from_env()
    tool = str(payload.get("tool_name") or "")
    if not s or s.get("kind") in CHAT_KINDS or tool in ("AskUserQuestion", "ExitPlanMode", ""):
        return None
    sd, ch = Path(str(s["stateDir"])), str(s["channelId"])
    if _turn_from_terminal(Path(str(payload.get("transcript_path") or "/nonexistent")), ch):
        return None
    _, label, what = tool_activity(tool, payload.get("tool_input") or {})
    token = uuid.uuid4().hex[:12]
    f, ans = sd / f"perm-{token}.json", sd / f"perm-{token}.answer"
    text = (f"🔐 **권한 요청** — `{tool}` {label}" + (f": {what}" if what else "")
            + f"\n-# {int(wait // 60) or 1}분 안에 안 누르면 터미널 권한 창으로 넘어가")
    dc = Discord(read_token(load_config()))
    _write_json(f, {"token": token, "msg": ""})      # 버튼보다 먼저 — 빨리 눌러도 '없는 요청'이 안 되게(리뷰 I3)
    msg, answer = "", ""
    import signal
    def _bye(*_: Any) -> None:
        raise SystemExit(0)
    try:
        signal.signal(signal.SIGTERM, _bye)          # 하네스가 훅을 끊어도 버튼·기록은 정리(리뷰 I2)
    except ValueError:
        pass                                          # 메인 스레드가 아니면(테스트) 생략
    try:
        try:
            msg = str(dc._req("POST", f"/channels/{ch}/messages", {
                "content": text, "allowed_mentions": {"parse": []},
                "components": [{"type": 1, "components": [
                    {"type": 2, "style": 3, "label": "허용", "custom_id": f"mperm:a:{ch}:{token}"},
                    {"type": 2, "style": 4, "label": "거부", "custom_id": f"mperm:d:{ch}:{token}"}]}]}).get("id") or "")
        except SessionError:
            return None
        _write_json(f, {"token": token, "msg": msg})
        end = start + wait                            # 훅 시작부터 — 느린 Discord 때문에 훅 제한을 넘지 않게(리뷰 I4)
        while time.time() < end:
            try:
                answer = ans.read_text().strip()
            except OSError:
                answer = ""
            if answer:
                break
            time.sleep(poll)
    finally:
        for x in (f, ans):
            try:
                x.unlink()
            except OSError:
                pass
        if msg:
            note = {"allow": "✅ 허용함", "deny": "⛔ 거부함"}.get(answer, "⌛ 넘어감 — 터미널에서 결정")
            try:
                dc._req("PATCH", f"/channels/{ch}/messages/{msg}", {"content": text.split("\n")[0] + f"\n-# {note}", "components": []})
            except SessionError:
                pass
    if answer == "allow":
        return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}
    if answer == "deny":
        return {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                       "decision": {"behavior": "deny", "message": "Discord 에서 거부함"}}}
    return None


def hook_question(payload: dict[str, Any]) -> None:
    """AskUserQuestion 이 뜨는 순간: 채널에 질문 메시지(떼어 낸 프로세스가 올린다 — 질문 창을 막지 않게)."""
    s = _session_from_env()
    if not s or s.get("kind") in CHAT_KINDS or payload.get("tool_name") != "AskUserQuestion":
        return
    ask = Path(__file__).resolve().with_name("marina_discord_ask.py")
    p = subprocess.Popen([sys.executable, str(ask), "post", str(s["stateDir"]), str(s["channelId"]), str(time.time())],
                         stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    p.stdin.write(json.dumps(payload.get("tool_input") or {}).encode())
    p.stdin.close()


def hook_question_done(payload: dict[str, Any]) -> None:
    s = _session_from_env()
    if not s or payload.get("tool_name") != "AskUserQuestion":
        return
    _spawn_question_done(str(s["stateDir"]), str(s["channelId"]))     # 떼어 낸다 — Discord 왕복에 Claude 를 붙잡지 않게(리뷰 I7)


def _spawn_question_done(sdir: str, ch: str) -> None:
    ask = Path(__file__).resolve().with_name("marina_discord_ask.py")
    subprocess.Popen([sys.executable, str(ask), "done", sdir, ch],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def _spawn_slash(tmux: str, cmd: str, mid: str) -> None:
    s = _session_from_env() or {}
    bot = Path(__file__).resolve().with_name("marina_discord_bot.py")
    subprocess.Popen([sys.executable, str(bot), "slash", tmux, cmd, str(s.get("channelId") or ""), mid],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


RESUME_TEXT = ("[마리나] 재시작 전에 받은 Discord 메시지에 답하지 못하고 끊겼어. "
               "바로 위 그 메시지에 이어서 답하고, 답은 Discord reply 로 보내 줘.")


def unanswered(transcript: Path) -> bool:
    """기록이 'Discord 로 받은 지시 → (답장 도구 없이) 끝' 으로 끝났나 — 재시작으로 턴이 끊긴 흔적."""
    try:
        lines = transcript.read_bytes()[-1_000_000:].decode("utf-8", "replace").splitlines()
    except OSError:
        return False
    pending = False
    for raw in lines:
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        c = (row.get("message") or {}).get("content") if isinstance(row, dict) else None
        if row.get("type") == "user":
            texts = [c] if isinstance(c, str) else [str(b.get("text") or "") for b in c or []
                                                    if isinstance(b, dict) and b.get("type") == "text"]
            if texts:
                pending = bool(_CHANNEL_TAG.search("\n".join(texts)))
        elif row.get("type") == "assistant" and isinstance(c, list):
            if any(isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == _REPLY_TOOL for b in c):
                pending = False
    return pending


def resume_unanswered(rec: dict[str, Any]) -> None:
    """턴 도중(받은 순간 뒤·턴 끝 전)에 끊긴 지 1시간 안이고, 기록이 답장 없이 끝났을 때만 이어받기를 건다(리뷰 I2).
    한 번 걸면 10분 안엔 다시 안 건다 — 연달아 재시작해도 두 번 입력되지 않게(리뷰 I3)."""
    sd = Path(str(rec.get("stateDir") or "/nonexistent"))
    def num(name: str) -> float:
        try:
            return float((sd / name).read_text())
        except (OSError, ValueError):
            return 0.0
    turn = num("turn-at")
    if not (turn > num("stopped-at") and time.time() - turn < 3600) or time.time() - num("resume-at") < 600:
        return
    sid = str(rec.get("sessionId") or "")
    tr = find_transcript(sid) if sid else None
    if not tr or not unanswered(tr) or not rec.get("tmux"):
        return
    (sd / "resume-at").write_text(f"{time.time()}\n")
    import marina_discord_bot as mb
    mb._spawn_type(str(rec["tmux"]), RESUME_TEXT, str(rec.get("channelId") or ""), "")


def hook_prompt(payload: dict[str, Any]) -> "dict[str, Any] | None":
    """받은 순간: Discord 로 온 '/compact' 는 마리나가 세션이 쉬는 순간 입력창에 직접 친다. Claude 에겐 짧게 답만 하라고."""
    _ensure_daemon_quiet()          # 지시를 받는 순간 봇이 있어야 🛑·typing 이 된다(리뷰 I3)
    s = _session_from_env()
    if s and s.get("stateDir"):                   # 턴 시작 — 안전 재시작은 턴 끝(stopped-at)까지 기다린다
        try:
            (Path(str(s["stateDir"])) / "turn-at").write_text(f"{time.time()}\n")
        except OSError:
            pass
    if not s or s.get("kind") in CHAT_KINDS:      # 채팅방(여자친구)엔 세션 명령을 열지 않는다
        return None
    hit = slash_command(str(payload.get("prompt") or ""), str(s["channelId"]))
    if not hit:
        return None
    mid, cmd = hit
    _spawn_slash(str(s.get("tmux") or ""), cmd, mid)      # 먼저 — 반응은 대기자가 단다(훅 시간 초과에 안 묶이게, 리뷰 I5)
    return {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext":
            f"[마리나] 이 {cmd} 는 마리나가 이번 턴이 끝나는 대로 입력창에 직접 실행한다. "
            f"진행 표시(🗜️·⚙️ → ✅)도 마리나가 하니 답장도 도구도 쓰지 말고 바로 턴을 끝내라."}}


def _drop_ack_reaction(path: Path) -> None:
    """예전에 만든 상태 폴더: 도착 👀 를 끈다(실제로 받은 것만 표시, 형 결정)."""
    try:
        acc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return
    if isinstance(acc, dict) and acc.pop("ackReaction", None) is not None:
        path.write_text(json.dumps(acc, ensure_ascii=False) + "\n", encoding="utf-8")


_PLUGIN_KEYS = ("marina-discord@", "marina@")    # 분리 D: discord 는 자기 플러그인(marina-discord), 옛 설치(marina)도 허용


def _hook_entry() -> list[str]:
    """세션이 부를 마리나 명령의 머리. 계약: hook-* 하위명령 이름·인자는 하위 호환으로만 바꾼다 — 떠 있는 세션의 옛 설정이
    새 코드를 부른다(리뷰 I7). 설치본에서 돌면 고정 입구(~/.marina/bin/marina-session-hook) — 입구가 부를 때마다
    설치 목록에서 지금 깔린 마리나를 찾으므로 새 버전을 깔면 떠 있는 세션도 재시작 없이 새 코드를 쓴다(형 요청: 재시작 걱정 줄이기).
    설치본이 아닌 곳(작업 트리·테스트)에서 돌면 예전처럼 직접 경로."""
    me = Path(__file__).resolve()
    home = Path(os.environ.get("MARINA_CLAUDE_HOME") or Path.home() / ".claude")
    plist = home / "plugins" / "installed_plugins.json"
    try:
        plugins = json.loads(plist.read_text(encoding="utf-8")).get("plugins") or {}
    except (OSError, ValueError, AttributeError):
        plugins = {}
    key = ""
    for k, entries in plugins.items():
        for e in entries if isinstance(entries, list) else []:
            ip = Path(str(e.get("installPath") or "/nonexistent")).resolve() if isinstance(e, dict) else None
            if str(k).startswith(_PLUGIN_KEYS) and ip and str(me).startswith(str(ip) + os.sep):
                key = str(k)
    if not key:
        return [sys.executable, str(me)]
    shim = marina_home() / "bin" / "marina-session-hook"
    body = f"""#!/bin/sh
# 마리나 세션 훅 입구 — 부를 때마다 설치 목록에서 지금 깔린 마리나를 찾아 실행한다(새 버전 = 재시작 없이 적용).
# 파이썬은 쓴 프로세스 것이 아니라 흔한 고정 경로부터(세션마다 다른 venv 가 공유 입구를 바꾸지 않게, 리뷰 I5)
PY=""
for c in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 {shlex.quote(sys.executable)}; do
  [ -x "$c" ] && PY="$c" && break
done
# 같은 이름 설치가 여럿이면 user 범위·가장 최근 것(리뷰 I6). 키는 marina-discord@ → marina@ 순으로, 파일이 있는 첫 설치본
# (분리 D: marina 를 먼저 업데이트하면 새 marina@ 엔 이 파일이 없다 — 키 하나에 묶이면 옛 코드로 되돌아간다)
target=$("$PY" -c 'import json,os,sys
try:
    d=json.load(open(sys.argv[1]))["plugins"]
    for pre in ("marina-discord@", "marina@"):
        for k in [k for k in d if k.startswith(pre)]:
            es=[e for e in d[k] if isinstance(e, dict)]
            es.sort(key=lambda e: (e.get("scope") == "user", str(e.get("lastUpdated") or "")), reverse=True)
            for e in es[:1]:
                f=os.path.join(e["installPath"], "scripts", "marina_session.py")
                if os.path.isfile(f):
                    print(f); sys.exit(0)
except Exception:
    pass' {shlex.quote(str(plist))} 2>/dev/null)
[ -n "$target" ] || target={shlex.quote(str(me))}
if [ -n "${{MARINA_SHIM_WHICH:-}}" ]; then echo "$target"; exit 0; fi
exec "$PY" "$target" "$@"
"""
    try:
        shim.parent.mkdir(parents=True, exist_ok=True)
        if not shim.is_file() or shim.read_text() != body:
            tmp = shim.with_name(f"{shim.name}.{os.getpid()}.tmp")
            tmp.write_text(body)
            os.chmod(tmp, 0o755)
            os.replace(tmp, shim)
    except OSError:
        return [sys.executable, str(me)]
    return [str(shim)]


def write_settings(sdir: Path, chat_root: Path | None = None, lobby: bool = False) -> Path:
    """채널 세션 전용 설정(--settings). 사용자 설정과 합쳐진다.
    Stop 훅 = 턴이 끝나면 진행 표시를 뗀다. enabledPlugins = 사용자 범위에서 플러그인을 꺼도 이 세션에서만 켜지게."""
    # 버전 캐시 경로가 지워지면 exit 2 가 claude 종료를 막는다 → 실패해도 0(최종 리뷰 I2). start 가 다시 쓴다.
    cmd = shlex.join(_hook_entry() + ["hook-stop"]) + " || true"
    settings = {"enabledPlugins": {"discord@claude-plugins-official": True},
                "hooks": {"Stop": [{"hooks": [{"type": "command", "command": cmd, "timeout": 15}]}]}}
    if chat_root is not None:
        # 플러그인은 첨부 경로에서 자기 상태 폴더만 막는다 — 폴더 밖 파일은 훅으로 막는다(실측).
        guard = shlex.join(_hook_entry() + ["hook-chat-guard",
                            str(chat_root), str(sdir / "inbox")])
        # 판정기가 어떤 이유로든 죽으면(파이썬 경로 바뀜 등) exit 2 = 도구 호출을 막는다(리뷰 I1)
        guard += " || exit 2"
        real = os.path.realpath(str(chat_root))
        settings["permissions"] = {
            "allow": ["Read", "Glob", "Grep", "Write", "Edit", "WebSearch", "WebFetch"]
                     + [f"mcp__plugin_discord_discord__{t}" for t in
                        ("reply", "react", "edit_message", "fetch_messages", "download_attachment")]
                     + (["mcp__marina__open_chat", "mcp__marina__list_chats"] if lobby else ["mcp__marina__share_file", "mcp__marina__progress"]),
            # 다음 기동 때 실행될 수 있는 폴더 안 설정 파일은 못 쓰게(리뷰 I2). '//' = 절대 경로
            "deny": [f"Edit(/{real}/{f})" for f in (".mcp.json", ".claude/**", "CLAUDE.md", "CLAUDE.local.md")]}
        settings["hooks"]["PreToolUse"] = [{"matcher": f"{_REPLY_TOOL}|WebFetch|Write|Edit",
                                            "hooks": [{"type": "command", "command": guard, "timeout": 15}]}]
    # 작업 중 표시: 도구를 쓸 때마다 채널에 '입력 중…'(8초에 한 번) — 👀 만으론 진행 여부를 알 수 없다(형 요청)
    typing = shlex.join(_hook_entry() + ["hook-typing"]) + " || true"
    settings["hooks"].setdefault("PreToolUse", []).append(       # 첨부 가드(있으면) 뒤에 붙인다 — 가드를 덮지 않게
        {"matcher": "*", "hooks": [{"type": "command", "command": typing, "timeout": 10}]})
    # 받은 순간 👀 — 플러그인은 도착만 해도 👀 를 달아 안 읽은 걸 읽은 것처럼 보였다(형 결정: 실제로 받은 것만)
    prompt_hook = shlex.join(_hook_entry() + ["hook-prompt"]) + " || true"
    settings["hooks"]["UserPromptSubmit"] = [{"hooks": [{"type": "command", "command": typing, "timeout": 10},
                                                        {"type": "command", "command": prompt_hook, "timeout": 10}]}]
    if chat_root is None:
        # 질문 버튼(봇 3단계): 질문이 뜨면 채널에 올리고, 어디서든 답하면 정리한다. 떼어 내서 질문 창을 막지 않는다
        q_hook = shlex.join(_hook_entry() + ["hook-question"]) + " || true"
        qd_hook = shlex.join(_hook_entry() + ["hook-question-done"]) + " || true"
        settings["hooks"]["PreToolUse"].append({"matcher": "AskUserQuestion",
                                                "hooks": [{"type": "command", "command": q_hook, "timeout": 10}]})
        settings["hooks"]["PostToolUse"] = [{"matcher": "AskUserQuestion",
                                             "hooks": [{"type": "command", "command": qd_hook, "timeout": 15}]}]
        # 권한 승인 버튼(봇 4): 채널에서 누를 때까지 기다린다 — 훅 제한은 기다림보다 넉넉히
        p_hook = shlex.join(_hook_entry() + ["hook-permission"]) + " || true"
        settings["hooks"]["PermissionRequest"] = [{"hooks": [{"type": "command", "command": p_hook,
                                                              "timeout": int(PERM_WAIT) + 30}]}]
    # 답장 = 끝 표시: reply_to 가 빠지면 훅이 채운다(규칙만으론 잊는다, 실사용)
    reply_hook = shlex.join(_hook_entry() + ["hook-reply-to"]) + " || true"
    settings["hooks"]["PreToolUse"].append({"matcher": _REPLY_TOOL,
                                            "hooks": [{"type": "command", "command": reply_hook, "timeout": 10}]})
    if chat_root is None:
        # 개발 세션: share_file 만 더한다(권한 모드는 형 설정 그대로 — 이 도구만 허용 목록에)
        settings["permissions"] = {"allow": ["mcp__marina__share_file", "mcp__marina__progress", "mcp__marina__ask_terminal"]}
        entry = _hook_entry()
        mcp = {"mcpServers": {"marina": {"command": entry[0], "args": entry[1:] + ["mcp-chat"]}}}
        (sdir / "mcp.json").write_text(json.dumps(mcp, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if chat_root is not None:
        entry = _hook_entry()
        mcp = {"mcpServers": {"marina": {"command": entry[0], "args": entry[1:] + ["mcp-lobby" if lobby else "mcp-chat"]}}}
        (sdir / "mcp.json").write_text(json.dumps(mcp, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    f = sdir / "settings.json"
    f.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return f


_CHAT_CONFIG_NAMES = (".mcp.json", "claude.md", "claude.local.md")
_VIEW_SUFFIXES = (".html", ".htm", ".md", ".markdown", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".pdf")   # 폰 브라우저가 여는 결과물


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


def inbound_messages(transcript: Path, channel_id: str) -> list[str]:
    """세션 기록 끝 2MB 에서 Claude 가 **실제로 읽은** 이 채널 메시지 ID 들(순서대로, 중복 제거).
    읽은 것 = user 기록(턴을 연 메시지) · attachment queued_command(처리 중 끼어든 메시지).
    queue-operation(도착만 함, 아직 안 읽음)은 세지 않는다 — 안 읽은 메시지를 읽은 것으로 표시하지 않게(실측 2026-10-01)."""
    try:
        data = transcript.read_bytes()[-2_000_000:].decode("utf-8", "replace")
    except OSError:
        return []
    out: list[str] = []
    for raw in data.splitlines():
        try:
            row = json.loads(raw)
        except ValueError:
            continue                                     # 2MB 경계에서 잘린 첫 줄 등
        if not isinstance(row, dict):
            continue
        texts: list[str] = []
        if row.get("type") == "user":
            content = (row.get("message") or {}).get("content")
            if isinstance(content, str):
                texts.append(content)
            elif isinstance(content, list):
                texts += [str(b.get("text") or "") for b in content if isinstance(b, dict)]
        elif row.get("type") == "attachment":
            att = row.get("attachment") or {}
            if isinstance(att, dict) and att.get("type") == "queued_command":
                texts.append(str(att.get("prompt") or ""))
        for text in texts:
            for m in _CHANNEL_TAG.finditer(text):
                if m.group(1) == channel_id and m.group(2) not in out:
                    out.append(m.group(2))
    return out

def _hook_target(payload: dict[str, Any], items: list[dict[str, Any]]) -> dict[str, Any] | None:
    """상태 폴더로 찾고, 없으면 cwd 로 짐작 — 채팅 세션은 모두 같은 폴더라 짐작하지 않는다."""
    sdir = os.environ.get("DISCORD_STATE_DIR") or ""
    root = Path(str(payload.get("cwd") or "/nonexistent")).resolve()
    return next((x for x in items if sdir and x.get("stateDir") == sdir), None) \
        or next((x for x in items if x.get("kind") not in CHAT_KINDS and _same_root(x, root)), None)


def daemon_pid_path() -> Path:
    return marina_home() / "discord-daemon.pid"


_DAEMON_ENV_KEEP = ("HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL", "SSH_AUTH_SOCK")


def daemon_path() -> str:
    """데몬(과 그가 띄우는 것)이 쓰는 PATH — claude(~/.local/bin)·tmux·git(homebrew)을 찾게."""
    return ":".join([str(Path.home() / ".local" / "bin"), "/opt/homebrew/bin", "/usr/local/bin",
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin"])


def _daemon_env() -> dict[str, str]:
    """데몬 환경 — 처음 깨운 세션의 것을 물려받지 않는다(DISCORD_STATE_DIR·CLAUDECODE·세션 PATH, 리뷰 I2)."""
    env = {k: v for k, v in os.environ.items() if k in _DAEMON_ENV_KEEP or k.startswith(("LC_", "MARINA_"))}
    env["PATH"] = daemon_path()
    env["MARINA_HOME"] = str(marina_home())
    env["PYTHONUNBUFFERED"] = "1"
    return env


def _spawn_daemon(entry: "list[str] | None" = None) -> int:
    log_path = marina_home() / "discord-daemon.log"
    try:
        if log_path.stat().st_size > 1 << 20:        # 1MB 넘으면 새로(리뷰 M7)
            log_path.unlink()
    except OSError:
        pass
    log = open(log_path, "a")
    # cwd 를 홈으로 — 세션 워크트리를 cwd 로 물면 그 워크트리가 지워진 뒤 고아 리퍼가 데몬을 죽인다(리뷰 I2)
    proc = subprocess.Popen([*(entry or _hook_entry()), "daemon"], stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                            start_new_session=True, cwd=str(marina_home()), env=_daemon_env())
    return proc.pid


def _is_daemon_cmd(cmd: str) -> bool:
    """`… marina_session.py daemon` 또는 `… marina-session-hook daemon` 으로 끝나는 프로세스만(리뷰 M1)."""
    parts = cmd.split()
    return bool(parts) and parts[-1] == "daemon" and any(
        p.endswith("marina_session.py") or p.endswith("marina-session-hook") for p in parts[:-1])


def _daemon_alive() -> bool:
    try:
        pid = int(daemon_pid_path().read_text().strip())
        os.kill(pid, 0)
    except (OSError, ValueError):
        return False
    try:
        cmd = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True, timeout=2).stdout
    except subprocess.SubprocessError:
        return True                               # 확인 못 하면 띄우지 않는다(중복보다 낫다)
    return _is_daemon_cmd(cmd.strip())


def ensure_daemon(entry: "list[str] | None" = None) -> str:
    """discord 봇(#상태·🛑·숫자판·typing·bun 봇)을 discord 가 스스로 띄운다(분리 B — 대시보드가 안 띄운다).
    떠 있으면 그대로, 없을 때만 하나. 훅마다 불리므로 싸야 한다. 동시에 여러 훅이 불러도 하나만(잠금, 리뷰 I1)."""
    if os.environ.get("MARINA_DISCORD_DAEMON") == "off":
        return "off"
    if _daemon_alive():
        return "running"
    import fcntl
    try:
        marina_home().mkdir(parents=True, exist_ok=True)
        lk = open(marina_home() / "discord-daemon.spawn.lock", "w")
        fcntl.flock(lk, fcntl.LOCK_EX)
    except OSError:
        return "running"
    try:
        if _daemon_alive():
            return "running"
        pid = _spawn_daemon(entry) if entry else _spawn_daemon()
        daemon_pid_path().write_text(f"{pid}\n")
        return "started"
    finally:
        lk.close()


def _code_updated(me: "Path | None" = None, home: "Path | None" = None) -> bool:
    return _newest_scripts(me, home) is not None


def _newest_scripts(me: "Path | None" = None, home: "Path | None" = None) -> "Path | None":
    """설치본으로 도는데 설치 목록의 최신이 이 파일이 아니면 참(업데이트됨) — 데몬이 스스로 끝나고 다음 훅이 새 코드로.
    업데이트하면 installPath 가 새 해시로 바뀌고 옛 캐시는 남으므로 '설치본인가'는 캐시 폴더 아래인지로 본다(리뷰 C1).
    최신 고르기는 셸 입구(shim)와 같은 규칙: user 범위·lastUpdated 최신."""
    me = (me or Path(__file__)).resolve()
    home = home or Path(os.environ.get("MARINA_CLAUDE_HOME") or Path.home() / ".claude")
    try:
        me.relative_to((home / "plugins" / "cache").resolve())
    except ValueError:
        return None                              # 작업 트리·테스트
    try:
        data = json.loads((home / "plugins" / "installed_plugins.json").read_text(encoding="utf-8")).get("plugins") or {}
    except (OSError, ValueError, AttributeError):
        return None
    # 이 파일이 깔린 플러그인(분리 D 이후 marina-discord@, 그 전엔 marina@)에서만 최신을 고른다
    key = next((k for k in data if str(k).startswith("marina-discord@")), None) or \
        next((k for k in data if str(k).startswith("marina@")), None)
    es = [e for e in (data.get(key) or []) if isinstance(e, dict)] if key else []
    es.sort(key=lambda e: (e.get("scope") == "user", str(e.get("lastUpdated") or "")), reverse=True)
    if not es:
        return None
    latest = Path(str(es[0].get("installPath") or "")) / "scripts" / "marina_session.py"
    return latest.parent if latest.exists() and latest.resolve() != me else None


UPDATE_EVERY_S = 3600.0
_DISCORD_PLUGIN = "marina-discord@marina-dev"
_PREFLIGHT_MODULES = ("marina_session", "marina_discord_bot", "marina_discord_ask", "marina_share", "marina_discord_usage")


def _claude_home() -> Path:
    return Path(os.environ.get("MARINA_CLAUDE_HOME") or Path.home() / ".claude")


def _marketplace_scripts() -> Path:
    return _claude_home() / "plugins" / "marketplaces" / "marina-dev" / "plugin-discord" / "scripts"


def _run_claude(argv: list[str]) -> tuple[int, str]:
    exe = shutil.which("claude") or str(Path.home() / ".local" / "bin" / "claude")
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    try:
        r = subprocess.run([exe, *argv[1:]], capture_output=True, text=True, timeout=300, env=env)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except (OSError, subprocess.SubprocessError) as exc:
        return 1, str(exc)


def _preflight(scripts: Path) -> tuple[bool, str]:
    """새 코드가 데몬 파이썬(sys.executable)으로 import 되는지 — 격리 홈에서. 깨진 버전을 깔지 않는다(3.9 사고 교훈)."""
    import tempfile
    code = "import sys; sys.path.insert(0, sys.argv[1])\n" + "".join(f"import {m}\n" for m in _PREFLIGHT_MODULES)
    with tempfile.TemporaryDirectory() as tmp:
        try:
            r = subprocess.run([sys.executable, "-c", code, str(scripts)], capture_output=True, text=True, timeout=60,
                               env={"HOME": tmp, "MARINA_HOME": tmp, "PATH": "/usr/bin:/bin"})
        except (OSError, subprocess.SubprocessError) as exc:
            return False, str(exc)
    return r.returncode == 0, (r.stderr or "")[-400:]


def _marketplace_sha() -> str:
    r = subprocess.run(["git", "-C", str(_marketplace_scripts().parent.parent), "rev-parse", "HEAD"],
                       capture_output=True, text=True, timeout=10)
    return r.stdout.strip()


def self_update_tick(now: float, installed: "bool | None" = None, run=None, preflight=None, new_sha=None) -> str:
    """discord 자동 업데이트(형 결정 2026-10-03: discord 도 자동) — marina 강제 업데이트는 marina@ 만 갱신하므로 스스로.
    한 시간마다: 마켓플레이스 갱신 → 새 코드 import 사전 검사 → plugin update. 깔고 나면 _code_updated 가 데몬을 교체한다.
    실패한 버전(sha)은 기록해 다시 시도하지 않는다. MARINA_AUTO_UPDATE=0 이면 끔(marina 와 같은 스위치)."""
    if str(os.environ.get("MARINA_AUTO_UPDATE", "1")).strip().lower() in ("0", "off", "false", "no"):
        return "off"                                 # marina enabled() 와 같은 값(리뷰 I3)
    if installed is None:
        try:
            Path(__file__).resolve().relative_to((_claude_home() / "plugins" / "cache").resolve())
            installed = True
        except ValueError:
            installed = False
    if not installed:
        return "skip:dev"
    run = run or _run_claude
    preflight = preflight or _preflight
    new_sha = new_sha or _marketplace_sha
    sf = marina_home() / "discord-update.json"
    try:
        st = json.loads(sf.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        st = {}
    if st.get("lastAt") and now - float(st["lastAt"]) < UPDATE_EVERY_S:
        return "skip:not-due"
    import fcntl
    try:                                             # runtime 자동 업데이트와 같은 공용 잠금(리뷰 M3) — 잡혀 있으면 다음 분에
        marina_home().mkdir(parents=True, exist_ok=True)
        lk = open(marina_home() / "plugin-update.lock", "w")
        fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return "skip:busy"
    try:
        return _self_update_locked(st, sf, now, run, preflight, new_sha)
    finally:
        lk.close()


def _self_update_locked(st: dict[str, Any], sf: Path, now: float, run, preflight, new_sha) -> str:
    st["lastAt"] = now
    st.pop("lastError", None)                        # 이번 판 결과만 남긴다(리뷰 M4)
    try:
        sf.write_text(json.dumps(st, ensure_ascii=False))   # 먼저 — 아래서 예외가 나도 1시간 쉰다(리뷰 M1)
    except OSError:
        pass
    out = "updated"
    rc, msg = run(["claude", "plugin", "marketplace", "update", "marina-dev"])
    sha = new_sha() if rc == 0 else ""
    if rc != 0:                                      # 리뷰 M2: 받기 실패를 '설치됨'으로 적지 않는다
        st["lastError"] = f"marketplace: {msg[-300:]}"
        out = "failed:marketplace"
    elif sha and sha in (st.get("rejected") or []):
        out = "skip:rejected"
    else:
        ok, why = preflight(_marketplace_scripts())
        if not ok:
            st["rejected"] = ((st.get("rejected") or []) + [sha])[-20:]
            st["lastError"] = why
            out = "rejected"
        else:
            rc, msg = run(["claude", "plugin", "update", _DISCORD_PLUGIN])
            if rc != 0:
                st["lastError"] = msg[-400:]
                out = "failed"
    try:
        sf.write_text(json.dumps(st, ensure_ascii=False))
        with open(sf.with_name("discord-update.log"), "a", encoding="utf-8") as fh:     # 무슨 일이 있었나(리뷰 M2)
            fh.write(f"{time.strftime('%m-%d %H:%M:%S')} {out} {sha or '-'} {str(st.get('lastError') or '')[-200:]}\n")
    except OSError:
        pass
    return out


_UPDATE_LOCK = threading.Lock()


def _update_in_background(tick) -> None:
    """업데이트(최대 수 분)는 뒤에서, 하나만 — 봇 루프(#상태·권한 버튼)를 막지 않는다(리뷰 I4)."""
    if not _UPDATE_LOCK.acquire(blocking=False):
        return
    def go() -> None:
        try:
            tick(time.time())
        except Exception:
            pass
        finally:
            _UPDATE_LOCK.release()
    threading.Thread(target=go, daemon=True).start()


def _daemon_stop_check(updated=None, preflight=None, tick=None) -> bool:
    """데몬이 1분마다 부른다: 자동 업데이트(한 시간에 한 번, 뒤에서) + 설치본이 바뀌었으면 끝낸다.
    단 새 설치본이 데몬 파이썬으로 import 안 되면 끝내지 않는다 — 옛 코드로 계속 돈다(리뷰 I2: 봇 벽돌 방지)."""
    _update_in_background(tick or self_update_tick)
    newest = (updated or _newest_scripts)()
    if not newest:
        return False
    ok, why = (preflight or _preflight)(Path(newest))
    if not ok:
        sys.stderr.write(f"새 설치본 import 실패 — 옛 코드로 계속: {why[-200:]}\n")
    return ok


def _daemon_handoff() -> None:
    """업데이트로 끝난 데몬이 새 코드로 스스로 다시 띄운다 — 다음 훅(사람)을 기다리면 그사이 🛑·권한 버튼이 멈춘다(리뷰 I1)."""
    try:
        if daemon_pid_path().read_text().strip() == str(os.getpid()):
            daemon_pid_path().unlink()
    except OSError:
        pass
    # 고정 입구로 — 이 프로세스는 옛 설치본이라 _hook_entry() 가 자기 경로(옛 코드)를 돌려준다. 그러면 옛 데몬이
    # 1분마다 다시 뜬다(실배포 2026-10-04). 입구는 부를 때마다 설치 목록의 최신을 찾는다
    shim = marina_home() / "bin" / "marina-session-hook"
    ensure_daemon([str(shim)] if shim.is_file() and os.access(shim, os.X_OK) else None)


def _ensure_daemon_quiet() -> None:
    try:
        if config_path().exists():
            ensure_daemon()
    except Exception:
        pass


def hook_stop(payload: dict[str, Any]) -> None:
    """턴 끝: 이번 턴에 읽은 지시들의 진행 표시(👀·도구 이모지·🛑)를 전부 뗀다. 끝났다는 표시는 답장이 한다(✅ 없음, 형 결정 B).
    백그라운드 알림으로 이어서 일한 턴(새 메시지 없음)이 단 이모지도 여기서 뗀다."""
    _ensure_daemon_quiet()
    items = load_sessions()
    s = _hook_target(payload, items)
    if not s or not s.get("channelId"):
        return
    dashboard_signal()
    ids = inbound_messages(Path(str(payload.get("transcript_path") or "/nonexistent")), str(s["channelId"]))
    sd = Path(str(s.get("stateDir") or "/nonexistent"))
    cfg = load_config()
    dc = Discord(read_token(cfg))
    # 진행 훅(분리 실행)이 반응을 다는 중이면 끝나길 기다린 뒤 읽는다 — 안 그러면 🔧 가 남는다(실사용).
    # 최대 3초: Stop 훅 제한 15초 안에 반응 정리·스레드 접기까지 끝내야 한다(리뷰 I5)
    lockf = _wait_lock(sd / "activity.lock")
    try:
        _clear_locked(s, sd, dc, ids)
    finally:
        if lockf:
            lockf.close()
    if ids:
        _archive_threads(s, dc, ids)



def _wait_lock(path: Path, timeout: float = 3.0) -> Any:
    import fcntl
    try:
        f = open(path, "w")
    except OSError:
        return None
    end = time.time() + timeout
    while True:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return f
        except OSError:
            if time.time() > end:
                return f          # 못 잡아도 표시는 진행한다
            time.sleep(0.1)


def _clear_locked(s: dict[str, Any], sd: Path, dc: "Discord", ids: list[str]) -> None:
    """턴 끝·정지 공통: 달아 둔 진행 표시를 기록대로 전부 뗀다. 끝 표시를 먼저 전진 — 중간에 잘려도 같은 일을 반복하지 않게(리뷰 6·B-I4)."""
    ch = str(s["channelId"])
    if sd.is_dir():
        (sd / "stopped-at").write_text(f"{time.time()}\n")   # 이 시각 전에 떠난 진행 훅은 늦게 도착해도 아무것도 안 단다
        if ids:
            (sd / "acked").write_text(ids[-1] + "\n")
    st = _activity_state(sd)
    clear_marks(dc, ch, st)
    if sd.is_dir():
        _write_json(sd / "activity.json", st)


def _archive_threads(s: dict[str, Any], dc: "Discord", ids: list[str]) -> None:
    # 끝난 지시의 진행 스레드는 접는다 — 채널 목록에 계속 쌓이지 않게(열면 기록은 그대로)
    # 턴이 끝났으니 이미 읽은 지시는 모두 끝난 것. 접은 스레드는 목록에서 뺀다(다음 턴에 다시 안 부르게).
    tfile = Path(str(s.get("stateDir") or "")) / "threads.json"
    try:
        threads = json.loads(tfile.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        threads = {}
    afile = tfile.with_name("threads-archived.json")
    try:
        archived = set(json.loads(afile.read_text(encoding="utf-8")))
    except (OSError, ValueError, TypeError):
        archived = set()
    done = [m for m in ids if threads.get(m) and m not in archived]
    for mid in done:
        try:
            dc._req("PATCH", f"/channels/{threads[mid]}", {"archived": True})
        except SessionError:
            pass
    if done:
        # 스레드 기록은 남긴다 — 같은 지시로 다시 progress 하면 그 스레드에 이어 쓰고 Discord 가 다시 연다(리뷰 4)
        _write_json(afile, sorted(archived | set(done))[-200:])


_TEST_CMD = re.compile(r"\b(pytest|run-affected|test-[\w-]+\.sh|npm (run )?test|gradlew\b.*\btest|jest|vitest|go test|cargo test)")


def tool_activity(tool: str, inp: dict[str, Any]) -> tuple[str, str, str]:
    """도구 → (이모지, 하는 일, 짧은 대상)."""
    inp = inp if isinstance(inp, dict) else {}
    base = lambda p: Path(str(p or "")).name
    if tool == "Read":
        return "📖", "파일 읽는 중", base(inp.get("file_path"))
    if tool in ("Glob", "Grep"):
        return "🔍", "찾는 중", str(inp.get("pattern") or "")[:40]
    if tool in ("Edit", "Write", "NotebookEdit"):
        return "✏️", "코드 고치는 중", base(inp.get("file_path") or inp.get("notebook_path"))
    if tool == "Bash":
        cmd = str(inp.get("command") or "")
        what = str(inp.get("description") or "")[:60]     # 명령 원문엔 비밀값이 섞일 수 있다 — 설명만(리뷰 5)
        return ("🧪", "테스트 중", what) if _TEST_CMD.search(cmd) else ("🔧", "명령 실행 중", what)
    if tool in ("WebFetch", "WebSearch"):
        url = str(inp.get("url") or "")
        return "🌐", "웹 보는 중", urllib.parse.urlsplit(url).hostname or str(inp.get("query") or "")[:40]
    if tool in ("Agent", "Task"):
        return "🤖", "하위 작업 맡김", str(inp.get("description") or "")[:40]
    if tool.startswith("mcp__plugin_discord_discord__"):
        return "💬", "답장 쓰는 중", ""
    return "⚙️", "작업 중", tool.replace("mcp__", "")[:40]


def dashboard_signal_path() -> Path:
    return marina_home() / "discord-dirty"


def dashboard_signal() -> None:
    """#상태 대시보드에 '바로 다시 그려' 신호(턴 시작·끝, 세션 켜짐·꺼짐). 봇이 없으면 아무도 안 읽는다."""
    try:
        dashboard_signal_path().touch()
    except OSError:
        pass


def _write_json(path: Path, data: Any) -> None:
    """동시에 도는 훅이 반쯤 쓴 파일을 읽지 않게 tmp 에 쓰고 바꾼다."""
    tmp = path.with_name(f".{path.name}.{os.getpid()}")
    tmp.write_text(json.dumps(data, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def _activity_state(sdir: Path) -> dict[str, Any]:
    try:
        d = json.loads((sdir / "activity.json").read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def hook_activity(payload: dict[str, Any], min_gap: float = 5.0) -> None:
    """PreToolUse(모든 도구, 5초 간격): '입력 중…' + 지시 메시지 반응을 도구 종류로 교체 +
    진행 스레드가 있으면 상태 줄 하나를 고쳐 쓴다. Claude 가 아니라 훅이 하므로 토큰 0."""
    sdir = os.environ.get("DISCORD_STATE_DIR") or ""
    s = next((x for x in load_sessions() if sdir and x.get("stateDir") == sdir), None)
    if not s or not s.get("channelId"):
        return
    sd, ch = Path(sdir), str(s["channelId"])
    import fcntl
    if payload.get("hook_event_name") == "UserPromptSubmit":
        lockf = _wait_lock(sd / "activity.lock")        # 받은 순간 👀 는 버리지 않는다(리뷰 B-M2)
        if lockf is None:
            return
    else:
        lockf = open(sd / "activity.lock", "w")
        try:
            fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)   # 병렬 도구 호출 — 하나만 지나간다(리뷰 2)
        except OSError:
            lockf.close()
            return
    try:
        _hook_activity_locked(payload, s, sd, ch, min_gap)
    finally:
        lockf.close()


def _mark(dc: "Discord", ch: str, st: dict[str, Any], mid: str, emoji: str) -> None:
    """반응을 달고 activity.json 에 적어 둔다 — 떼는 쪽(턴 끝·정지)은 추론하지 않고 적힌 것을 그대로 뗀다(리뷰 B-I1~I4)."""
    marked = st.setdefault("marked", {})
    if emoji in marked.get(mid, []):
        return
    try:
        dc.add_reaction(ch, mid, emoji)
    except SessionError:
        return
    marked.setdefault(mid, []).append(emoji)


def _unmark(dc: "Discord", ch: str, st: dict[str, Any], mid: str, emoji: str) -> None:
    marked = st.setdefault("marked", {})
    if emoji not in marked.get(mid, []):
        return
    try:
        dc.remove_reaction(ch, mid, emoji)
    except SessionError:
        pass
    marked[mid].remove(emoji)
    if not marked[mid]:
        marked.pop(mid)


def clear_marks(dc: "Discord", ch: str, st: dict[str, Any]) -> None:
    for mid, emojis in list((st.get("marked") or {}).items()):
        for e in list(emojis):
            _unmark(dc, ch, st, mid, e)
    st["marked"] = {}
    st.pop("emoji", None)


def _stopped_after(sd: Path, at: float) -> bool:
    try:
        return at < float((sd / "stopped-at").read_text())
    except (OSError, ValueError):
        return False


def _hook_activity_locked(payload: dict[str, Any], s: dict[str, Any], sd: Path, ch: str, min_gap: float) -> None:
    at = float(payload.get("_at") or time.time())
    if _stopped_after(sd, at):      # 턴이 끝나기 전에 떠난 훅이 늦게 도착했다 — 끝난 지시에 다시 달지 않는다(실사용)
        return
    prompt = payload.get("hook_event_name") == "UserPromptSubmit"
    if prompt:
        clear_suggest(sd, ch, Discord(read_token(load_config())))    # 새 지시 — 지난 추천 버튼은 바로 뗀다
        if (sd / "question.json").exists():                          # 취소돼 PostToolUse 가 안 온 질문도 정리(리뷰 C2)
            import marina_discord_ask
            marina_discord_ask.done(sd, ch, "지나간 질문")
    ids = inbound_messages(Path(str(payload.get("transcript_path") or "/nonexistent")), ch)
    if prompt:      # 막 받은 메시지는 아직 기록에 없을 수 있다 — 넘겨받은 글에서 직접 읽는다
        tagged = [m.group(2) for m in _CHANNEL_TAG.finditer(str(payload.get("prompt") or "")) if m.group(1) == ch]
        if not tagged or slash_command(str(payload.get("prompt") or ""), ch):
            return      # 터미널에서 친 말(옛 메시지에 표시 안 함, 리뷰 B-M3) · /compact(마리나가 🗜️ 로 따로 표시)
        ids += [m for m in tagged if m not in ids]
    mid = ids[-1] if ids else ""
    st = _activity_state(sd)
    stamp = sd / "activity-at"
    try:   # 같은 지시면 5초 간격. 새 지시(끼어든 메시지 포함)는 바로(리뷰 B-M1)
        if not prompt and str(st.get("mid") or "") == mid and time.time() - stamp.stat().st_mtime < min_gap:
            return
    except OSError:
        pass
    stamp.touch()
    dc = Discord(read_token(load_config()))
    try:
        dc._req("POST", f"/channels/{ch}/typing")
    except SessionError:
        pass
    if not mid:
        return
    try:
        acked = (sd / "acked").read_text().strip()
    except OSError:
        acked = ""
    fresh = ids[ids.index(acked) + 1:] if acked in ids else [mid]
    emoji, label, what = ("👀", "받음", "") if prompt else \
        tool_activity(str(payload.get("tool_name") or ""), payload.get("tool_input") or {})
    if st.get("mid") != mid:
        old = str(st.get("mid") or "")
        if old:        # 끼어든 새 지시 — 이전 지시는 '받음'(👀)으로 돌리고, 정지 버튼은 지금 지시에만(리뷰 3·B-I1)
            _unmark(dc, ch, st, old, str(st.get("emoji") or ""))
            _unmark(dc, ch, st, old, "🛑")
            if old in fresh:
                _mark(dc, ch, st, old, "👀")
        for m in fresh[:-1]:                        # 한 번에 읽은 앞 메시지들도 '받음'
            if not (st.get("marked") or {}).get(m):
                _mark(dc, ch, st, m, "👀")
        st.update(mid=mid, since=time.time())
        st.pop("emoji", None)
        dashboard_signal()
    _mark(dc, ch, st, mid, "🛑")                    # 누르면 봇이 이 세션에 Esc(봇 1단계). 턴 끝에 뗀다
    if st.get("emoji") != emoji:
        _mark(dc, ch, st, mid, emoji)
        for o in {str(st.get("emoji") or ""), "👀"} - {"", emoji}:
            _unmark(dc, ch, st, mid, o)
        st["emoji"] = emoji
    try:
        tid = json.loads((sd / "threads.json").read_text(encoding="utf-8")).get(mid)
    except (OSError, ValueError):
        tid = None
    if tid:
        mins = int((time.time() - float(st.get("since") or time.time())) // 60)
        line = f"{emoji} {label}" + (f" — {what}" if what else "") + (f" · {mins}분째" if mins else "")
        try:
            if st.get("status_tid") == tid and st.get("status_msg"):
                dc._req("PATCH", f"/channels/{tid}/messages/{st['status_msg']}",
                        {"content": line, "allowed_mentions": {"parse": []}})
            else:
                r = dc._req("POST", f"/channels/{tid}/messages",
                            {"content": line, "flags": 4096, "allowed_mentions": {"parse": []}})
                st.update(status_tid=tid, status_msg=str(r.get("id") or ""))
        except SessionError:
            pass
    if _stopped_after(sd, at):
        # 잠금을 오래 쥔 사이 턴 끝·정지가 잠금 없이 정리했다 — 방금 단 것을 되돌린다(리뷰 B-I3)
        clear_marks(dc, ch, st)
    _write_json(sd / "activity.json", st)


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


def runtime_bin() -> "str | None":
    """runtime(마리나 실행 격리) 명령 — 있으면 `marina` CLI 로만 부른다(스펙 R0·R2, 분리 B). 없으면 None.
    MARINA_RUNTIME_BIN 이 있으면 그것만 본다(테스트·고정 경로, 'none' = 없음). 데몬은 PATH 가 짧아
    ~/.local/bin·플러그인 bin 도 본다."""
    forced = os.environ.get("MARINA_RUNTIME_BIN")
    if forced is not None:
        return forced if forced not in ("", "none") and os.access(forced, os.X_OK) else None
    inst = ""
    try:      # 설치된 marina(runtime) 플러그인의 bin — 데몬 PATH 가 짧아도 찾게(리뷰 D-I3)
        home = Path(os.environ.get("MARINA_CLAUDE_HOME") or Path.home() / ".claude")
        d = json.loads((home / "plugins" / "installed_plugins.json").read_text(encoding="utf-8"))["plugins"]
        es = [e for k, v in d.items() if str(k).startswith("marina@") for e in (v or []) if isinstance(e, dict)]
        es.sort(key=lambda e: (e.get("scope") == "user", str(e.get("lastUpdated") or "")), reverse=True)
        inst = str(Path(str(es[0]["installPath"])) / "bin" / "marina") if es else ""
    except (OSError, ValueError, KeyError, AttributeError):
        inst = ""
    for cand in (shutil.which("marina"), inst, str(Path.home() / ".local" / "bin" / "marina"),
                 str(Path(__file__).resolve().parent.parent.parent / "plugin" / "bin" / "marina")):   # 레포 개발
        if cand and os.access(cand, os.X_OK):
            return cand
    return None


def _run_marina(args: list[str], cwd: Path | None = None, timeout: int = 300) -> subprocess.CompletedProcess:
    rb = runtime_bin()
    if not rb:
        raise SessionError("runtime(marina) 이 없어")
    return subprocess.run([rb] + args, cwd=str(cwd) if cwd else None,
                          capture_output=True, text=True, timeout=timeout)


def _git_worktree_add(project: str, task: str, base: str = "") -> Path:
    """runtime 없이 표준 git 워크트리 — runtime 과 같은 위치·브랜치(<root>/.claude/worktrees/<task 의 /:→->, 브랜치=task)."""
    root = project_root(project)
    wt = root / ".claude" / "worktrees" / re.sub(r"[/:]", "-", task)
    if wt.exists():
        raise SessionError(f"이미 있어: {wt}")
    wt.parent.mkdir(parents=True, exist_ok=True)
    has = subprocess.run(["git", "-C", str(root), "show-ref", "--verify", "--quiet", f"refs/heads/{task}"]).returncode == 0
    if not has and not base:
        # runtime 과 같은 규칙 — 원격 기본 브랜치 최신(origin/HEAD), 원격 없거나 실패하면 로컬 HEAD(리뷰 I4: 메인 체크아웃이
        # 다른 브랜치에 있어도 그 커밋을 안고 태어나지 않게)
        rmt = "origin" if subprocess.run(["git", "-C", str(root), "remote", "get-url", "origin"], capture_output=True).returncode == 0 else ""
        if rmt:
            subprocess.run(["git", "-C", str(root), "fetch", "-q", rmt], capture_output=True, timeout=120)
            subprocess.run(["git", "-C", str(root), "remote", "set-head", rmt, "-a"], capture_output=True, timeout=60)
            head = subprocess.run(["git", "-C", str(root), "symbolic-ref", "-q", "--short", f"refs/remotes/{rmt}/HEAD"],
                                  capture_output=True, text=True).stdout.strip()
            if head:
                base = head
    args = ["worktree", "add", str(wt), task] if has else ["worktree", "add", "-b", task, str(wt)] + ([base] if base else [])
    r = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        raise SessionError("워크트리 생성 실패: " + (r.stderr or r.stdout).strip()[-800:])
    return wt


def worktree_create(project: str, task: str, base: str = "") -> Path:
    if not runtime_bin():
        return _git_worktree_add(project, task, base)
    r = _run_marina(["worktree", "create", task] + ([base] if base else []) + ["--project", project])
    out = (r.stdout or "") + (r.stderr or "")
    if r.returncode != 0:
        raise SessionError("워크트리 생성 실패: " + out.strip()[-800:])
    m = re.search(r"✓ 워크트리:\s*(.+)", out)
    if not m:
        raise SessionError("워크트리 경로를 출력에서 찾지 못했어: " + out.strip()[-400:])
    return Path(m.group(1).strip())


def marina_start(root: Path) -> str:
    """실행 환경 시작. 실패해도 세션은 연다 — 실행 환경은 나중에 켜도 된다. 성공이면 빈 문자열.
    runtime 이 없으면 시작할 실행 환경이 없다(조용히 건너뜀)."""
    if not runtime_bin():
        return ""
    try:
        r = _run_marina(["start", "--all"], cwd=root, timeout=900)
    except subprocess.TimeoutExpired:
        return "marina start 가 15분 안에 끝나지 않았어 — marina status 로 확인해"
    if r.returncode == 0:
        return ""
    return "marina start 실패(세션은 열었어): " + (r.stderr or r.stdout or "").strip()[-400:]


# ── 명령 ─────────────────────────────────────────────────────────────────────

def preflight(cfg: dict[str, Any], dc: Discord, project: str, task: str,
              existing: Path | None = None) -> dict[str, Any]:
    """아무것도 만들기 전에 전부 본다 — 하나라도 걸리면 SessionError. existing = 옮겨 올 대화의 기존 폴더."""
    pc = project_config(cfg, project)
    root = project_root(project)
    tf = token_file(cfg)
    if not tf.is_file():
        raise SessionError(f"토큰 파일이 없어: {tf}")
    if not _tmux_exe():
        raise SessionError("'tmux' 를 찾지 못했어 (brew install tmux)")
    if not shutil.which("claude"):
        raise SessionError("'claude' 를 찾지 못했어 (PATH 확인)")
    wt = existing or root / ".claude" / "worktrees" / worktree_dirname(task)
    name, sdir, chan = tmux_name(project, task), state_dir(project, task), channel_name(task)
    if existing is None and wt.exists():
        raise SessionError(f"워크트리가 이미 있어: {wt}")
    if existing is not None and any(s.get("kind") not in CHAT_KINDS and _same_root(s, existing) for s in load_sessions()):
        raise SessionError(f"이 폴더엔 이미 세션이 있어: {existing}")
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


def cmd_dev_lobby(project: str) -> dict[str, Any]:
    """개발 프로젝트 카테고리의 #새-작업 로비. 프로젝트 루트(이미 신뢰된 폴더)에서 도구 없는 제한 세션으로 뜬다.
    첨부 가드 기준은 레포가 아닌 빈 폴더(inbox) — 로비가 레포 파일을 보낼 일은 없다."""
    task = LOBBY_TASK
    if any(s.get("project") == project and s.get("kind") == "dev-lobby" for s in load_sessions()):
        raise SessionError("이 프로젝트엔 로비가 이미 있어 ('marina session ls' 로 확인)")
    cfg = load_config()
    pc = project_config(cfg, project)
    project_root(project)                     # 등록된 프로젝트인지
    dc = Discord(read_token(cfg))
    tmux, sdir = tmux_name(project, task), state_dir(project, task)
    root = sdir / "home"                      # 레포 루트에서 띄우면 레포 설정·훅·CLAUDE.md 가 섞일 수 있다(리뷰) → 빈 폴더
    tf = token_file(cfg)
    if not tf.is_file():
        raise SessionError(f"토큰 파일이 없어: {tf}")
    if tmux_alive(tmux) or sdir.exists():
        raise SessionError(f"로비 흔적이 남아 있어: {tmux} / {sdir}")
    root.mkdir(parents=True)
    os.chmod(sdir, 0o700)
    root = Path(os.path.realpath(str(root)))
    ensure_trusted(root)          # 새 폴더는 신뢰 확인창에서 멈추고 그동안 플러그인이 안 뜬다(실측)
    record = {"project": project, "task": task, "kind": "dev-lobby", "root": str(root), "tmux": tmux,
              "stateDir": str(sdir), "rcName": "", "sessionId": str(uuid.uuid4()), "createdAt": int(time.time())}
    channel_id = ""
    try:
        cat = ensure_category(dc, cfg, project)
        ensure_archive(dc, cfg, project, cat)
        channel_id = dc.create_text_channel(cfg["guildId"], DEV_LOBBY_CHANNEL, cat, DEV_LOBBY_TOPIC)
        write_state_dir(sdir, channel_id, pc.get("allow") or [], tf)
        (sdir / "inbox").mkdir(exist_ok=True)
        write_settings(sdir, chat_root=sdir / "inbox", lobby=True)
        tmux_start(tmux, root, lobby_argv(project, task, record["sessionId"], dev=True), chat_env(sdir),
                   notify_ref=f"{project}/{task}")
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
    try:
        dc.send_message(channel_id, DEV_LOBBY_GUIDE)
    except SessionError:
        pass
    try:
        ensure_new_panel(project)
    except SessionError:
        pass                                  # 패널은 봇 틱이 다시 보장한다
    return dict(record, url=f"https://discord.com/channels/{cfg['guildId']}/{channel_id}", warning="")


# ── 새 작업 버튼(스펙 2026-10-05-new-task-button-design) ─────────────────────

NEW_PANEL_TEXT = "🛠 **새 작업이 필요해?** 버튼을 누르고 뭘 할지 한 줄로 적어 줘 — 워크트리·채널·세션을 열어 줄게."


def ensure_new_panel(project: str) -> bool:
    """dev 로비에 '새 작업 열기' 버튼 패널을 고정으로 하나만. 있으면 그대로(False), 새로 올렸으면 True."""
    lobby = next((s for s in load_sessions() if s.get("project") == project and s.get("kind") == "dev-lobby"), None)
    if not lobby or not lobby.get("channelId"):
        return False
    cfg = load_config()
    pc = project_config(cfg, project)
    dc = Discord(read_token(cfg))
    ch = str(lobby["channelId"])
    cur = pc.get("newPanel")
    if isinstance(cur, dict) and cur.get("channelId") == ch and cur.get("messageId") and \
            dc.message_exists(ch, str(cur["messageId"])):
        return False
    button = {"type": 1, "components": [{"type": 2, "style": 1, "label": "🛠 새 작업 열기",
                                          "custom_id": f"marina-new:{project}"}]}
    mid = dc.post_panel(ch, NEW_PANEL_TEXT, [button])
    if not mid:
        raise SessionError("패널 메시지 ID 를 못 받았어")
    try:
        dc.pin(ch, mid)
    except SessionError:
        pass                                  # pin 실패(권한·50개 제한)해도 패널은 쓸 수 있다
    cfg = load_config()                       # 올리는 사이 바뀐 설정을 덮지 않게 다시 읽어 그 키만 고친다
    project_config(cfg, project)["newPanel"] = {"channelId": ch, "messageId": mid}
    save_config(cfg)
    return True


RESERVED_SLUGS = frozenset(("dev", "develop", "main", "master", "prod", "production", "staging", "release", "head"))


def _branches(project: str) -> "set[str]":
    r = subprocess.run(["git", "-C", str(project_root(project)), "for-each-ref", "--format=%(refname)",
                        "refs/heads", "refs/remotes/origin"], capture_output=True, text=True)
    out = set()
    for ref in r.stdout.split() if r.returncode == 0 else []:
        out.add(ref[len("refs/heads/"):] if ref.startswith("refs/heads/") else ref[len("refs/remotes/origin/"):])
    return out


def suggest_slug(text: str) -> str:
    """haiku 로 영문 slug 한 번(깨끗한 env, 20초). 실패·형식 불일치면 task-MMDD-HHMM."""
    fallback = time.strftime("task-%m%d-%H%M")
    env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}
    env["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"      # 형의 claude.ai 커넥터를 끈다(chat_env 와 같게)
    prompt = ("아래 작업을 나타내는 짧은 영어 이름을 하나만 답해. 영문 소문자·숫자·하이픈만, 40자 이내, 다른 말은 쓰지 마.\n"
              "예: refund-bug-fix\n\n작업: " + text)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            r = subprocess.run(["claude", "-p", "--model", "haiku", "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                                "--no-session-persistence", prompt],
                               capture_output=True, text=True, timeout=20, env=env, cwd=tmp)
    except (OSError, subprocess.SubprocessError):
        return fallback
    lines = (r.stdout or "").strip().splitlines()
    cand = lines[0].strip().strip("`'\"").lower() if r.returncode == 0 and lines else ""
    return cand if _SLUG.fullmatch(cand) and cand not in RESERVED_SLUGS else fallback


def unique_slug(project: str, slug: str) -> str:
    """같은 slug 의 워크트리·세션 기록·상태 폴더·git 브랜치가 이미 있거나 dev·main 같은 예약어면 -2, -3 …"""
    root = project_root(project)
    items = load_sessions()
    branches = _branches(project)
    n = 1
    while True:
        cand = slug if n == 1 else f"{slug}-{n}"
        if not (cand in RESERVED_SLUGS or cand in branches or (root / ".claude" / "worktrees" / worktree_dirname(cand)).exists()
                or any(s.get("project") == project and s.get("task") == cand for s in items)
                or state_dir(project, cand).exists()):
            return cand
        n += 1


def extract_base(project: str, text: str) -> str:
    """'<브랜치>에서' 꼴(여러 개면 '…에서 시작' 우선, 그다음 마지막)이고 실제로 있는 브랜치만. origin 에 있으면 origin/<b>
    (먼저 fetch), 로컬뿐이면 로컬. 없으면 빈 값(기본 = main)."""
    pat = r"(?<![A-Za-z0-9._/-])([A-Za-z0-9][A-Za-z0-9._/-]*)에서"
    cands = re.findall(pat, text)
    if not cands:
        return ""
    cands = [c for c in re.findall(pat + r"\s*시작", text)][::-1] + cands[::-1]      # 우선순위 순
    root = str(project_root(project))
    try:
        subprocess.run(["git", "-C", root, "fetch", "--quiet", "origin"], capture_output=True, timeout=30,
                       env=dict(os.environ, GIT_TERMINAL_PROMPT="0"))
    except (OSError, subprocess.SubprocessError):
        pass
    r = subprocess.run(["git", "-C", root, "for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes/origin"],
                       capture_output=True, text=True)
    refs = set(r.stdout.split()) if r.returncode == 0 else set()
    for c in cands:
        if f"refs/remotes/origin/{c}" in refs:
            return f"origin/{c}"
        if f"refs/heads/{c}" in refs:
            return c
    return ""


def task_title(text: str) -> str:
    """채널 주제·제목. open_chat 과 같은 문자(@ < > 줄바꿈 백틱)는 거른다."""
    line = re.sub(r"[@<>`]+", " ", (text.strip().splitlines() or [""])[0])
    line = re.sub(r"\s+", " ", line).strip()
    if not line:
        return "새 작업"
    return line if len(line) <= 40 else line[:40] + "…"


def new_task_first_prompt(text: str, who: str = "형", channel: str = "", mid: str = "") -> str:
    """첫 지시. 메시지 ID 가 있으면 다른 들어오는 메시지와 같은 <channel …> 태그로 감싸 reply_to·progress 가 자연스럽게."""
    note = ("[Discord 새 작업 버튼] 위 메시지는 형이 이 작업으로 채널을 열며 남긴 첫 지시야. 이걸 받아 시작해. "
            "진행·결과·질문은 이 채널 reply 로.")
    if not (channel and mid):
        return f"[Discord 새 작업 버튼] 형이 이 작업으로 채널을 열었어: {text}\n" + note.split("야. ", 1)[1]
    who = re.sub(r"[\s\"<>`@\\]+", " ", who).strip()[:40] or "형"
    body = text.replace("</channel", "<\u200b/channel")
    ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
    return (f'<channel source="plugin:discord:discord" chat_id="{channel}" message_id="{mid}" user="{who}" ts="{ts}">\n'
            f'{body}\n</channel>\n{note}')


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
    sdir = os.environ.get("DISCORD_STATE_DIR") or ""
    me = next((s for s in load_sessions() if sdir and s.get("stateDir") == sdir), None)
    project = str((me or {}).get("project") or CHAT_PROJECT)
    dev = project != CHAT_PROJECT
    if name == "list_chats":
        rows = [f"- {s.get('title') or s['task']} ({s['task']}): {link.format(s.get('channelId'))}"
                for s in load_sessions() if s.get("project") == project and s.get("kind") not in LOBBY_KINDS]
        return "\n".join(rows) or ("아직 작업 채널이 없어" if dev else "아직 대화방이 없어")
    if name == "open_chat":
        slug, title = str(args.get("name") or ""), str(args.get("title") or "").strip()
        if not _SLUG.fullmatch(slug):
            raise SessionError("방 이름은 영문 소문자·숫자·하이픈만 (예: wedding-prep)")
        if not title or len(title) > 80:
            raise SessionError("제목이 필요해(80자 이내)")
        if re.search(r"[@<>\n\r`]", title):
            raise SessionError("제목에 @ < > ` 줄바꿈은 쓸 수 없어")
        if dev:
            # 서비스 자동 실행은 수 분 걸려 도구 호출이 끊긴다 — 세션 안에서 marina start
            r = cmd_new(project, slug, start=False, title=title)
            try:
                Discord(read_token(cfg)).send_message(str(r["channelId"]),
                    f"🛠 **'{title}' 작업 채널이야.** 워크트리: `{r['root']}`\n"
                    "• 여기서 지시하면 돼. 서비스가 필요하면 'marina start 해줘' 라고 해.")
            except SessionError:
                pass
            return f"열었어: {title} → {r['url']}"
        r = cmd_new_chat(slug, title=title)
        return f"열었어: {title} → {r['url']}" + (f"\n(참고: {r['warning']})" if r.get("warning") else "")
    raise SessionError(f"없는 도구: {name}")


_CHAT_TOOLS_MCP = [
    {"name": "share_file",
     "description": "만든 결과물을 Discord 로 보낼 준비를 한다. HTML·md 이면 미리보기 이미지를 만들고, #자료실 에도 모아 올린다. "
                    "돌려받은 파일 경로들을 reply 의 files 로 첨부하고, 열어보기 주소가 있으면 reply 본문에 넣어라.",
     "inputSchema": {"type": "object",
                     "properties": {"path": {"type": "string", "description": "이 폴더 안 파일 경로(상대·절대)"},
                                    "title": {"type": "string", "description": "결과물 제목(자료실 표시용)"}},
                     "required": ["path"]}},
    {"name": "ask_terminal",
     "description": "사람이 직접 실행해야 하는 명령(사람 확인이 박힌 래퍼 등)을 Discord 에 [터미널에서 열기] 버튼으로 넘긴다. "
                    "상대가 누르면 이 워크트리 폴더의 터미널에 명령이 입력만 돼 있고 Enter 는 상대가 친다. 개발 세션 전용. 한 줄 명령만.",
     "inputSchema": {"type": "object",
                     "properties": {"command": {"type": "string", "description": "입력해 둘 명령(한 줄, 개행 불가)"},
                                    "why": {"type": "string", "description": "왜 필요한지 한 줄(Discord 메시지에 표시)"}},
                     "required": ["command"]}},
    {"name": "progress",
     "description": "아직 안 끝난 작업의 중간 보고를 지시 메시지의 스레드에 남긴다(알림 없이). 같은 message_id 면 같은 스레드에 이어 쓴다. "
                    "최종 결과는 스레드가 아니라 채널에 reply 로 보낸다.",
     "inputSchema": {"type": "object",
                     "properties": {"message_id": {"type": "string", "description": "지시한 Discord 메시지 ID(<channel> 태그의 message_id)"},
                                    "text": {"type": "string", "description": "진행 한 줄"}},
                     "required": ["message_id", "text"]}}]


def _progress(rec: dict[str, Any], args: dict[str, Any]) -> str:
    """지시 메시지에 스레드를 열고(처음 한 번) 진행 한 줄을 알림 없이 남긴다."""
    mid, text = str(args.get("message_id") or ""), str(args.get("text") or "").strip()
    if not re.fullmatch(r"\d{1,25}|M\d+", mid):
        raise SessionError("message_id 는 지시 메시지의 숫자 ID 여야 해")
    if not text:
        raise SessionError("text 가 비었어")
    cfg = load_config()
    dc = Discord(read_token(cfg))
    tf = Path(str(rec["stateDir"])) / "threads.json"
    try:
        threads = json.loads(tf.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        threads = {}
    tid = str(threads.get(mid) or "")
    if not tid:
        name = ("진행 · " + re.sub(r"\s+", " ", text))[:90]
        try:
            tid = str(dc._req("POST", f"/channels/{rec['channelId']}/messages/{mid}/threads",
                              {"name": name, "auto_archive_duration": 60})["id"])
        except DiscordError as exc:
            if exc.code == 403:
                return ("스레드를 만들 권한이 없어(봇 역할에 '공개 스레드 만들기' 필요) — "
                        "이번엔 채널에 진행 메시지 하나를 reply 로 보내고 edit_message 로 갱신해")
            raise
        threads[mid] = tid
        tf.write_text(json.dumps(dict(list(threads.items())[-50:]), ensure_ascii=False) + "\n", encoding="utf-8")
    dc._req("POST", f"/channels/{tid}/messages",
            {"content": text[:1900], "flags": 4096, "allowed_mentions": {"parse": []}})   # 4096 = 알림 없이
    af = tf.with_name("threads-archived.json")                 # 다시 열렸으니 턴이 끝나면 다시 접는다
    try:
        arch = json.loads(af.read_text(encoding="utf-8"))
        if mid in arch:
            _write_json(af, [m for m in arch if m != mid])
    except (OSError, ValueError, TypeError):
        pass
    return f"스레드에 남겼어(thread {tid}). 끝나면 결과는 채널에 reply 로."


def _ask_terminal(rec: dict[str, Any], args: dict[str, Any]) -> str:
    """사람이 직접 실행할 명령을 [터미널에서 열기] 링크 버튼으로 채널에 보낸다. runtime 은 `marina term-request` 로만 부른다."""
    if rec.get("kind") in CHAT_KINDS:
        raise SessionError("ask_terminal 은 개발 세션 전용이야")
    command, why = str(args.get("command") or ""), str(args.get("why") or "").strip()
    if not command.strip():
        raise SessionError("command 가 필요해")
    # 개행·보이지 않는 문자·1500자 초과 검증은 runtime(`marina term-request`)이 한다 — 거부되면 아래에서 SessionError.
    argv = ["term-request"] + (["--why", why] if why else []) + ["--", command]
    # 선택 기능 — marina CLI 가 없거나 실패하면 버튼 없이 "맥 앞에서 직접 실행해 달라고 부탁해" 로 안내한다(discord 는 runtime 없이도 돈다)
    ask_human = "이 명령은 맥 앞에서 직접 실행해 달라고 형에게 reply 로 부탁해(명령 원문을 같이 적어)"
    try:
        r = _run_marina(argv, cwd=Path(str(rec["root"])), timeout=30)
    except (SessionError, OSError, subprocess.SubprocessError) as exc:
        raise SessionError(f"터미널 링크를 만들지 못했어({str(exc)[:200]}) — {ask_human}")
    url = (r.stdout or "").strip().splitlines()[-1] if (r.stdout or "").strip() else ""
    if r.returncode != 0 or not url.startswith(("http://", "https://")):
        raise SessionError(f"터미널 링크를 만들지 못했어({(r.stderr or r.stdout or '').strip()[:200]}) — {ask_human}")
    # 보이는 명령 = 실제 명령: 자르지 않고, 명령 안의 백틱보다 긴 울타리로 감싼다
    fence = "`" * max(3, max((len(m) for m in re.findall(r"`+", command)), default=0) + 1)
    why = "".join(c for c in re.sub(r"\s+", " ", why) if unicodedata.category(c) not in ("Cc", "Cf"))   # 한 줄·보이지 않는 문자 제거
    esc_why = re.sub(r"([\\`*_~|>#\[\]()])", r"\\\1", why.replace("@", ""))[:300]   # 마크다운 링크·서식이 렌더되지 않게
    head = ("🖥 " + esc_why + "\n") if why else "🖥 터미널에서 직접 실행해 줘\n"
    try:
        cfg = load_config()
        Discord(read_token(cfg))._req("POST", f"/channels/{rec['channelId']}/messages", {
            "content": f"{head}{fence}\n{command}\n{fence}", "allowed_mentions": {"parse": []},
            "components": [{"type": 1, "components": [{"type": 2, "style": 5, "label": "터미널에서 열기", "url": url}]}]})
    except Exception as exc:        # 버튼을 못 보내도 세션이 막히지 않게 — 같은 안내로
        raise SessionError(f"터미널 버튼을 못 보냈어({str(exc)[:200]}) — {ask_human}")
    return "버튼 보냈어 — 형이 실행하고 알려 주면 이어서"


def _dev_preview_dir(rec: dict[str, Any]) -> Path:
    """개발 세션 미리보기 폴더 — 워크트리 밖(git add 로 딸려 가지 않게) + 상태 폴더 밖(공식 Discord 플러그인이 자기 상태 폴더 안
    파일 첨부를 'refusing to send channel state' 로 거부한다, 2026-10-05 실측)."""
    return marina_home() / "share-previews" / f"{rec.get('project')}-{rec.get('task')}"


def chat_tool(name: str, args: dict[str, Any]) -> str:
    """채팅·개발 세션 MCP 도구. 실패는 SessionError."""
    if name == "ask_terminal":
        sdir = os.environ.get("DISCORD_STATE_DIR") or ""
        rec = next((s for s in load_sessions() if sdir and s.get("stateDir") == sdir), None)
        if not rec or not rec.get("channelId"):
            raise SessionError("이 세션의 기록을 찾지 못했어")
        return _ask_terminal(rec, args)
    if name == "progress":
        sdir = os.environ.get("DISCORD_STATE_DIR") or ""
        rec = next((s for s in load_sessions() if sdir and s.get("stateDir") == sdir), None)
        if not rec or not rec.get("channelId"):
            raise SessionError("이 세션의 기록을 찾지 못했어")
        return _progress(rec, args)
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
        # 개발 세션은 레포 밖(상태 폴더)에 — 워크트리에 두면 git add 로 커밋에 딸려 간다(리뷰)
        outdir = root / "미리보기" if rec.get("kind") in CHAT_KINDS else _dev_preview_dir(rec)
        prev, why = marina_share.render_html(path, root, outdir)
        if not prev:
            notes.append(f"미리보기를 만들지 못했어({why}) — HTML 파일만 보내")
        else:
            files = [prev] + files
            if why:
                notes.append(why)
    if path.suffix.lower() in (".md", ".markdown"):
        outdir = root / "미리보기" if rec.get("kind") in CHAT_KINDS else _dev_preview_dir(rec)
        imgs, why = marina_share.render_md(path, root, outdir)
        if not imgs:
            notes.append(f"미리보기를 만들지 못했어({why}) — md 파일만 보내")
        else:
            files = imgs + files
            if why:
                notes.append(why)
    cfg = load_config()
    view_url = ""
    if path.suffix.lower() in _VIEW_SUFFIXES:
        # 폰·다른 사람이 여는 보기 주소 — discord 가 혼자 한다(링크가 열쇠, 기한 없음). 개발·채팅 세션 둘 다
        import marina_view
        if not marina_view.public_url(cfg, "x"):
            notes.append("(열어보기 주소는 아직 설정 전이라 생략 — 첨부만 보내. 설정은 형이 `marina-session view-setup`)")
        else:
            try:
                url = marina_view.public_url(cfg, marina_view.create(str(root), str(path), str(rec.get("channelId") or "")))
                view_url = url
                notes.append(f"열어보기: {url} — reply 본문에 이 주소를 넣어")
            except (ValueError, OSError) as exc:
                notes.append(f"열어보기 링크를 만들지 못했어({exc}) — 첨부만 보내")
    title = str(args.get("title") or path.stem).replace("@", "").replace("\n", " ")[:80]
    arch = str((cfg["projects"].get(str(rec.get("project"))) or {}).get("archiveChannelId") or "")
    if arch:
        room = str(rec.get("title") or rec.get("task")).replace("@", "")
        big = [f for f in files if f.stat().st_size > 10 * 1024 * 1024]
        try:
            marina_share.upload_message(Discord(read_token(cfg)).base, read_token(cfg), arch,
                                        f"📎 [{room}] {title}\n원래 방: <#{rec.get('channelId')}>" + (f"\n열어보기: <{view_url}>" if view_url else ""),
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


LOCK_OWNER = "marina-session"
GONE_GRACE_S = 120          # 워크트리가 이만큼 넘게 계속 없을 때만 채널을 정리(잠깐 옮기거나 디스크가 안 보일 때 오탐 방지)


def _dev(s: dict[str, Any]) -> bool:
    return s.get("kind") not in CHAT_KINDS and bool(s.get("root"))


def _git_lock_info(root: Path) -> "dict[str, Any] | None":
    """git 표준 잠금 정보 — runtime 의 판정과 같은 규칙(사본, 스펙 R3): 이유 첫 낱말 = 주인, `(pid N` 이 있고
    그 프로세스가 죽었으면 낡은 잠금."""
    try:
        r = subprocess.run(["git", "-C", str(root), "rev-parse", "--absolute-git-dir"], capture_output=True, text=True, timeout=10)
        reason = (Path(r.stdout.strip()) / "locked").read_text(encoding="utf-8").strip() if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        reason = None
    if reason is None:
        return None
    m = re.search(r"\(pid (\d+)", reason)
    pid = int(m.group(1)) if m else None
    stale = False
    if pid:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            stale = True
        except OSError:
            pass
    return {"reason": reason, "owner": (reason.split() or [""])[0], "pid": pid, "stale": stale}


def lock_root(s: dict[str, Any]) -> str:
    """개발 세션 워크트리를 git 표준 잠금으로 '쓰는 중' 표시(스펙 3장) — runtime 삭제·7일 정리가 건너뛴다.
    메인 체크아웃(잠글 수 없음)·남이 잠근 것은 조용히 넘긴다. 반환: 실패 이유(성공이면 "")."""
    if not _dev(s):
        return ""
    try:
        root = Path(str(s["root"]))
        cur = _git_lock_info(root)
        if cur and cur["owner"] == LOCK_OWNER:
            return ""
        if cur and cur["owner"] == "claude":
            # 데스크톱 claude --worktree 대화를 adopt — Claude 자기 잠금은 /exit 때 스스로 무시하고 지우므로(실측) 지켜 주지
            # 못한다. marina-session 잠금으로 바꿔 건다(리뷰 I4).
            subprocess.run(["git", "-C", str(root), "worktree", "unlock", str(root)], capture_output=True, timeout=10)
        if cur and cur["owner"] not in (LOCK_OWNER, "claude") and not cur["stale"]:
            return f"이미 잠김: {cur['reason']}"
        if cur and cur["owner"] != "claude":     # 낡은 잠금
            subprocess.run(["git", "-C", str(root), "worktree", "unlock", str(root)], capture_output=True, timeout=10)
        r = subprocess.run(["git", "-C", str(root), "worktree", "lock", "--reason",
                            f"{LOCK_OWNER} {s.get('project')}/{s.get('task')}", str(root)],
                           capture_output=True, text=True, timeout=10)
        return "" if r.returncode == 0 else (r.stderr or r.stdout).strip()
    except Exception as exc:
        return str(exc)


def unlock_root(s: dict[str, Any]) -> None:
    if not _dev(s):
        return
    try:
        root = Path(str(s["root"]))
        cur = _git_lock_info(root)
        if cur and cur["owner"] == LOCK_OWNER:
            subprocess.run(["git", "-C", str(root), "worktree", "unlock", str(root)], capture_output=True, timeout=10)
    except Exception:
        pass


def reconcile_gone(now: float | None = None) -> list[str]:
    """밖에서(대시보드 force·git) 지워진 워크트리의 세션을 정리한다 — runtime 은 Discord 를 모르므로(스펙 R1)
    discord 가 스스로 본다. 두 번 관찰(≥ GONE_GRACE_S 간격)해야 정리. 절대 예외를 올리지 않는다."""
    now = time.time() if now is None else now
    done: list[str] = []
    try:
        items = load_sessions()
    except Exception:
        return done
    changed = False
    for s in items:
        if not _dev(s):
            continue
        if Path(str(s["root"])).is_dir():
            if s.pop("goneSince", None) is not None:
                changed = True
            lock_root(s)      # 배포 전부터 돌던 세션도 알아서 잠근다(멱등, 리뷰 I5)
            continue
        since = s.get("goneSince")
        if since is None:
            s["goneSince"] = now
            changed = True
        elif now - float(since) >= GONE_GRACE_S:
            done.append(f"{s.get('project')}/{s.get('task')}")
    if changed:
        try:
            save_sessions(items)
        except Exception:
            return []
    for ref in done:
        try:
            teardown(find_session(ref))
        except Exception:
            pass
    return done


def cmd_new(project: str, task: str, base: str = "", start: bool = True, from_id: str = "",
            title: str = "", first: Any = "") -> dict[str, Any]:
    """first = 첫 지시 글, 또는 채널 ID 를 받아 글을 돌려주는 함수(채널을 만든 뒤 조립 — 세션이 자기 채널·메시지를 알게)."""
    if project == CHAT_PROJECT:
        return cmd_new_chat(task, from_id, title=title)
    if from_id:
        return cmd_adopt(project, task, from_id)
    cfg = load_config()
    dc = Discord(read_token(cfg))
    plan = preflight(cfg, dc, project, task)
    wt = worktree_create(project, task, base)
    warning = marina_start(wt) if start else ""
    sdir: Path = plan["stateDir"]
    channel_id = ""
    try:
        cat = ensure_category(dc, cfg, project)
        ensure_archive(dc, cfg, project, cat)
        channel_id = dc.create_text_channel(cfg["guildId"], plan["channel"], cat, title)
        write_state_dir(sdir, channel_id, project_config(cfg, project).get("allow") or [], token_file(cfg))
        write_settings(sdir)
        if callable(first):
            try:
                first = first(channel_id)
            except Exception:
                first = ""
        tmux_start(plan["tmux"], wt, claude_argv(project, task, first=first), session_env(sdir),
                   notify_ref=f"{project}/{task}")
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
    if title:
        record["title"] = title
    items = load_sessions()
    items.append(record)
    save_sessions(items)
    lock_root(record)
    return dict(record, url=f"https://discord.com/channels/{cfg['guildId']}/{channel_id}", warning=warning)


def cmd_adopt(project: str, task: str, from_id: str) -> dict[str, Any]:
    """하던 개발 대화를 Discord 채널로 옮긴다: 워크트리를 만들지 않고 그 대화가 돌던 폴더에서 복사본으로 잇는다.
    실행 환경(marina start)은 건드리지 않는다 — 이미 떠 있을 수 있다."""
    _check_task(task)
    from_id = _check_uuid(from_id)
    tr = find_transcript(from_id)
    if not tr:
        raise SessionError(f"대화를 찾지 못했어: {from_id}")
    cwd = conversation_home(tr)
    root = project_root(project)
    here = Path(os.path.realpath(cwd)) if cwd else None
    wtroot = root / ".claude" / "worktrees"
    if here is not None and str(here).startswith(str(wtroot) + os.sep) and here.parent != wtroot:
        raise SessionError(f"워크트리 안 하위 폴더에서 띄운 대화는 옮길 수 없어(워크트리 폴더에서 띄운 대화만): {here}")
    inside = here is not None and (here == root or here.parent == wtroot)   # 워크트리 경계 = 세션 root(리뷰 1)
    if not inside:
        raise SessionError(f"그 대화는 프로젝트 '{project}' 의 폴더에서 한 게 아니야: {cwd or '?'}")
    if not here.is_dir():
        raise SessionError(f"그 대화의 폴더가 지워졌어(워크트리 삭제됨): {here}")
    cfg = load_config()
    dc = Discord(read_token(cfg))
    plan = preflight(cfg, dc, project, task, existing=here)
    sdir: Path = plan["stateDir"]
    record = {"project": project, "task": task, "root": str(here), "tmux": plan["tmux"], "stateDir": str(sdir),
              "rcName": rc_name(project, task), "sessionId": str(uuid.uuid4()), "forkedFrom": from_id,
              "createdAt": int(time.time())}
    channel_id = ""
    try:
        cat = ensure_category(dc, cfg, project)
        ensure_archive(dc, cfg, project, cat)
        channel_id = dc.create_text_channel(cfg["guildId"], plan["channel"], cat)
        write_state_dir(sdir, channel_id, project_config(cfg, project).get("allow") or [], token_file(cfg))
        write_settings(sdir)
        tmux_start(plan["tmux"], here, claude_argv(project, task, session_id=record["sessionId"], from_id=from_id),
                   session_env(sdir), notify_ref=f"{project}/{task}")
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
    lock_root(record)
    try:
        dc.send_message(channel_id, f"🔁 하던 대화를 이어받았어 — `{here}`. 여기서 이어서 지시하면 돼.")
    except SessionError:
        pass
    return dict(record, url=f"https://discord.com/channels/{cfg['guildId']}/{channel_id}", warning="")


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
        chat = s.get("kind") in CHAT_KINDS
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
                guard = sdir / "inbox" if s.get("kind") == "dev-lobby" else root
                write_settings(sdir, chat_root=guard if chat else None, lobby=s.get("kind") in LOBBY_KINDS)
                _drop_ack_reaction(sdir / "access.json")
            if chat:
                ensure_trusted(chat_home())
            cwd, argv = session_launch(s, resume=True)
            tmux_start(name, cwd, argv,
                       chat_env(sdir) if chat else session_env(sdir), notify_ref=label)
            lock_root(s)
            started.append(label)
            try:
                resume_unanswered(s)          # 재시작 전에 받고 못 답한 메시지가 있으면 이어서 답하게
            except Exception:
                pass
        except SessionError as exc:
            failed.append(f"{label}: {exc}")
    return started, failed


def teardown(s: dict[str, Any]) -> list[str]:
    """tmux · 채널 · 상태 폴더 · 기록을 지운다(워크트리는 안 건드림). 채널 404 는 이미 지워진 것."""
    warnings: list[str] = []
    tmux_stop(str(s.get("tmux") or ""))
    unlock_root(s)
    if s.get("channelId"):
        try:
            cfg = load_config()
            Discord(read_token(cfg)).delete_channel(str(s["channelId"]))
        except DiscordError as exc:
            if exc.code != 404:
                warnings.append(f"채널 삭제 실패: {exc}")
        except Exception as exc:          # 무슨 실패든 나머지 정리는 끝까지 한다
            warnings.append(f"채널 삭제 실패: {exc}")
    try:       # 결과물 보기 링크 — 그 방에서 만든 것(채팅 폴더는 방끼리 공유라 channel 로), 개발 세션은 워크트리 전체
        import marina_view
        if s.get("channelId"):
            marina_view.revoke(channel=str(s["channelId"]))
        if s.get("root") and s.get("kind") not in CHAT_KINDS:
            marina_view.revoke(all_in=str(s["root"]))
    except Exception as exc:
        warnings.append(f"보기 링크 정리 실패: {exc}")
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


def _tailscale_bin() -> "str | None":
    """MARINA_TAILSCALE(테스트·고정 경로, 'none' = 없음) → PATH(데몬 PATH 포함) → macOS 앱 번들."""
    forced = os.environ.get("MARINA_TAILSCALE")
    if forced is not None:
        return forced if forced not in ("", "none") and os.access(forced, os.X_OK) else None
    found = shutil.which("tailscale", path=os.environ.get("PATH", "") + ":" + daemon_path())
    if found:
        return found
    app = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    return app if os.access(app, os.X_OK) else None


def _tailscale_argv(ts: str) -> "list[str]":
    """맥에 오픈소스 tailscaled 와 Tailscale 앱이 같이 떠 있으면 --socket 없는 CLI 는 **앱**을 본다(2026-09-28 사고) —
    형 Funnel 은 tailscaled 쪽. MARINA_TAILSCALE_SOCKET 이 있으면 그것, 없으면 맥 기본 소켓이 있을 때 그것(runtime marina_remote 와 같은 규칙)."""
    sock = os.environ.get("MARINA_TAILSCALE_SOCKET") or ""
    if (not sock and not os.environ.get("MARINA_TAILSCALE") and sys.platform == "darwin"   # 고정 경로(테스트 등)면 자동 소켓 안 붙임
            and os.path.exists("/var/run/tailscaled.socket")):
        sock = "/var/run/tailscaled.socket"
    return [ts, "--socket", sock] if sock else [ts]


def cmd_view_setup(force: bool = False) -> int:
    """결과물 보기 서버(127.0.0.1:<port>)를 Tailscale Funnel(https 10000)로 공개하고 discord.json view.publicBase 를 저장한다.
    형이 허락한 뒤 한 번 실행한다 — 외부 공개 설정을 바꾸는 명령이라 자동으로 돌리지 않는다."""
    import marina_view
    ts = _tailscale_bin()
    if not ts:
        print("marina session: tailscale 을 찾지 못했어 — 설치한 뒤 다시 하거나, discord.json 의 view.publicBase 를 직접 적어 "
              f"(예: \"view\": {{\"port\": {marina_view.DEFAULT_PORT}, \"publicBase\": \"https://<맥>.ts.net:10000\"}})", file=sys.stderr)
        return 1
    cfg = load_config()
    raw_port = (cfg.get("view") or {}).get("port") if isinstance(cfg.get("view"), dict) else None
    try:
        port = int(raw_port or marina_view.DEFAULT_PORT)
        if not 1 <= port <= 65535:
            raise ValueError(port)
    except (TypeError, ValueError):
        print(f"marina session: discord.json 의 view.port 가 올바른 포트 번호가 아니야: {raw_port!r}", file=sys.stderr)
        return 1
    target = f"http://127.0.0.1:{port}"
    if not force:      # 10000 에 이미 다른 매핑이 있으면 덮지 않는다(다른 서비스를 끊을 수 있다)
        try:
            fs = subprocess.run([*_tailscale_argv(ts), "funnel", "status", "--json"], capture_output=True, text=True, timeout=20)
            info = json.loads(fs.stdout or "{}")
        except (OSError, subprocess.SubprocessError, ValueError):
            info = {}
        web = info.get("Web") if isinstance(info, dict) and isinstance(info.get("Web"), dict) else {}
        tcp = info.get("TCP") if isinstance(info, dict) and isinstance(info.get("TCP"), dict) else {}
        proxies = [str(h.get("Proxy") or h.get("Path") or h.get("Text") or "?")
                   for k, v in web.items() if str(k).endswith(":10000") and isinstance(v, dict)
                   for h in (v.get("Handlers") or {}).values() if isinstance(h, dict)]
        if proxies and any(x.rstrip("/") != target for x in proxies):
            print(f"marina session: https 10000 에 이미 다른 Funnel 매핑이 있어: {', '.join(proxies)}\n"
                  "  덮으면 그 서비스가 끊겨 — 확인한 뒤 덮으려면 `marina-session view-setup --force`", file=sys.stderr)
            return 1
        if "10000" in tcp and not proxies:
            print("marina session: https 10000 이 이미 쓰이고 있는데 내용을 못 읽었어 — 확인한 뒤 덮으려면 `marina-session view-setup --force`", file=sys.stderr)
            return 1
    try:
        st = subprocess.run([*_tailscale_argv(ts), "status", "--json"], capture_output=True, text=True, timeout=20)
        dns = str((json.loads(st.stdout or "{}").get("Self") or {}).get("DNSName") or "").rstrip(".")
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        print(f"marina session: tailscale 상태를 읽지 못했어: {exc}", file=sys.stderr)
        return 1
    if not dns:
        print("marina session: tailscale 이 로그인돼 있지 않아(DNSName 없음)", file=sys.stderr)
        return 1
    try:
        fr = subprocess.run([*_tailscale_argv(ts), "funnel", "--bg", "--https=10000", f"http://127.0.0.1:{port}"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"marina session: funnel 설정 실패: {exc}", file=sys.stderr)
        return 1
    if fr.returncode != 0:
        print(f"marina session: funnel 설정 실패: {(fr.stderr or fr.stdout or '').strip()[:300]}", file=sys.stderr)
        return 1
    base = f"https://{dns}:10000"
    cfg["view"] = dict(cfg["view"], port=port, publicBase=base) if isinstance(cfg.get("view"), dict) else {"port": port, "publicBase": base}
    save_config(cfg)
    print(f"✓ 결과물 보기: {base}  (데몬이 127.0.0.1:{port} 를 열어 줘 — 데몬은 다음 한 바퀴 안에 반영)")
    _ensure_daemon_quiet()
    return 0


def cmd_view_revoke(target: str, all_in: str) -> int:
    import marina_view
    if not target and not all_in:
        print("marina session: view-revoke <토큰|파일 경로> 또는 --all-in <폴더>", file=sys.stderr)
        return 2
    n = marina_view.revoke(target or None, all_in or None)
    if not n:
        print("marina session: 끊을 링크가 없어", file=sys.stderr)
        return 1
    print(f"✓ 링크 {n}개 끊음")
    return 0


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
    sub.add_parser("lobby", help="카테고리에 로비를 연다(인자 없음 = CHAT #새-대화, 프로젝트 = #새-작업)") \
        .add_argument("project", nargs="?", default="")
    sub.add_parser("mcp-lobby")
    sub.add_parser("mcp-chat")
    p = sub.add_parser("ls")
    p.add_argument("--json", action="store_true")
    for name in ("attach", "stop", "rm"):
        sub.add_parser(name).add_argument("ref")
    sub.add_parser("lock-all")
    sub.add_parser("daemon")
    sub.add_parser("daemon-ensure")
    p = sub.add_parser("view-setup", help="결과물 보기 서버를 Tailscale Funnel 로 공개하고 publicBase 를 저장")
    p.add_argument("--force", action="store_true", help="https 10000 에 이미 다른 매핑이 있어도 덮는다")
    p = sub.add_parser("view-revoke", help="결과물 보기 링크 끊기(토큰·파일 경로·--all-in 폴더)")
    p.add_argument("target", nargs="?", default="")
    p.add_argument("--all-in", dest="all_in", default="")
    p = sub.add_parser("start")
    p.add_argument("ref", nargs="?", default="")
    p.add_argument("--all", action="store_true")
    p = sub.add_parser("restart")
    p.add_argument("refs", nargs="*")
    p.add_argument("--all", action="store_true")
    p.add_argument("--wait", type=float, default=6 * 3600.0)
    sub.add_parser("hook-stop")
    sub.add_parser("hook-typing")
    sub.add_parser("hook-reply-to")
    sub.add_parser("hook-prompt")
    sub.add_parser("hook-question")
    sub.add_parser("hook-permission")
    sub.add_parser("hook-question-done")
    sub.add_parser("hook-activity-run")
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
    if a.cmd in ("hook-question", "hook-question-done"):
        try:
            (hook_question if a.cmd == "hook-question" else hook_question_done)(json.loads(sys.stdin.read() or "{}"))
        except Exception:
            pass
        return 0
    if a.cmd == "hook-permission":
        try:
            out = hook_permission(json.loads(sys.stdin.read() or "{}"))
            if out:
                print(json.dumps(out, ensure_ascii=False))
        except Exception:
            pass
        return 0
    if a.cmd in ("hook-reply-to", "hook-prompt"):
        # 실패해도 도구 호출·입력은 그대로 지나가게 — 출력이 없으면 하네스는 아무것도 바꾸지 않는다
        try:
            fn = hook_reply_to if a.cmd == "hook-reply-to" else hook_prompt
            out = fn(json.loads(sys.stdin.read() or "{}"))
            if out:
                print(json.dumps(out, ensure_ascii=False))
        except Exception:
            pass
        return 0
    if a.cmd == "hook-typing":
        # 표시용 — 도구 실행을 기다리게 하지 않는다: 입력만 넘기고 떼어 낸 프로세스가 Discord 를 부른다(리뷰 1)
        try:
            try:
                data = json.dumps(dict(json.loads(sys.stdin.read() or "{}"), _at=time.time()))
            except (ValueError, TypeError):
                data = "{}"
            p = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "hook-activity-run"],
                                 stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
            p.stdin.write(data.encode())
            p.stdin.close()
        except Exception:
            pass
        return 0
    if a.cmd == "hook-activity-run":
        try:
            hook_activity(json.loads(sys.stdin.read() or "{}"))
        except Exception:
            pass
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
        if a.cmd == "lobby" and a.project and a.project != CHAT_PROJECT:
            r = cmd_dev_lobby(a.project)
            print(f"✓ 로비: #{DEV_LOBBY_CHANNEL} ({a.project})")
            print(f"  Discord: {r['url']}")
        elif a.cmd == "lobby":
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
        elif a.cmd == "restart":
            # 안전 재시작: 쉬고(턴 끝)·뒤에서 도는 일·질문·권한 대기가 없을 때만. 아니면 풀릴 때까지 기다린다
            import marina_discord_bot as mb
            refs = [f"{x['project']}/{x['task']}" for x in load_sessions()] if a.all else \
                [f"{find_session(r)['project']}/{find_session(r)['task']}" for r in a.refs]
            me = _session_from_env()                  # 세션 안에서 부르면 자기 자신은 빼고(자기를 기다리며 멈춘다, 리뷰 I8)
            if me:
                mine = f"{me['project']}/{me['task']}"
                if mine in refs:
                    refs.remove(mine)
                    print(f"⚠ 자기 세션({mine})은 빼고 한다 — 다른 곳에서 restart 해 줘", file=sys.stderr)
            if not refs:
                raise SessionError("restart <작업…> 또는 restart --all")
            done, waiting = mb.safe_restart(refs, wait=a.wait, log=print)
            for x in waiting:
                print(f"✗ 못 함(계속 바쁨): {x}", file=sys.stderr)
            return 1 if waiting else 0
        elif a.cmd == "stop":
            s = find_session(a.ref)
            tmux_stop(str(s["tmux"]))
            print(f"✓ 정지: {s['project']}/{s['task']}")
        elif a.cmd == "daemon":
            daemon_pid_path().write_text(f"{os.getpid()}\n")
            import marina_discord_bot
            marina_discord_bot.run_forever(stop=_daemon_stop_check)
            _daemon_handoff()
        elif a.cmd == "daemon-ensure":
            print(ensure_daemon())
        elif a.cmd == "view-setup":
            return cmd_view_setup(a.force)
        elif a.cmd == "view-revoke":
            return cmd_view_revoke(a.target, a.all_in)
        elif a.cmd == "lock-all":
            for x in load_sessions():
                why = lock_root(x)
                if why and _dev(x):
                    print(f"· {x.get('project')}/{x.get('task')}: 안 잠금({why.splitlines()[0][:120]})")
            print("✓ 개발 세션 워크트리 잠금")
        elif a.cmd == "rm":
            s = find_session(a.ref)
            for x in teardown(s):
                print("⚠ " + x, file=sys.stderr)
            kept = f"폴더는 그대로: {s['root']}" if s.get("kind") in CHAT_KINDS else "워크트리는 그대로"
            print(f"✓ 정리: {s['project']}/{s['task']} ({kept})")
    except SessionError as exc:
        print(f"marina session: {exc}", file=sys.stderr)
        return 1
    if a.cmd in ("new", "start", "restart", "lobby"):
        _ensure_daemon_quiet()          # 세션을 띄우면 봇도(대시보드가 안 띄운다, 분리 B)
    return 0


if __name__ == "__main__":
    sys.exit(main())
