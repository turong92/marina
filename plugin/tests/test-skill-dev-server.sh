#!/usr/bin/env bash
# dev-server 스킬: SKILL.md 존재 + frontmatter(name/description) + 핵심 명령 포함 스모크
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
F="$HERE/../skills/dev-server/SKILL.md"
[[ -f "$F" ]] || { echo "FAIL: SKILL.md 없음"; exit 1; }
head -1 "$F" | grep -qx -- '---' || { echo "FAIL: frontmatter 시작 없음"; exit 1; }
grep -q '^name: dev-server$' "$F" || { echo "FAIL: name"; exit 1; }
grep -q '^description: .*dev server' "$F" || { echo "FAIL: description 트리거 문구"; exit 1; }
grep -q 'marina start' "$F" || { echo "FAIL: marina start 안내 없음"; exit 1; }
grep -q 'MARINA_DIRECT=1' "$F" || { echo "FAIL: 탈출구 안내 없음"; exit 1; }
echo "PASS test-skill-dev-server"
