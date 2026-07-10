#!/usr/bin/env python3
"""marina PreToolUse(Bash) 판정기: 등록 프로젝트 안에서 dev 서버 직접 기동 명령이면 deny JSON 을 stdout 으로,
아니면 무출력(=allow). 어떤 오류든 무출력 exit 0 (fail-open) — marina 문제로 세션의 Bash 전체를 막지 않는다.
stdin: Claude Code PreToolUse JSON({tool_name, tool_input:{command}, cwd}).

`--is-registered <root>` 모드: 등록 판정을 SessionStart 훅과 **공유**한다(정책 이중화 방지).
exit 0=등록(project id stdout) · 1=확실 미등록 · 2=판정불가(레지스트리 깨짐 등 — 호출자는 침묵할 것)."""
import json
import os
import re
import subprocess
import sys

# dev 서버 직접 기동 패턴표 — 추가/삭제는 여기 한 줄. 조회성(config/ps/logs)·build·test 는 표에 없음 = 통과.
# 규칙: 셸 구분자 클래스에 \n 포함(멀티라인 명령이 문장 경계를 넘어 오탐 금지), 기동 동사 뒤는
# 경계 lookahead(?=$|[ \t\n;&|)]) — 'up.log' 같은 파일명 오탐 금지. (셀프 리뷰 반영)
_END = r"(?=$|[ \t\n;&|)])"
PATTERNS = [
    r"\bdocker([ \t]+|-)compose\b[^|;&\n]*[ \t](up|start|restart)" + _END,
    r"\b(npm|yarn|pnpm|bun)\b[^|;&\n]*\brun[ \t]+(dev|start|serve)\b",
    r"\b(npm|yarn|pnpm|bun)[ \t]+start" + _END,
    r"\b(next|nuxt|astro)[ \t]+dev\b",
    r"(^|[ \t;&|(])vite(?=$|[ \t\n])(?![ \t]+(build|preview)\b)",       # vite.config.ts 등 파일명 참조는 비대상
    r"\bgradlew?\b[^|;&\n]*[ \t](bootRun|run)" + _END,                  # --dry-run 은 [ \t] 요구로 비대상
    r"\bmvnw?\b[^|;&\n]*[ \t]spring-boot:run\b",
    r"\bmanage\.py[ \t]+runserver\b",
    r"\bflask[ \t]+run" + _END,
    r"(^|[\n;&|][ \t]*)((poetry|pipenv)[ \t]+run[ \t]+)?uvicorn[ \t]+\S",   # 문장 시작 한정 — 'pip install uvicorn …' 비대상
    r"\bpython3?[ \t]+-m[ \t]+uvicorn\b",
    r"\brails[ \t]+s(erver)?" + _END,
]

REASON = ("이 워크트리는 marina 가 관리합니다. dev 서버는 `marina start <서비스>` (전체 --all) 로 띄우세요 — "
          "포트가 워크트리별로 격리됩니다. 상태·실제 포트 `marina status` · 로그 `marina logs <서비스>` · "
          "정지 `marina stop <서비스>`. 정말 직접 실행해야 하면 명령 앞에 `MARINA_DIRECT=1 ` 를 붙이세요.")


def _projects_file() -> str:
    return os.path.join(os.environ.get("MARINA_HOME") or os.path.expanduser("~/.marina"), "projects.json")


def _strip_quoted(cmd: str) -> str:
    """따옴표 구간을 공백으로 치환 — `rg 'npm run dev' README.md`·`echo \"docker compose up\"` 같은
    검색/인용 텍스트가 기동 명령으로 오탐되지 않게(코덱스 P2). 닫히지 않은 따옴표는 그대로 둔다(보수적)."""
    return re.sub(r"'[^'\n]*'|\"[^\"\n]*\"", " ", cmd)


def classify_root(root: str, projects_file: str):
    """root 판정: ("registered", id) | ("unregistered", None) | ("unknown", None).
    레지스트리 파일 부재=확실 미등록(아무것도 등록 안 함), 파싱 실패=unknown(미등록 단정 금지 — 셀프 리뷰).
    매칭 규칙은 root 자신/하위 + codex 레이아웃 basename (구 세션훅 is_registered 와 동일, 이제 이 한 곳)."""
    try:
        with open(projects_file, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return ("unregistered", None)
    except Exception:
        return ("unknown", None)
    root = os.path.realpath(root)
    codex_wt = os.path.realpath(os.path.expanduser(os.environ.get("CODEX_WORKTREES_ROOT") or "~/.codex/worktrees"))
    in_codex = os.path.dirname(os.path.dirname(root)) == codex_wt  # <worktrees>/<id>/<basename>
    for p in data.get("projects", []):
        pr = os.path.realpath(os.path.expanduser(p.get("root", "")))
        if not pr:
            continue
        if root == pr or root.startswith(pr + os.sep) or (in_codex and os.path.basename(root) == os.path.basename(pr)):
            return ("registered", str(p.get("id", "")))
    return ("unregistered", None)


def main() -> int:
    if len(sys.argv) >= 3 and sys.argv[1] == "--is-registered":     # SessionStart 훅 공유 진입점
        state, pid = classify_root(sys.argv[2], _projects_file())
        if state == "registered":
            print(pid)
            return 0
        return 1 if state == "unregistered" else 2
    try:
        d = json.load(sys.stdin)
    except Exception:
        return 0
    tn = d.get("tool_name")
    if tn is not None and not any(k in str(tn).lower() for k in ("bash", "shell", "exec")):   # 플랫폼별 셸 툴명 차이 허용(Codex 등)
        return 0
    cmd = str((d.get("tool_input") or {}).get("command") or "")
    if not cmd or "MARINA_DIRECT=1" in cmd:                        # 의도적 직접 실행 탈출구
        return 0
    bare = _strip_quoted(cmd)                                      # 따옴표 안(검색어·인용)은 판정 비대상
    if not any(re.search(p, bare) for p in PATTERNS):              # 싼 검사 먼저 — git/파일 IO 전에
        return 0
    cwd = d.get("cwd") or os.getcwd()
    try:
        root = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                              capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return 0
    if not root:
        return 0
    if classify_root(root, _projects_file())[0] != "registered":   # unknown 은 차단하지 않음(fail-open)
        return 0
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "permissionDecision": "deny",
                                             "permissionDecisionReason": REASON}}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
