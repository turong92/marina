"""코덱스 방(kind "codex") 전용 코드 — 스펙 docs/superpowers/specs/2026-10-21-codex-rooms-design.md.

클로드 방과 다른 지점(띄우기 인자·env·막는 화면 검사 …)만 여기에 둔다. 방 기록·상태 폴더·tmux·Discord 인프라는
marina_session 이 그대로 쓴다. marina_session 은 이 모듈을 함수 안에서 늦게 import 한다(순환 방지).
값(트러스트·훅 인자·막는 화면 문구)은 스파이크 실측(스펙 "실측 결과", codex-cli 0.146)."""
from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

import marina_session as ms

KIND = "codex"
DEFAULT_CATEGORY = "chat-bot"
DEFAULT_ACCOUNT = "b"

# 이 화면이 남아 있으면 입력이 조용히 삼켜진다(S1)
PANE_BLOCKING = ("Update available", "Do you trust the contents of this directory", "Hooks need review")

CODEX_RULES = (
    "이 세션은 Discord 채널에 연결돼 있다. 상대는 Discord 만 보고 이 터미널은 보지 않는다.\n"
    "- 받은 메시지는 <channel … chat_id=\"…\" message_id=\"…\"> 태그로 온다. 답은 반드시 marina MCP 의 "
    "mcp__marina__reply 로 보낸다(chat_id 는 받은 태그의 것, 지시에 대한 끝 보고·답은 reply_to = 그 지시의 message_id).\n"
    "- 결과·질문·실패/막힘·완료는 reply 로 보낸다. 아직 안 끝난 중간 보고는 mcp__marina__progress "
    "(message_id = 지시 메시지 ID)로 한 줄 남긴다(알림 없음). 짧은 답은 progress 없이 reply 만.\n"
    "- 이미지는 첨부한다. 10MB 를 넘는 파일은 링크로 보낸다.\n"
    "- 상대가 볼 결과물(스펙·보고서 md, HTML·목업, 스크린샷)을 만들면 mcp__marina__share_file 에 넘기고, "
    "돌려받은 미리보기 파일을 reply 로 첨부하며 열어보기 주소를 reply 본문에 넣는다.\n"
    "- 터미널에서 직접 받은 지시의 답은 터미널에 둬도 된다."
)


def codex_cfg(cfg: dict[str, Any]) -> dict[str, Any]:
    """discord.json 최상위 "codex" 에 기본값(category·account)을 채운 사본. categoryId 는 있을 때만."""
    raw = cfg.get("codex") if isinstance(cfg.get("codex"), dict) else {}
    out = dict(raw)
    out["category"] = str(raw.get("category") or DEFAULT_CATEGORY)
    out["account"] = str(raw.get("account") or DEFAULT_ACCOUNT)
    return out


def codex_home(account: str) -> Path:
    return ms.marina_home() / "accounts" / f"codex-{account}"


def _q(value: str) -> str:
    """TOML 기본 문자열(JSON 문자열 인용이 그대로 TOML 이다)."""
    return json.dumps(value, ensure_ascii=False)


def trust_args(root: str) -> list[str]:
    """폴더 신뢰 -c — 점 경로(projects."x".trust_level)는 안 먹고 표 형태만 먹는다(S1)."""
    return ["-c", f'projects={{{_q(os.path.realpath(root))}={{trust_level="trusted"}}}}']


def _mcp_env(sdir: Path) -> dict[str, str]:
    """MCP 서버는 코덱스 env 를 물려받지 않는다(S4) — 서버가 쓸 변수는 env 칸에 따로 적는다."""
    env = {"DISCORD_STATE_DIR": str(sdir), "MARINA_HOME": str(ms.marina_home())}
    for k in ("MARINA_DISCORD_API", "MARINA_CHANNELS_DIR", "MARINA_CODEX_SESSIONS"):
        if os.environ.get(k):
            env[k] = os.environ[k]
    return env


def mcp_args(sdir: Path) -> list[str]:
    entry = ms._hook_entry()
    args = ", ".join(_q(a) for a in entry[1:] + ["mcp-chat"])
    env = ", ".join(f"{k}={_q(v)}" for k, v in _mcp_env(sdir).items())
    return ["-c", f"mcp_servers.marina={{command={_q(entry[0])},args=[{args}],env={{{env}}}}}"]


def rules_args() -> list[str]:
    return ["-c", f"developer_instructions={_q(CODEX_RULES)}"]


def hook_args(sdir: Path) -> list[str]:
    """인라인 훅(-c hooks={…}) — 훅 하위명령은 Task 5 가 채운다."""
    return []


def codex_argv(rec: dict[str, Any], resume: bool = False, first: str = "") -> list[str]:
    """codex 는 sid 를 미리 못 정한다 — sid 가 있고 resume 일 때만 `resume <sid>`, 아니면 새 대화(S7)."""
    sid = str(rec.get("sessionId") or "")
    sdir = Path(str(rec.get("stateDir") or ""))
    root = str(rec.get("root") or "")
    argv = ["codex"]
    if resume and sid:
        argv += ["resume", sid]
    argv += ["-C", root, "-a", "never", "-c", "check_for_update_on_startup=false",
             *trust_args(root), "--dangerously-bypass-hook-trust",
             *mcp_args(sdir), *rules_args(), *hook_args(sdir)]
    if first:
        argv.append(first)
    return argv


def codex_env(sdir: Path, account: str) -> dict[str, str]:
    """clean_env_prefix 에 더할 변수 — 클로드 토큰 변수는 넣지 않는다."""
    env = _mcp_env(sdir)
    env["CODEX_HOME"] = str(codex_home(account))
    return env


def boot_check(tmux: str, timeout: "float | None" = None) -> str:
    """막는 화면 문구가 보이면 그 문구, 입력창(›)이 먼저 보이거나 시간이 다 되면 ""."""
    wait = float(os.environ.get("MARINA_CODEX_BOOT_WAIT") or 8.0) if timeout is None else timeout
    deadline = time.time() + wait
    while True:
        screen = ms._tmux("capture-pane", "-p", "-t", tmux).stdout or ""
        for phrase in PANE_BLOCKING:
            if phrase in screen:
                return phrase
        if any(line.startswith("› ") for line in screen.splitlines()) or time.time() >= deadline:
            return ""
        time.sleep(0.3)
