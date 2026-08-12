#!/usr/bin/env bash
# 다른 앱 데이터 읽기 차단 — 의지가 아니라 기계로 막는다.
#
# **왜.** macOS TCC 모달이 뜨는데 Claude Code CLI 는 .app 번들이 아니라 버전 경로의 맨 실행파일이라
# 허용이 저장되지 않는다(anthropics/claude-code #66216·#59608). 업데이트마다 경로가 바뀌어 매번
# 새 앱 취급이고, ClaudeCode.app 에 전체 디스크 접근을 줘도 안 통한다(검증됨).
# 성가심보다 나쁜 건 **원격 사용 중 정지**다 — 화면 앞에 아무도 없으면 모달에 답할 수가 없어
# 프로세스가 그대로 선다. 형: "니가 안 읽는다고 안 읽을 수 있나? 하다보면 건드리게되는건데".
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK="$HERE/../scripts/marina-appdata-guard-hook.sh"

decide() { printf '%s' "$1" | bash "$HOOK" 2>/dev/null; }

# ① 다른 앱 데이터는 막는다 — Read 의 file_path.
out="$(decide '{"tool_input":{"file_path":"'"$HOME"'/Library/Application Support/Claude/git-worktrees.json"}}')"
echo "$out" | grep -q '"permissionDecision": *"deny"' || { echo "FAIL: 앱 데이터를 안 막음: $out"; exit 1; }
# 왜 막혔는지 사람이 읽을 수 있어야 한다 — 아니면 다음에 또 우회하려 든다.
echo "$out" | grep -q "마리나 데몬" || { echo "FAIL: 대안 안내가 없음"; exit 1; }

# ② Grep/Glob 의 path 키도 같은 문이다(도구마다 키 이름이 다르다 — 하나만 막으면 샌다).
out="$(decide '{"tool_input":{"path":"'"$HOME"'/Library/Application Support/Slack"}}')"
echo "$out" | grep -q '"deny"' || { echo "FAIL: path 키를 안 봄"; exit 1; }

# ③ 무관한 경로는 **건드리지 않는다**. 과차단하면 훅을 꺼버리게 되고 그럼 보호가 사라진다.
for ok in "/Users/sumin/IdeaProjects/sumin/marina/README.md" "$HOME/.marina/projects.json" "$HOME/.claude/settings.json"; do
  out="$(decide '{"tool_input":{"file_path":"'"$ok"'"}}')"
  [ -z "$out" ] || { echo "FAIL: 무관한 경로를 막음($ok): $out"; exit 1; }
done

# ④ 경로가 없는 호출(Bash 등)에 끼어들지 않는다.
[ -z "$(decide '{"tool_input":{"command":"ls"}}')" ] || { echo "FAIL: 경로 없는 호출에 개입"; exit 1; }
# ⑤ 깨진 입력에도 죽지 않는다 — 훅이 죽으면 도구가 통째로 막힌다.
[ -z "$(decide 'not json at all')" ] || { echo "FAIL: 깨진 입력에 개입"; exit 1; }

# ⑥ hooks.json 에 등록돼 있어야 실제로 돈다.
python3 - "$HERE/../hooks/hooks.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
pre = d["hooks"]["PreToolUse"]
hit = [e for e in pre if "appdata-guard" in json.dumps(e)]
assert hit, "hooks.json 에 appdata guard 가 등록되지 않았다"
assert "Read" in hit[0]["matcher"] and "Grep" in hit[0]["matcher"], f"matcher 가 좁다: {hit[0]['matcher']}"
PY

echo "PASS test-appdata-guard"
