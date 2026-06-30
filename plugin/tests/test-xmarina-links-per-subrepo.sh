#!/usr/bin/env bash
# 서브레포별 x-marina.links: {<sub>:{symlink,copy}} → 그 서브레포에만 적용·표시.
# 예: ai-api 만 .venv(python), be-api(java)엔 .venv 안 잡힘. workspace `marina link` 가 각 서브레포로 재귀 적용.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
SRC="$TMP/src"; P="$TMP/wt"

# main(SOURCE_ROOT): 서브레포 be-api(java)·ai-api(python)
mkdir -p "$SRC/be-api/src/main/resources" "$SRC/ai-api/.venv/bin" "$SRC/ai-api"
echo y > "$SRC/be-api/src/main/resources/application-local.yml"
echo v > "$SRC/ai-api/.venv/bin/python"
echo a > "$SRC/ai-api/application-ai-local.yml"
# worktree(ROOT) — 서브레포 dst + compose(서브레포별 x-marina.links)
mkdir -p "$P/be-api" "$P/ai-api"
cat > "$P/docker-compose.yml" <<'YAML'
services:
  batch:
    build: { context: ./be-api }
  index-api:
    build: { context: ./ai-api }
x-marina:
  links:
    be-api:
      copy: ["**/*local.yml"]
    ai-api:
      symlink: [".venv"]
      copy: ["**/*local.yml"]
YAML
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" >/dev/null
mrun() { (cd "$P" && MARINA_HOME="$MARINA_HOME" SOURCE_ROOT="$SRC" bash "$SH" "$@"); }

# 1) workspace `marina link` → 각 서브레포로 재귀 적용
mrun link >/dev/null 2>&1
# ai-api: .venv 심링크 + config 복제
[[ -L "$P/ai-api/.venv" ]] || { echo "FAIL: ai-api/.venv 심링크 안 됨"; exit 1; }
[[ -f "$P/ai-api/application-ai-local.yml" && ! -L "$P/ai-api/application-ai-local.yml" ]] || { echo "FAIL: ai-api config 복제 안 됨"; exit 1; }
# be-api: config 복제, 그러나 .venv 는 안 잡힘(서브레포별이라 be-api 엔 .venv 정의 없음)
[[ -f "$P/be-api/src/main/resources/application-local.yml" ]] || { echo "FAIL: be-api config 복제 안 됨"; exit 1; }
[[ ! -e "$P/be-api/.venv" ]] || { echo "FAIL: be-api 에 .venv 가 잡힘(서브레포별 스코프 깨짐)"; exit 1; }

# 2) 대시보드 표시(links-json) — be-api 탭엔 .venv 없음, ai-api 탭엔 .venv 있음
be_json="$(cd "$P" && MARINA_HOME="$MARINA_HOME" SOURCE_ROOT="$SRC" bash "$SH" links-json batch be-api)"
echo "$be_json" | python3 -c "
import json,sys
names=[l['name'] for l in json.load(sys.stdin)]
assert '.venv' not in names, ('be-api 탭에 .venv 가 뜸', names)
assert any('local.yml' in n for n in names), ('be-api 탭에 config 없음', names)
" || { echo "FAIL: be-api 탭 표시 (.venv 빠져야)"; echo "$be_json"; exit 1; }
ai_json="$(cd "$P" && MARINA_HOME="$MARINA_HOME" SOURCE_ROOT="$SRC" bash "$SH" links-json index-api ai-api)"
echo "$ai_json" | python3 -c "
import json,sys
names=[l['name'] for l in json.load(sys.stdin)]
assert '.venv' in names, ('ai-api 탭에 .venv 없음', names)
" || { echo "FAIL: ai-api 탭 표시 (.venv 있어야)"; echo "$ai_json"; exit 1; }

echo "PASS test-xmarina-links-per-subrepo"
