#!/usr/bin/env bash
# A — Claude Code CLI 트랜스크립트(~/.claude/projects/<slug>/<sid>.jsonl)에서 세션 발견.
# Desktop local_*.json 없이도, cwd 필드로 worktree 매핑 + 파일 stem = 진짜 sid.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

PROJ_DIR="$TMP/claude-projects"
WT="$TMP/worktree-a"; mkdir -p "$WT" "$PROJ_DIR"

python3 - "$SCR" "$PROJ_DIR" "$WT" <<'PY'
import sys, os, json, time, re
scr, proj_dir, wt = sys.argv[1:4]
os.environ["CLAUDE_PROJECTS_DIR"] = proj_dir
os.environ["CLAUDE_DESKTOP_SESSIONS_DIR"] = os.path.join(os.path.dirname(proj_dir), "no-desktop")
sys.path.insert(0, scr)
import marina_sessions as ms
from pathlib import Path

# 가짜 CLI 트랜스크립트: slug 디렉토리 + <sid>.jsonl, 라인들에 cwd/aiTitle
slug = re.sub(r"[/.]", "-", wt)
d = Path(proj_dir) / slug; d.mkdir(parents=True, exist_ok=True)
sid = "43d8240a-9462-47e4-9877-52cc758e6a0f"
lines = [
    {"type": "last-prompt"},                     # cwd 없는 선두 라인 — 건너뛰어야
    {"type": "attachment", "cwd": wt, "aiTitle": "세션 제목"},
    {"type": "user", "cwd": wt, "message": {"role": "user", "content": "안녕"}},
]
(d / f"{sid}.jsonl").write_text("\n".join(json.dumps(o) for o in lines) + "\n", encoding="utf-8")

now = time.time()
out = ms._claude_cli_sessions(now, now - ms.AGENTS_MAX_AGE)
key = str(Path(wt))
assert key in out, f"worktree 미발견: {list(out)}"
entry = out[key][0]
assert entry["source"] == "claude", entry
assert entry["cliSessionId"] == sid, f"진짜 sid 아님: {entry['cliSessionId']}"
assert entry["title"] == "세션 제목", entry["title"]
print("OK A-discovery")

# title 폴백: aiTitle 없을 때 lastPrompt 를 쓰되 cd/경로/순수 셸명령은 걷어낸다(지저분 방지).
def title_of(*lines):
    import tempfile
    p = Path(tempfile.mktemp(suffix=".jsonl"))
    p.write_text("\n".join(json.dumps(o) for o in lines) + "\n", encoding="utf-8")
    return ms._read_transcript_title(p)

assert title_of({"aiTitle": "영천시 날씨"}) == "영천시 날씨", "aiTitle 우선 실패"
assert title_of({"lastPrompt": "영천시 날씨 자동화 해줘"}) == "영천시 날씨 자동화 해줘", "자연어 lastPrompt 보존 실패"
assert title_of({"lastPrompt": "cd ~/.codex/worktrees/3b58/marina"}) == "", "cd 노이즈 미제거"
assert title_of({"lastPrompt": "~/.codex/worktrees/3b58/marina"}) == "", "경로 노이즈 미제거"
assert title_of({"lastPrompt": "git commit -m x"}) == "", "셸명령 노이즈 미제거"
print("OK title 폴백 셸노이즈 정제")
PY
echo "PASS test-claude-cli-discovery"
