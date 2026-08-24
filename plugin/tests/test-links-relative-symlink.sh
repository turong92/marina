#!/usr/bin/env bash
# links 심링크는 **상대경로**로 만든다.
# 왜: 절대경로("/Users/<나>/...")로 박히면 그 워크트리가 이 머신에만 유효하다.
#  - 레포 폴더를 옮기거나 이름을 바꾸면 워크트리 링크가 전부 깨진다.
#  - 파일 동기화(mutagen 등)로 워크트리를 다른 기계에 올릴 때 절대링크는 전파되지 않는다
#    ("invalid symbolic link: target is absolute" 로 조용히 누락 → deps 없는 워크트리).
# 상대경로는 로컬 해석 결과가 절대경로와 동일하므로 기존 사용자 동작은 안 바뀐다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
SRC="$TMP/src"; P="$TMP/wt"

mkdir -p "$SRC/node_modules/dep" "$SRC/.venv/bin" "$P"
echo m > "$SRC/node_modules/dep/i.js"
echo v > "$SRC/.venv/bin/python"
cat > "$P/docker-compose.yml" <<'YAML'
services:
  app:
    build: .
x-marina:
  links:
    symlink: [node_modules, .venv]
YAML
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" >/dev/null
mrun() { (cd "$P" && MARINA_HOME="$MARINA_HOME" SOURCE_ROOT="$SRC" bash "$SH" "$@"); }

mrun link >/dev/null 2>&1

# ① 만들어진 심링크는 상대경로여야 한다
for n in node_modules .venv; do
  [[ -L "$P/$n" ]] || { echo "FAIL: $n 심링크 안 됨"; exit 1; }
  tgt="$(readlink "$P/$n")"
  case "$tgt" in
    /*) echo "FAIL: $n 링크가 절대경로다 -> $tgt"; exit 1 ;;
  esac
done

# ② 상대경로여도 내용은 그대로 닿아야 한다(로컬 동작 불변)
[[ "$(cat "$P/node_modules/dep/i.js")" == m ]] || { echo "FAIL: node_modules 내용 안 닿음"; exit 1; }
[[ "$(cat "$P/.venv/bin/python")" == v ]] || { echo "FAIL: .venv 내용 안 닿음"; exit 1; }

# ③ 이미 박혀 있는 절대링크는 재실행으로 상대링크로 교체된다(기존 워크트리 이관)
rm "$P/node_modules"; ln -s "$SRC/node_modules" "$P/node_modules"
[[ "$(readlink "$P/node_modules")" == /* ]] || { echo "FAIL: 전제 세팅(절대링크) 실패"; exit 1; }
mrun link >/dev/null 2>&1
tgt="$(readlink "$P/node_modules")"
case "$tgt" in
  /*) echo "FAIL: 기존 절대링크가 상대로 교체 안 됨 -> $tgt"; exit 1 ;;
esac
[[ "$(cat "$P/node_modules/dep/i.js")" == m ]] || { echo "FAIL: 교체 후 내용 안 닿음"; exit 1; }

echo PASS
