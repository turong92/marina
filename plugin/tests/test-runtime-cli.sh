#!/usr/bin/env bash
# `marina remote` — 런타임 타깃 스위치.
#
# 형 지시(2026-08-24): "전역 설정으로 고르게 하고, 각 세션에서도 변경 가능하게."
#   marina remote use <host> [--global]   원격으로 (기본=이 워크트리, --global=전역 기본)
#   marina remote off [--global]          로컬로 되돌리기
#   marina remote status                  지금 어디서 도나 + 어느 계층이 결정했나
#
# 엔진(오버레이·기동 시퀀스)은 이미 되어 있고, 이게 없으면 사용자가 JSON 을 손으로 놔야 한다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
P="$TMP/wt"; mkdir -p "$P"
cat > "$P/docker-compose.yml" <<'YAML'
services:
  app:
    build: .
YAML
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" >/dev/null
mrun() { (cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" "$@"); }
SD="$(mrun print-session-dir)"

fail() { echo "FAIL: $1"; exit 1; }

# ── 기본은 로컬 ──
out="$(mrun remote status)" || fail "status 실패"
grep -qi "로컬\|local" <<<"$out" || fail "기본이 로컬로 안 보고됨: $out"

# ── 세션 단위 전환 ──
mrun remote use ssh://box >/dev/null || fail "remote use 실패"
[[ -f "$SD/runtime-target.json" ]] || fail "세션 설정파일 안 생김($SD)"
grep -q '"remote"' "$SD/runtime-target.json" || fail "세션 설정에 remote 없음"
grep -q 'ssh://box' "$SD/runtime-target.json" || fail "세션 설정에 host 없음"
out="$(mrun remote status)"; grep -q "ssh://box" <<<"$out" || fail "status 가 host 를 안 보여줌: $out"

# ── 세션 해제 → 로컬 ──
mrun remote off >/dev/null || fail "remote off 실패"
out="$(mrun remote status)"; grep -qi "로컬\|local" <<<"$out" || fail "off 후에도 원격: $out"

# ── inherit: 세션 의견을 지우면 전역을 따른다(off=로컬 고정 과 다른 뜻) ──
mrun remote inherit >/dev/null || fail "remote inherit 실패"
[[ ! -f "$SD/runtime-target.json" ]] || fail "inherit 후에도 세션 설정파일이 남음"

# ── 전역 설정 ──
mrun remote use ssh://global-box --global >/dev/null || fail "--global 실패"
[[ -f "$MARINA_HOME/runtime-target.json" ]] || fail "전역 설정파일 안 생김"
# 세션 의견이 없으니 전역이 먹어야 한다
out="$(mrun remote status)"; grep -q "ssh://global-box" <<<"$out" || fail "전역이 안 먹음: $out"

# ── 세션이 전역을 덮는다: 이 워크트리만 로컬로 ──
mrun remote off >/dev/null
out="$(mrun remote status)"
grep -qi "로컬\|local" <<<"$out" || fail "전역 원격인데 세션 off 가 안 먹음: $out"
# 전역 설정은 남아 있어야 한다(다른 워크트리에 영향 없어야)
grep -q 'ssh://global-box' "$MARINA_HOME/runtime-target.json" || fail "세션 off 가 전역을 지웠다"

# ── 세션이 주소 없이 켜면 전역 주소를 물려받는다 ──
mrun remote use >/dev/null || fail "주소 없는 remote use 실패"
out="$(mrun remote status)"; grep -q "ssh://global-box" <<<"$out" || fail "전역 주소 물려받기 실패: $out"

# ── 전역 해제 ──
mrun remote inherit --global >/dev/null || fail "--global inherit 실패"
mrun remote inherit >/dev/null
out="$(mrun remote status)"; grep -qi "로컬\|local" <<<"$out" || fail "전부 해제 후에도 원격: $out"

# ── 잘못된 서브커맨드는 실패해야 한다(조용히 성공하면 오타가 묻힌다) ──
if mrun remote bogus >/dev/null 2>&1; then fail "잘못된 서브커맨드가 성공함"; fi

# ── --global 에 주소를 빼면 실패해야 한다 ──
# 전역은 물려받을 상위 계층이 없다. 성공을 찍고 실제론 로컬로 해석되면 사용자를 속인다.
if mrun remote use --global >/dev/null 2>&1; then fail "--global 에 주소 없이 성공함"; fi
[[ ! -f "$MARINA_HOME/runtime-target.json" ]] || fail "실패했는데 전역 설정파일을 썼다"

# ── 깨진 설정은 조용히 넘어가지 말고 경고해야 한다 ──
# 쓰기가 중단돼 파일이 깨지면 조용히 로컬로 돌아 안 돌리려던 노트북에서 스택이 뜬다.
mrun remote use ssh://box >/dev/null
printf '{ not json' > "$SD/runtime-target.json"
err="$(mrun remote status 2>&1 >/dev/null)"
grep -qiE "runtime-target|설정|warn" <<<"$err" || fail "깨진 설정에 경고가 없다: $err"
out="$(mrun remote status 2>/dev/null)"
grep -qi "로컬\|local" <<<"$out" || fail "깨진 설정인데 원격으로 감: $out"
mrun remote inherit >/dev/null

echo PASS
