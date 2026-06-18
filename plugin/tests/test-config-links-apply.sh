#!/usr/bin/env bash
# links 적용: 선언/override 된 단일 {to,from} 링크가 서비스 start 때 실제 symlink 을 만든다.
# 격리: mktemp 임시 프로젝트 + fake 서비스만.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
P="$TMP/proj"; mkdir -p "$P"
SRC="$TMP/src"; mkdir -p "$SRC"; echo orig > "$SRC/orig.txt"; echo other > "$TMP/other.txt"
cat > "$P/marina-services.json" <<'JSON'
{"services":[{"name":"app","portBase":8711,"cwd":".","run":"exec sleep 30"}]}
JSON
bash "$SH" project add "$P" >/dev/null
mrun() { (cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" "$@"); }
SDIR="$(mrun print-session-dir)"; mkdir -p "$SDIR"

# 1) 선언(overrides.json)된 link 가 start 때 생성된다
cat > "$SDIR/overrides.json" <<JSON
{"version":1,"links":{"app":{"cfg":{"to":"linked.txt","from":"$SRC/orig.txt"}}}}
JSON
rm -f "$P/linked.txt"
mrun start --all >/dev/null 2>&1 || true; sleep 0.4; mrun stop --all >/dev/null 2>&1 || true
[[ -L "$P/linked.txt" ]] || { echo "FAIL: link not created at start"; exit 1; }
[[ "$(readlink "$P/linked.txt")" == "$SRC/orig.txt" ]] || { echo "FAIL: wrong target: $(readlink "$P/linked.txt")"; exit 1; }

# 2) override 가 link 를 redirect (idempotent 갱신)
cat > "$SDIR/overrides.json" <<JSON
{"version":1,"links":{"app":{"cfg":{"to":"linked.txt","from":"$TMP/other.txt"}}}}
JSON
mrun start --all >/dev/null 2>&1 || true; sleep 0.4; mrun stop --all >/dev/null 2>&1 || true
[[ "$(readlink "$P/linked.txt")" == "$TMP/other.txt" ]] || { echo "FAIL: redirect didn't update: $(readlink "$P/linked.txt")"; exit 1; }

# 3) 소스가 없으면 에러 없이 skip
cat > "$SDIR/overrides.json" <<JSON
{"version":1,"links":{"app":{"missing":{"to":"nope.txt","from":"$TMP/does-not-exist"}}}}
JSON
rm -f "$P/nope.txt"
mrun start --all >/dev/null 2>&1 || true; sleep 0.4; mrun stop --all >/dev/null 2>&1 || true
[[ ! -e "$P/nope.txt" ]] || { echo "FAIL: linked despite missing source"; exit 1; }

echo "PASS test-config-links-apply"
