#!/usr/bin/env bash
# glob 링크: 기본 룰(node_modules·.venv·*local.yml·.env*.local)이 main(SOURCE_ROOT)→worktree(ROOT) 로 symlink.
# 빌드출력(build·.next·dist·out·target)은 기본 제외(독립 빌드) — 가져오려면 x-marina.links 에 명시.
# attach 의 숨은 sync 대체 — 보임(marina config)·override(null)로 끔·marina link 로 수동·source==dest 면 skip.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
SRC="$TMP/src"; P="$TMP/wt"
# main(SOURCE_ROOT): heavy/gitignored — node_modules(중첩 포함)·.venv·빌드출력(build·.next, PRUNE 대상)·configs·env
mkdir -p "$SRC/node_modules/dep" "$SRC/.venv/bin" "$SRC/sub/node_modules" "$SRC/build/libs" "$SRC/.next" "$SRC/src/main/resources"
echo m > "$SRC/node_modules/dep/i.js"; echo v > "$SRC/.venv/bin/python"
echo j > "$SRC/build/libs/app.jar"
echo y > "$SRC/src/main/resources/app-local.yml"; echo e > "$SRC/.env.local"
# worktree(ROOT)
mkdir -p "$P"; echo keep > "$P/keep.txt"
cat > "$P/marina-services.json" <<'JSON'
{"services":[{"name":"app","portBase":8712,"cwd":".","run":"exec sleep 30"}]}
JSON
bash "$SH" project add "$P" >/dev/null
mrun() { (cd "$P" && MARINA_HOME="$MARINA_HOME" SOURCE_ROOT="$SRC" bash "$SH" "$@"); }
SDIR="$(mrun print-session-dir)"; mkdir -p "$SDIR"

# 1) marina link 가 기본 glob 룰을 main→worktree symlink
mrun link >/dev/null 2>&1
[[ -L "$P/node_modules" ]] || { echo "FAIL: node_modules not linked"; exit 1; }
[[ -L "$P/sub/node_modules" ]] || { echo "FAIL: nested node_modules not linked"; exit 1; }
[[ -L "$P/.venv" ]] || { echo "FAIL: .venv not linked"; exit 1; }
[[ ! -e "$P/build" ]] || { echo "FAIL: build(빌드출력) 자동링크됨 — 기본 제외여야(독립 빌드)"; exit 1; }
[[ ! -e "$P/.next" ]] || { echo "FAIL: .next(빌드출력) 자동링크됨 — 기본 제외여야"; exit 1; }
[[ -L "$P/src/main/resources/app-local.yml" ]] || { echo "FAIL: local.yml not linked"; exit 1; }
[[ -L "$P/.env.local" ]] || { echo "FAIL: .env.local not linked"; exit 1; }
[[ -f "$P/keep.txt" && ! -L "$P/keep.txt" ]] || { echo "FAIL: real file clobbered"; exit 1; }
[[ "$(cat "$P/node_modules/dep/i.js")" == m ]] || { echo "FAIL: symlink content unreachable"; exit 1; }

# 2) override null 로 node_modules 만 끔 (.venv 는 계속)
mkdir -p "$SRC/copy-me"
echo c > "$SRC/copy-me/value.txt"
rm -rf "$P/node_modules" "$P/.venv" "$P/copy-me"
cat > "$SDIR/overrides.json" <<JSON
{"version":1,"links":{"app":{"node_modules":null}}}
JSON
mrun link >/dev/null 2>&1
[[ ! -e "$P/node_modules" ]] || { echo "FAIL: node_modules linked despite null override"; exit 1; }
[[ -L "$P/.venv" ]] || { echo "FAIL: .venv should still link"; exit 1; }

