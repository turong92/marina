"""역할 = 에이전트 정의 파일 한 장. 찾기·파싱·역할 방 하네스(argv)·연결 계약.

스펙: docs/superpowers/specs/2026-09-10-role-rooms-chain-design.md 4절.
새 형식을 만들지 않는다 — Claude 서브에이전트 파일(name·description·tools·model + 본문)을 그대로 쓴다.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import Any

# 첫 버전 역할은 읽기 전용이다. 정의에 편집 도구가 있어도 뺀다(plan 모드가 막지만 두 겹으로).
EDIT_TOOLS = {"Edit", "Write", "NotebookEdit", "MultiEdit"}
# SendMessage 는 지연 로드 도구라 ToolSearch 로 불러와야 쓴다(실측 2026-09-10).
ALWAYS_TOOLS = ("ToolSearch", "SendMessage")
_ROLE_NAME_RE = re.compile(r"[a-z][a-z0-9-]{0,40}")
_META_RE = re.compile(r"^([A-Za-z_][\w-]*):\s*(.*?)\s*$")


def plugin_dir() -> Path:
    """플러그인 루트(scripts/ 의 부모)."""
    return Path(__file__).resolve().parent.parent


def split_tools(raw: str) -> list[str]:
    """`Read, Grep, Bash(git diff:*)` → 낱말 목록. 괄호 안 쉼표는 쪼개지 않는다."""
    out: list[str] = []
    cur: list[str] = []
    depth = 0
    for ch in raw or "":
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
        if ch == "," and depth == 0:
            word = "".join(cur).strip()
            if word:
                out.append(word)
            cur = []
            continue
        cur.append(ch)
    word = "".join(cur).strip()
    if word:
        out.append(word)
    return out


def parse_definition(text: str) -> dict[str, Any]:
    """프론트매터(한 줄짜리 `키: 값`만) + 본문. 닫는 `---` 가 없으면 전체를 본문으로 본다."""
    meta: dict[str, str] = {}
    body = text or ""
    lines = body.splitlines()
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                body = "\n".join(lines[i + 1:])
                break
            match = _META_RE.match(lines[i])
            if match:
                meta[match.group(1)] = match.group(2).strip().strip("'\"")
    return {
        "name": meta.get("name", ""),
        "description": meta.get("description", ""),
        "model": meta.get("model", ""),
        "tools": split_tools(meta.get("tools", "")),
        "body": body.strip(),
    }


def find_role(root: Path, role: str, home: Path | None = None) -> tuple[Path, str] | None:
    """찾는 순서: 프로젝트 → 사용자 → 마리나 기본. 이름이 규칙에 안 맞으면 None(경로 탈출 차단)."""
    if not _ROLE_NAME_RE.fullmatch(role or ""):
        return None
    home = home if home is not None else Path.home()
    candidates = (
        (Path(root) / ".claude" / "agents" / f"{role}.md", "project"),
        (home / ".claude" / "agents" / f"{role}.md", "user"),
        (plugin_dir() / "roles" / f"{role}.md", "marina"),
    )
    for path, origin in candidates:
        if path.is_file():
            return path, origin
    return None


def load_role(root: Path, role: str, home: Path | None = None) -> dict[str, Any] | None:
    found = find_role(root, role, home)
    if found is None:
        return None
    path, origin = found
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    return {**parse_definition(text), "path": str(path), "origin": origin}


def role_tools(defn: dict[str, Any]) -> tuple[list[str], list[str]]:
    """(허용 도구, 뺀 편집 도구). 편집 도구는 `Edit` 처럼 이름만, `Edit(...)` 처럼 괄호가 붙어도 뺀다."""
    allowed: list[str] = []
    dropped: list[str] = []
    for tool in defn.get("tools") or []:
        bare = tool.split("(", 1)[0].strip()
        if bare in EDIT_TOOLS:
            dropped.append(tool)
        elif tool not in allowed:
            allowed.append(tool)
    for tool in ALWAYS_TOOLS:
        if tool in allowed:
            allowed.remove(tool)
        allowed.append(tool)
    return allowed, dropped


def role_cli(defn: dict[str, Any], prompt: str) -> list[str]:
    """역할 방 argv. **프롬프트는 claude 바로 뒤** — --allowedTools 가 뒤따르는 값을 삼킨다.
    prompt 가 빈 문자열이면 저장용 launch(프롬프트 없는 argv)를 만든다."""
    cmd = ["claude", prompt] if prompt else ["claude"]
    if defn.get("model"):
        cmd += ["--model", str(defn["model"])]
    cmd += ["--permission-mode", "plan"]
    allowed, _ = role_tools(defn)
    cmd += ["--allowedTools", *allowed]
    if defn.get("body"):
        cmd += ["--append-system-prompt", str(defn["body"])]
    return cmd


def contract_prompt(*, role: str, repos: dict[str, tuple[str, str]], reply_socket: str,
                    round_no: int, unlimited: bool, previous: str = "") -> str:
    """마리나가 역할 방 요청마다 붙이는 연결 계약(스펙 4.3). 정의 본문과 별개로 역할이 무엇이든 같다."""
    범위 = "\n".join(f"- `{name}`: `git diff {base}..{head}` + 커밋 안 한 변경(staged·unstaged)"
                   for name, (base, head) in repos.items())
    lines = [
        f"[마리나 · {role} · {round_no}바퀴]",
        "검토 범위(저장소 경로는 이 워크트리 기준):",
        범위,
        "",
        "규칙:",
        f'- 결과는 **한 번의** SendMessage 로 보낸다. to 는 정확히 "{reply_socket}" (이름 말고 이 주소).',
        "- 지적할 게 없으면 메시지 마지막 줄을 정확히 `새 지적 없음` 으로 쓴다.",
        "- 파일은 절대 고치지 않는다. 읽고 지적만 한다.",
    ]
    if unlimited:
        lines.append("- 지난 바퀴에 이미 한 지적과 같은 것은 줄 머리를 `[보류]` 로 시작한다(다시 설명하지 않는다).")
    if previous:
        lines += ["", "지난 바퀴 요약:", previous]
    return "\n".join(lines)
