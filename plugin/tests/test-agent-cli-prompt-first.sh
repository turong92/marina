#!/usr/bin/env bash
# 첫 프롬프트는 argv 에서 `claude` 바로 뒤 — 가변 인자 플래그(--tools/--allowedTools)가 뒤 값을 삼킨다.
# 실측 2026-09-10: lean + 프롬프트(모델·effort 없음) = ['claude','--strict-mcp-config','--tools','Read','Write','첫 프롬프트'].
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import marina_term as T
p = "첫 프롬프트"
for profile, lean in (("", True), ("chat", False), ("chat", True), ("", False)):
    argv = T._agent_cli("claude", "", p, "", "", profile, lean)
    assert argv[:2] == ["claude", p], f"프롬프트가 맨 앞이 아니다(profile={profile!r} lean={lean}): {argv}"
    assert argv.count(p) == 1, argv
# resume 도 순서와 무관하게 동작해야 한다
argv = T._agent_cli("claude", "sid0001", p, "claude-opus-5", "high", "", True)
assert argv[:2] == ["claude", p] and argv[argv.index("--resume") + 1] == "sid0001", argv
# 프롬프트 없으면 그대로
assert T._agent_cli("claude", "", "", "", "", "", True)[0] == "claude"
assert "첫 프롬프트" not in T._agent_cli("claude", "", "", "", "", "", True)
print("PASS: 첫 프롬프트는 claude 바로 뒤")
PY
