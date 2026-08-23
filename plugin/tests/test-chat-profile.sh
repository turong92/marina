#!/usr/bin/env bash
# 프로젝트별 **채팅 프로필** — 형: "특정 프로젝트만 그렇게 세팅 할 수 있나?".
#
# **왜.** Claude Code 세션은 잡담에도 도구·MCP·플러그인 스키마를 통째로 싣는다. 실측(2026-08-24,
# `claude -p "안녕" --output-format json`):
#     마리나 레포에서            ~46,700 토큰 (읽기 27,540 + 쓰기 19,200)
#     빈 폴더, 기본값            ~25,600
#     빈 폴더 + settings.json    ~24,000   ← 설정 파일로는 거의 안 준다
#     빈 폴더 + --strict-mcp-config --tools Read   ~6,500
# 설정 파일이 안 먹는 이유: 그 MCP 키들은 프로젝트 .mcp.json 서버에만 적용되고(사용자 스코프
# MCP 는 그대로), 무엇보다 **내장 도구 스키마**가 계속 실린다. 실제로 깎는 건 CLI 플래그다.
#
# 그래서 마리나가 명령을 조립할 때 프로젝트 프로필을 보고 플래그를 붙인다. 파일 첨부를 읽고
# 결과를 파일로 주려면 Read·Write 는 남긴다(형: "파일 넣어서 분석시키고 결과도 받고").
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import marina_term as mt

# ① 채팅 프로필: MCP 를 끊고 도구를 Read·Write 로 좁힌다.
채팅 = mt._agent_cli("claude", "", "", "", "", profile="chat")
assert "--strict-mcp-config" in 채팅, 채팅
i = 채팅.index("--tools")
도구 = 채팅[i + 1:i + 3]
assert 도구 == ["Read", "Write"], 채팅
# 모델·추론강도는 그대로 먹어야 한다 — 형: "모델 바꾸거나".
모델 = mt._agent_cli("claude", "", "", "claude-sonnet-5", "high", profile="chat")
assert "--model" in 모델 and "claude-sonnet-5" in 모델 and "--effort" in 모델, 모델

# ② 개발 방은 **하나도 안 바뀐다**.
개발 = mt._agent_cli("claude", "", "", "", "")
assert "--strict-mcp-config" not in 개발 and "--tools" not in 개발, 개발
assert 개발 == ["claude"], 개발

# ③ 이어가기(resume)에도 같은 프로필이 붙는다 — 붙었다 안 붙었다 하면 방마다 무게가 널뛴다.
이어 = mt._agent_cli("claude", "11111111-2222-3333-4444-555555555555", "", "", "", profile="chat")
assert "--strict-mcp-config" in 이어 and "--resume" in 이어, 이어

# ④ codex 는 아직 프로필이 없다 — 조용히 다른 플래그를 지어내지 않는다.
코덱스 = mt._agent_cli("codex", "", "", "", "", profile="chat")
assert 코덱스 == ["codex"], 코덱스
print("ok 채팅 프로필: MCP 끊고 도구 Read·Write · 모델은 그대로 · 개발 방 무영향")
PY

# ⑤ 레지스트리가 프로필을 읽고, 방을 열 때 그 프로필이 실린다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY2'
import inspect
import sys

import marina_registry as reg
import marina_term as mt

원본 = inspect.getsource(reg.load_projects)
assert '"profile"' in 원본, "프로젝트가 프로필을 안 읽는다"
연다 = inspect.getsource(mt.term_open)
assert "profile" in 연다, "방을 열 때 프로필을 안 본다"
assert "project_for" in 연다 or "_project_profile" in 연다, "프로필을 어디서 가져오는지 없다"
print("ok 레지스트리→실행 배선")
PY2

# ⑥ 등록부터 실행까지 실제로 이어지나 — `marina project add --profile chat`.
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
CHAT="$TMP/잡담"; mkdir -p "$CHAT"
bash "$SH" project add "$CHAT" --profile chat >/dev/null
PYTHONPATH="$SCR" python3 - "$CHAT" <<'PY3'
import sys
from pathlib import Path

import marina_registry as reg
import marina_term as mt

reg._projects_cache.clear()
project = reg.project_for(Path(sys.argv[1]))
assert project and project.get("profile") == "chat", project
assert mt._project_profile(Path(sys.argv[1])) == "chat", "실행 경로가 프로필을 못 읽는다"

# 개발 프로젝트는 그대로 빈 값 — 기존 등록에 영향이 없어야 한다.
보통 = Path(sys.argv[1]).parent / "개발"
보통.mkdir(exist_ok=True)
print("ok 등록(--profile chat) → 실행 프로필까지 이어진다")
PY3

echo "PASS test-chat-profile"