# 2b) 대시보드 탐색기 copy mode — central links.json mode=copy 는 symlink 가 아니라 복제
PID="$(python3 -c "import json; print(json.load(open('$MARINA_HOME/projects.json'))['projects'][0]['id'])")"
mkdir -p "$MARINA_HOME/$PID"
cat > "$MARINA_HOME/$PID/links.json" <<'JSON'
{"version":1,"links":{"copy-me":{"glob":"copy-me","kind":"dir","mode":"copy"}}}
JSON
mrun link >/dev/null 2>&1
[[ -d "$P/copy-me" && ! -L "$P/copy-me" ]] || { echo "FAIL: mode=copy should create a real copied directory"; exit 1; }
[[ "$(cat "$P/copy-me/value.txt")" == c ]] || { echo "FAIL: copied directory content unreachable"; exit 1; }
pjc="$(cd "$P" && MARINA_HOME="$MARINA_HOME" SOURCE_ROOT="$SRC" bash "$SH" links-json app)"
echo "$pjc" | python3 -c "
import json, sys
m = {l['name']: l for l in json.load(sys.stdin)}
assert m['copy-me']['rule']['mode'] == 'copy', m['copy-me']
" || { echo "FAIL: copy mode not shown in links-json"; exit 1; }

# 3) claude worktree가 SOURCE_ROOT 아래에 있어도 dst/worktree 하위로 재귀 링크하지 않음
PN="$SRC/.claude/worktrees/wt"
mkdir -p "$PN"
cat > "$PN/marina-services.json" <<'JSON'
{"services":[{"name":"app","portBase":8714,"cwd":".","run":"exec sleep 30"}]}
JSON
bash "$SH" project add "$PN" >/dev/null
(cd "$PN" && MARINA_HOME="$MARINA_HOME" SOURCE_ROOT="$SRC" bash "$SH" link >/dev/null 2>&1)
[[ -L "$PN/node_modules" ]] || { echo "FAIL: nested worktree did not get top-level node_modules link"; exit 1; }
[[ ! -e "$PN/.claude/worktrees/wt" ]] || { echo "FAIL: nested worktree recursion created .claude/worktrees/wt"; find "$PN/.claude" -maxdepth 5 -print; exit 1; }

# 4) source==dest(main 체크아웃)면 skip — 에러 없이 self node_modules 보존
PM="$TMP/main"; mkdir -p "$PM/node_modules/x"
cat > "$PM/marina-services.json" <<'JSON'
{"services":[{"name":"app","portBase":8713,"cwd":".","run":"exec sleep 30"}]}
JSON
bash "$SH" project add "$PM" >/dev/null
(cd "$PM" && MARINA_HOME="$MARINA_HOME" SOURCE_ROOT="$PM" bash "$SH" link >/dev/null 2>&1)
[[ -d "$PM/node_modules" && ! -L "$PM/node_modules" ]] || { echo "FAIL: source==dest should leave real node_modules"; exit 1; }

# 5) links-json present — 소스에 실제 있는 것만 present=true (대시보드 모달이 이걸로 필터)
pj="$(cd "$P" && MARINA_HOME="$MARINA_HOME" SOURCE_ROOT="$SRC" bash "$SH" links-json app)"
echo "$pj" | python3 -c "
import json, sys
m = {l['name']: l for l in json.load(sys.stdin)}
assert m['node_modules']['present'] is True, ('node_modules 있는데 present 아님', m['node_modules'])
# 분류(Task 4): deps/config/build — UI 기본 동작 제안용
assert m['node_modules']['category'] == 'deps', ('node_modules 는 deps', m['node_modules'])
assert m['local-yml']['category'] == 'config', ('local-yml 는 config', m.get('local-yml'))
# build 는 기본 링크 아님 — 소스에 있으면 discovered/build 로 노출(제외 제안), 기본 동작 링크는 아님
assert m['build']['base'] == 'discovered' and m['build']['category'] == 'build', ('build 는 discovered/build', m.get('build'))
" || { echo "FAIL: 분류·present 검사"; exit 1; }

echo "PASS test-config-glob-links"
