#!/usr/bin/env bash
# 역할 = 에이전트 정의 파일 한 장. 찾는 순서·하네스 변환·연결 계약(스펙 4절).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import tempfile
from pathlib import Path
import marina_roles as R

md = """---
name: code-reviewer
description: "Senior reviewer. Read-only."
tools: Read, Grep, Glob, Bash(git diff:*), Bash(git log:*), Edit, Write
model: sonnet
---

You are a senior reviewer.
"""
d = R.parse_definition(md)
assert d["name"] == "code-reviewer" and d["model"] == "sonnet", d
assert d["tools"] == ["Read", "Grep", "Glob", "Bash(git diff:*)", "Bash(git log:*)", "Edit", "Write"], d["tools"]
assert d["body"] == "You are a senior reviewer.", repr(d["body"])
assert R.split_tools("Bash(a, b), Read") == ["Bash(a, b)", "Read"]          # 괄호 안 쉼표 보존
assert R.parse_definition("no frontmatter")["body"] == "no frontmatter"

allowed, dropped = R.role_tools(d)
assert "Edit" not in allowed and "Write" not in allowed and set(dropped) == {"Edit", "Write"}, (allowed, dropped)
assert allowed[-2:] == ["ToolSearch", "SendMessage"], allowed                  # 실측: SendMessage 는 ToolSearch 로 불러온다
assert R.role_tools({"tools": ["Read", "SendMessage"]})[0].count("SendMessage") == 1

argv = R.role_cli(d, "첫 프롬프트")
assert argv[:2] == ["claude", "첫 프롬프트"], argv                            # 가변 인자 앞
assert argv[argv.index("--permission-mode") + 1] == "plan"
assert argv[argv.index("--model") + 1] == "sonnet"
assert argv[argv.index("--append-system-prompt") + 1] == "You are a senior reviewer."
i = argv.index("--allowedTools"); j = argv.index("--append-system-prompt")
assert argv[i + 1:j] == allowed, argv
launch = R.role_cli(d, "")
assert "첫 프롬프트" not in launch and launch[1] == "--model", launch
assert "--model" not in R.role_cli({**d, "model": ""}, "p")

# 찾는 순서: project > user > marina
tmp = Path(tempfile.mkdtemp()); root = tmp / "wt"; home = tmp / "home"
assert R.find_role(root, "reviewer", home=home)[1] == "marina"                 # 기본 역할 파일이 있다
(home / ".claude/agents").mkdir(parents=True); (home / ".claude/agents/reviewer.md").write_text(md)
assert R.find_role(root, "reviewer", home=home)[1] == "user"
(root / ".claude/agents").mkdir(parents=True); (root / ".claude/agents/reviewer.md").write_text(md)
assert R.find_role(root, "reviewer", home=home)[1] == "project"
for bad in ("../x", "Reviewer", "", "a/b"):
    assert R.find_role(root, bad, home=home) is None, bad                       # 경로 탈출·이상한 이름 거부
loaded = R.load_role(root, "reviewer", home=home)
assert loaded["origin"] == "project" and loaded["path"].endswith("reviewer.md")

base = R.load_role(tmp / "none", "reviewer", home=tmp / "nohome")
assert base["origin"] == "marina" and base["model"] == "claude-sonnet-5" and base["body"], base

c = R.contract_prompt(role="reviewer", repos={"marina": ("cb675c6", "e04dc5f")},
                      reply_socket="uds:/tmp/cc-socks/3741.sock", round_no=1, unlimited=False)
for need in ('"uds:/tmp/cc-socks/3741.sock"', "cb675c6..e04dc5f", "새 지적 없음", "SendMessage", "고치지"):   # 따옴표째 정확한 소켓 주소
    assert need in c, (need, c)
assert "[보류]" not in c                                                         # 무제한일 때만
c2 = R.contract_prompt(role="reviewer", repos={"a": ("1", "2"), "b/c": ("3", "4")}, reply_socket="uds:/x",
                       round_no=2, unlimited=True, previous="지적 요약")
assert "[보류]" in c2 and "b/c" in c2 and "지적 요약" in c2 and "2바퀴" in c2, c2
print("PASS: 역할 정의·하네스·연결 계약")
PY
