#!/usr/bin/env python3
"""Discord 세션 — 워크트리 하나 = Discord 채널 하나 = tmux 안의 `claude --channels` 하나.

설계: docs/superpowers/specs/2026-10-01-discord-sessions-design.md
마리나는 실행 계층(worktree create · start)만 부른다. 대화 배달은 Claude Code Channels(공식 플러그인)가 한다.
데몬(python3.9)이 remove_worktree · idle_verdict 경로로 import 하므로 3.9 호환을 지킨다."""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.error
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

    def create_category(self, guild: str, name: str) -> str:
        return str(self._req("POST", f"/guilds/{guild}/channels", {"name": name, "type": 4})["id"])

    def create_text_channel(self, guild: str, name: str, parent: str) -> str:
        body = {"name": name, "type": 0, "parent_id": parent}
        return str(self._req("POST", f"/guilds/{guild}/channels", body)["id"])

    def delete_channel(self, cid: str) -> None:
        self._req("DELETE", f"/channels/{cid}")

    def add_reaction(self, cid: str, mid: str, emoji: str) -> None:
        self._req("PUT", f"/channels/{cid}/messages/{mid}/reactions/{urllib.parse.quote(emoji)}/@me")

    def remove_reaction(self, cid: str, mid: str, emoji: str) -> None:
        self._req("DELETE", f"/channels/{cid}/messages/{mid}/reactions/{urllib.parse.quote(emoji)}/@me")

    def send_message(self, cid: str, content: str) -> None:
        self._req("POST", f"/channels/{cid}/messages", {"content": content})


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


def write_settings(sdir: Path) -> Path:
    """채널 세션 전용 설정(--settings). 사용자 설정과 합쳐진다.
    Stop 훅 = 턴이 끝나면 👀→✅. enabledPlugins = 사용자 범위에서 플러그인을 꺼도 이 세션에서만 켜지게."""
    # 버전 캐시 경로가 지워지면 exit 2 가 claude 종료를 막는다 → 실패해도 0(최종 리뷰 I2). start 가 다시 쓴다.
    cmd = shlex.join([sys.executable, str(Path(__file__).resolve()), "hook-stop"]) + " || true"
    settings = {"enabledPlugins": {"discord@claude-plugins-official": True},
                "hooks": {"Stop": [{"hooks": [{"type": "command", "command": cmd, "timeout": 15}]}]}}
    f = sdir / "settings.json"
    f.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return f


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


def hook_stop(payload: dict[str, Any]) -> None:
    sdir = os.environ.get("DISCORD_STATE_DIR") or ""
    root = Path(str(payload.get("cwd") or "/nonexistent")).resolve()
    items = load_sessions()
    s = next((x for x in items if sdir and x.get("stateDir") == sdir), None) \
        or next((x for x in items if _same_root(x, root)), None)
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


def cmd_new(project: str, task: str, base: str = "", start: bool = True) -> dict[str, Any]:
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
        if tmux_alive(name):
            continue
        root = Path(str(s.get("root") or ""))
        if not s.get("root") or not root.is_dir():
            failed.append(f"{label}: 워크트리가 없어 건너뜀")
            continue
        try:
            if s.get("stateDir") and Path(str(s["stateDir"])).is_dir():
                write_settings(Path(str(s["stateDir"])))   # 업데이트로 바뀐 스크립트 경로를 다시 적는다
            tmux_start(name, root, claude_argv(str(s["project"]), str(s["task"]), resume=True),
                       session_env(Path(str(s.get("stateDir") or ""))), notify_ref=label)
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
    p = sub.add_parser("ls")
    p.add_argument("--json", action="store_true")
    for name in ("attach", "stop", "rm"):
        sub.add_parser(name).add_argument("ref")
    p = sub.add_parser("start")
    p.add_argument("ref", nargs="?", default="")
    p.add_argument("--all", action="store_true")
    sub.add_parser("hook-stop")
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
    if a.cmd == "notify-exit":
        try:   # 알림 실패가 아무것도 막지 않게
            notify_exit(a.ref, a.code)
        except Exception:
            pass
        return 0
    try:
        if a.cmd == "new":
            r = cmd_new(a.project, a.task, a.base, start=not a.no_start)
            print(f"✓ 세션: {r['project']}/{r['task']}")
            print(f"  Discord: {r['url']}")
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
            print(f"✓ 정리: {s['project']}/{s['task']} (워크트리는 그대로)")
    except SessionError as exc:
        print(f"marina session: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
