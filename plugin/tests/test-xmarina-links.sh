#!/usr/bin/env bash
# opt-in links: x-marina.links {symlink:[...], copy:[...]} 가 있으면 그 명시 리스트만 적용.
# symlink=공유 심링크, copy=독립 복제(원본과 무관), 목록 외(빌드출력 build/.next/*.jar)=아무것도 안 함.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
SRC="$TMP/src"; P="$TMP/wt"
# main(SOURCE_ROOT): deps·config·빌드출력 모두 존재. build 안에도 config 파일을 둬서 '빌드트리 안 config 누수' 확인
mkdir -p "$SRC/node_modules/dep" "$SRC/.venv/bin" "$SRC/build/libs" "$SRC/build/resources" "$SRC/.next" "$SRC/src/main/resources"
echo m > "$SRC/node_modules/dep/i.js"; echo v > "$SRC/.venv/bin/python"
echo j > "$SRC/build/libs/app.jar"
echo bld > "$SRC/build/resources/app-local.yml"     # 빌드트리 내부 config — copy glob 이 여기까진 안 닿아야(빌드 독립)
echo y > "$SRC/src/main/resources/app-local.yml"
echo rootyml > "$SRC/root-local.yml"                # 루트 직속 — globstar(**/) 가 여기도 잡아야(codex P2)
# worktree(ROOT) — compose 프로젝트로 등록(x-marina.links 보유). copy 는 문서형 path glob, 빌드 아티팩트 명시 opt-in 포함
mkdir -p "$P"
cat > "$P/docker-compose.yml" <<'YAML'
services:
  app:
    build: .
x-marina:
  links:
    symlink: [node_modules, .venv, "build/libs/app.jar"]
    copy: ["**/*local.yml"]
YAML
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" >/dev/null
mrun() { (cd "$P" && MARINA_HOME="$MARINA_HOME" SOURCE_ROOT="$SRC" bash "$SH" "$@"); }

mrun link >/dev/null 2>&1
# symlink 목록 → 심링크
[[ -L "$P/node_modules" ]] || { echo "FAIL: node_modules 심링크 안 됨"; exit 1; }
[[ -L "$P/.venv" ]] || { echo "FAIL: .venv 심링크 안 됨"; exit 1; }
[[ "$(cat "$P/node_modules/dep/i.js")" == m ]] || { echo "FAIL: 심링크 내용 안 닿음"; exit 1; }
# copy 목록 → 독립 복제(심링크 아님, 실파일)
ylf="$P/src/main/resources/app-local.yml"
[[ -f "$ylf" && ! -L "$ylf" ]] || { echo "FAIL: local.yml 복제(실파일) 아님"; exit 1; }
[[ "$(cat "$ylf")" == y ]] || { echo "FAIL: 복제 내용 불일치"; exit 1; }
# 복제는 원본과 독립 — 대상 수정해도 원본 불변
echo changed > "$ylf"
[[ "$(cat "$SRC/src/main/resources/app-local.yml")" == y ]] || { echo "FAIL: 복제본이 원본과 안 독립(원본 변경됨)"; exit 1; }
# globstar(**/) 는 루트 직속도 잡음 (codex P2)
[[ -f "$P/root-local.yml" && ! -L "$P/root-local.yml" ]] || { echo "FAIL: 루트 직속 *local.yml 가 globstar 로 복제 안 됨"; exit 1; }
# 명시 빌드 아티팩트 opt-in — build/libs/app.jar 는 심링크 (codex P2: prune 이 명시 opt-in 막으면 안 됨)
[[ -L "$P/build/libs/app.jar" ]] || { echo "FAIL: 명시 opt-in 한 build/libs/app.jar 가 prune 으로 누락"; exit 1; }
# 그러나 build 디렉터리 통째/안의 config 는 안 옴(명시 안 한 것)
[[ ! -e "$P/build/resources/app-local.yml" ]] || { echo "FAIL: 빌드트리 안 config 가 copy glob 에 딸려옴(빌드 독립 깨짐)"; exit 1; }
[[ ! -e "$P/.next" ]] || { echo "FAIL: .next(빌드출력) 가져옴"; exit 1; }

# 빈 리스트 opt-out: x-marina.links {symlink:[],copy:[]} → 아무것도 안 함(legacy 기본 링크로 폴백 금지, codex P2)
P2="$TMP/wt2"; mkdir -p "$P2"
cat > "$P2/docker-compose.yml" <<'YAML'
services:
  app:
    build: .
x-marina:
  links:
    symlink: []
    copy: []
YAML
bash "$SH" project add "$P2" --compose "$P2/docker-compose.yml" >/dev/null
(cd "$P2" && MARINA_HOME="$MARINA_HOME" SOURCE_ROOT="$SRC" bash "$SH" link >/dev/null 2>&1)
[[ ! -e "$P2/node_modules" ]] || { echo "FAIL: 빈 links opt-out 인데 node_modules 링크됨(legacy 폴백)"; exit 1; }

echo "PASS test-xmarina-links"
