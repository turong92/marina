#!/usr/bin/env bash
# main 기본 링크 disable/enable → 새 워크트리 상속(3개/5개) + 워크트리 override 격리 e2e.
# (원본 e2e: main 에서 기본 링크 disable/enable → 새 워크트리 생성 → 상속 반영 확인 + 워크트리 override 격리 확인.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"

SRC="$TMP/src"
mkdir -p "$SRC"
# main(source) — 기본 링크 대상 5개를 소스에 둠: node_modules·.venv(deps) + *local.yml·.env*.local(config) + 공유로 추가할 shared/
mkdir -p "$SRC/node_modules/dep" "$SRC/.venv/bin" "$SRC/config" "$SRC/shared/x"
echo nm > "$SRC/node_modules/dep/i.js"; echo v > "$SRC/.venv/bin/python"
echo y > "$SRC/config/app-local.yml"; echo e > "$SRC/.env.local"; echo s > "$SRC/shared/x/v.txt"
cat > "$SRC/marina-services.json" <<'JSON'
{"services":[{"name":"app","portBase":8900,"cwd":".","run":"exec sleep 30"}]}
JSON
cat > "$SRC/.gitignore" <<'GI'
node_modules/
.venv/
*local.yml
.env.local
shared/
GI
git -C "$SRC" init -q && git -C "$SRC" add -A && git -C "$SRC" -c user.email=a@b.c -c user.name=t commit -qm init

bash "$SH" project add "$SRC" >/dev/null
PID="$(python3 -c "import json; print(json.load(open('$MARINA_HOME/projects.json'))['projects'][0]['id'])")"
mkdir -p "$MARINA_HOME/$PID"

# 공유 링크 1개(shared/)를 main 에 추가(base set) — 기본4 + 공유1 = 총 5개 후보
cl() { printf '%s' "$1" > "$MARINA_HOME/$PID/links.json"; }    # central links.json 직접 기록 = 대시보드 base 동작과 동일

newwt() {  # $1=name → SRC 하위 워크트리 생성 후 SOURCE_ROOT 상속 link, 적용된 링크 이름 출력
  local name="$1" wt="$SRC/.claude/worktrees/$1"
  git -C "$SRC" worktree add -q -b "$name" "$wt" >/dev/null 2>&1
  (cd "$wt" && MARINA_HOME="$MARINA_HOME" SOURCE_ROOT="$SRC" bash "$SH" link >/dev/null 2>&1) || true
  for n in node_modules .venv config/app-local.yml .env.local shared; do
    [[ -L "$wt/$n" ]] && echo "$n"
  done
}

echo "================ 시나리오 A: main 에서 node_modules·.venv 빼고(=3개) 워크트리 생성 ================"
cl '{"version":1,"links":{"shared":{"glob":"shared","kind":"dir"},"node_modules":null,".venv":null}}'
A="$(newwt wtA | sort)"
echo "wtA 적용된 링크:"; echo "$A" | sed 's/^/  - /'
echo "  → 갯수: $(echo "$A" | grep -c . )  (기대: 3 — config/app-local.yml·.env.local·shared, node_modules·.venv 제외)"

echo
echo "================ 시나리오 B: main 에서 다시 넣고(=5개) 워크트리 생성 ================"
cl '{"version":1,"links":{"shared":{"glob":"shared","kind":"dir"}}}'
B="$(newwt wtB | sort)"
echo "wtB 적용된 링크:"; echo "$B" | sed 's/^/  - /'
echo "  → 갯수: $(echo "$B" | grep -c . )  (기대: 5 — 기본4 + 공유1 전부)"

echo
echo "================ 시나리오 C: wtA 에서 개별 override(.env.local 끔) → wtA 만 영향, wtB·main 무영향 ================"
SD="$(cd "$SRC/.claude/worktrees/wtA" && MARINA_HOME="$MARINA_HOME" SOURCE_ROOT="$SRC" bash "$SH" print-session-dir)"
mkdir -p "$SD"; printf '%s' '{"version":1,"links":{"":{"local-env":null}}}' > "$SD/overrides.json"   # 링크는 이름(local-env)으로 키잉 — .env*.local 의 링크명
rm -f "$SRC/.claude/worktrees/wtA/.env.local"
(cd "$SRC/.claude/worktrees/wtA" && MARINA_HOME="$MARINA_HOME" SOURCE_ROOT="$SRC" bash "$SH" link >/dev/null 2>&1) || true
echo "wtA(.env.local override 끔) 적용된 링크:"
for n in node_modules .venv config/app-local.yml .env.local shared; do [[ -L "$SRC/.claude/worktrees/wtA/$n" ]] && echo "  - $n"; done
echo "  wtB .env.local 링크 살아있나(격리)?: $([[ -L "$SRC/.claude/worktrees/wtB/.env.local" ]] && echo '예(영향 없음 ✓)' || echo '아니오 — 격리 실패 ✗')"
echo "  main central links.json 그대로?: $(python3 -c "import json;d=json.load(open('$MARINA_HOME/$PID/links.json'));print('예 ✓' if list(d['links'])==['shared'] else '변경됨 ✗ '+str(d['links']))")"

echo
echo "================ 판정 ================"
na="$(echo "$A" | grep -c .)"; nb="$(echo "$B" | grep -c .)"
cok=$([[ -L "$SRC/.claude/worktrees/wtA/.env.local" ]] && echo no || echo yes)   # wtA 에선 빠져야
bok=$([[ -L "$SRC/.claude/worktrees/wtB/.env.local" ]] && echo yes || echo no)   # wtB 엔 살아야
git -C "$SRC" worktree prune 2>/dev/null || true
if [[ "$na" == 3 && "$nb" == 5 && "$cok" == yes && "$bok" == yes ]]; then
  echo "PASS test-base-link-inheritance  (A=3, B=5, C 격리 OK)"
else
  echo "FAIL ✗  A=$na(기대3) B=$nb(기대5) wtA끔=$cok wtB유지=$bok"
  exit 1
fi
