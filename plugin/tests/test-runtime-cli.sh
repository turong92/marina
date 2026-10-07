#!/usr/bin/env bash
# `marina runtime` — 런타임 타깃 스위치 (옛 `marina remote use|off|inherit|status`, c61fb51 에서 죽었다).
#
# 형 지시(2026-08-24): "전역 설정으로 고르게 하고, 각 세션에서도 변경 가능하게."
# 형 지시(2026-10-07): "mdc 프로젝트만 원격으로" → 계층 = 전역 < 프로젝트 < 세션.
#   marina runtime use [<ssh://…>] | local | inherit | status   [--global | --project [<id>]]
#   `off` 는 funnel 도구(marina remote off)와 같은 단어라 `local` 로 바꿨다.
# `marina remote …`(funnel)는 한 글자도 안 바뀐다. 단 remote use|inherit 는 옮겨 갔다고 안내하고 실패한다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
EP="$HERE/../scripts/marina-entrypoint.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
P="$TMP/wt"; mkdir -p "$P"
cat > "$P/docker-compose.yml" <<'YAML'
services:
  app:
    build: .
YAML
bash "$SH" project add "$P" --compose "$P/docker-compose.yml" >/dev/null
PID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["projects"][0]["id"])' "$MARINA_HOME/projects.json")"
PD="$MARINA_HOME/$PID"
mrun() { (cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$EP" "$@"); }
SD="$(cd "$P" && MARINA_HOME="$MARINA_HOME" bash "$SH" print-session-dir)"

fail() { echo "FAIL: $1"; exit 1; }

# ── 기본은 로컬 ──
out="$(mrun runtime status)" || fail "status 실패"
grep -qi "로컬\|local" <<<"$out" || fail "기본이 로컬로 안 보고됨: $out"

# ── 세션 단위 전환 ──
mrun runtime use ssh://box >/dev/null || fail "runtime use 실패"
[[ -f "$SD/runtime-target.json" ]] || fail "세션 설정파일 안 생김($SD)"
grep -q '"remote"' "$SD/runtime-target.json" || fail "세션 설정에 remote 없음"
grep -q 'ssh://box' "$SD/runtime-target.json" || fail "세션 설정에 host 없음"
out="$(mrun runtime status)"; grep -q "ssh://box" <<<"$out" || fail "status 가 host 를 안 보여줌: $out"

# ── 세션 해제 → 로컬 ──
mrun runtime local >/dev/null || fail "runtime local 실패"
out="$(mrun runtime status)"; grep -qi "로컬\|local" <<<"$out" || fail "off 후에도 원격: $out"

# ── inherit: 세션 의견을 지우면 전역을 따른다(off=로컬 고정 과 다른 뜻) ──
mrun runtime inherit >/dev/null || fail "runtime inherit 실패"
[[ ! -f "$SD/runtime-target.json" ]] || fail "inherit 후에도 세션 설정파일이 남음"

# ── 전역 설정 ──
mrun runtime use ssh://global-box --global >/dev/null || fail "--global 실패"
[[ -f "$MARINA_HOME/runtime-target.json" ]] || fail "전역 설정파일 안 생김"
# 세션 의견이 없으니 전역이 먹어야 한다
out="$(mrun runtime status)"; grep -q "ssh://global-box" <<<"$out" || fail "전역이 안 먹음: $out"

# ── 세션이 전역을 덮는다: 이 워크트리만 로컬로 ──
mrun runtime local >/dev/null
out="$(mrun runtime status)"
grep -qi "로컬\|local" <<<"$out" || fail "전역 원격인데 세션 off 가 안 먹음: $out"
# 전역 설정은 남아 있어야 한다(다른 워크트리에 영향 없어야)
grep -q 'ssh://global-box' "$MARINA_HOME/runtime-target.json" || fail "세션 off 가 전역을 지웠다"

# ── 세션이 주소 없이 켜면 전역 주소를 물려받는다 ──
mrun runtime use >/dev/null || fail "주소 없는 runtime use 실패"
out="$(mrun runtime status)"; grep -q "ssh://global-box" <<<"$out" || fail "전역 주소 물려받기 실패: $out"

# ── 전역 해제 ──
mrun runtime inherit --global >/dev/null || fail "--global inherit 실패"
mrun runtime inherit >/dev/null
out="$(mrun runtime status)"; grep -qi "로컬\|local" <<<"$out" || fail "전부 해제 후에도 원격: $out"

# ── 잘못된 서브커맨드는 실패해야 한다(조용히 성공하면 오타가 묻힌다) ──
if mrun runtime bogus >/dev/null 2>&1; then fail "잘못된 서브커맨드가 성공함"; fi

# ── --global 에 주소를 빼면 실패해야 한다 ──
# 전역은 물려받을 상위 계층이 없다. 성공을 찍고 실제론 로컬로 해석되면 사용자를 속인다.
if mrun runtime use --global >/dev/null 2>&1; then fail "--global 에 주소 없이 성공함"; fi
[[ ! -f "$MARINA_HOME/runtime-target.json" ]] || fail "실패했는데 전역 설정파일을 썼다"

# ── 깨진 설정은 조용히 넘어가지 말고 경고해야 한다 ──
# 쓰기가 중단돼 파일이 깨지면 조용히 로컬로 돌아 안 돌리려던 노트북에서 스택이 뜬다.
mrun runtime use ssh://box >/dev/null
printf '{ not json' > "$SD/runtime-target.json"
err="$(mrun runtime status 2>&1 >/dev/null)"
grep -qiE "runtime-target|설정|warn" <<<"$err" || fail "깨진 설정에 경고가 없다: $err"
out="$(mrun runtime status 2>/dev/null)"
grep -qi "로컬\|local" <<<"$out" || fail "깨진 설정인데 원격으로 감: $out"
mrun runtime inherit >/dev/null

# ════════ 프로젝트 계층 (전역 < 프로젝트 < 세션) ════════
first() { head -n1 <<<"$1"; }

# --project(id 생략 = 현재 워크트리의 프로젝트)로 쓴다. 세션·전역은 손대지 않는다.
mrun runtime use ssh://pbox --project >/dev/null || fail "--project use 실패"
[[ -f "$PD/runtime-target.json" ]] || fail "프로젝트 설정파일 위치가 <MARINA_HOME>/<id>/runtime-target.json 이 아니다($PD)"
grep -q 'ssh://pbox' "$PD/runtime-target.json" || fail "프로젝트 설정에 host 없음"
[[ ! -f "$SD/runtime-target.json" && ! -f "$MARINA_HOME/runtime-target.json" ]] || fail "--project 가 다른 계층을 썼다"
out="$(mrun runtime status)"
grep -q "ssh://pbox" <<<"$(first "$out")" || fail "프로젝트 설정이 첫 줄(최종 결과)에 안 보임: $out"
grep -q "프로젝트" <<<"$out" || fail "어느 계층이 정했는지 안 나옴: $out"

# 새 워크트리처럼 세션 설정이 없어도 원격이어야 한다(= 형 요구의 핵심)
# 세션이 덮으면 세션이 최종
mrun runtime local >/dev/null
grep -qi "로컬" <<<"$(first "$(mrun runtime status)")" || fail "세션 local 이 프로젝트를 못 덮음"
grep -q 'ssh://pbox' "$PD/runtime-target.json" || fail "세션 local 이 프로젝트 설정을 건드림"
mrun runtime inherit >/dev/null

# 프로젝트가 local 이면 전역이 원격이어도 이 프로젝트는 로컬
mrun runtime use ssh://gbox --global >/dev/null
mrun runtime local --project >/dev/null || fail "--project local 실패"
grep -qi "로컬" <<<"$(first "$(mrun runtime status)")" || fail "프로젝트 local 이 전역을 못 덮음"
# 프로젝트 inherit → 전역을 따른다, 파일은 지워진다
mrun runtime inherit --project >/dev/null || fail "--project inherit 실패"
[[ ! -f "$PD/runtime-target.json" ]] || fail "--project inherit 후에도 파일이 남음"
grep -q "ssh://gbox" <<<"$(first "$(mrun runtime status)")" || fail "프로젝트 inherit 후 전역을 안 따름"

# 프로젝트가 주소 생략 remote → 전역 주소
mrun runtime use --project >/dev/null || fail "주소 없는 --project use 실패"
grep -q "ssh://gbox" <<<"$(first "$(mrun runtime status)")" || fail "프로젝트 주소 생략 시 전역 물려받기 실패"
mrun runtime inherit --project >/dev/null; mrun runtime inherit --global >/dev/null

# 명시 id: --project <id> (워크트리 밖에서도 보고 쓴다)
out="$(cd "$TMP" && MARINA_HOME="$MARINA_HOME" bash "$EP" runtime use ssh://xbox --project "$PID")" || fail "명시 id 쓰기 실패: $out"
grep -q 'ssh://xbox' "$PD/runtime-target.json" || fail "명시 id 가 그 프로젝트 폴더에 안 써짐"
out="$(cd "$TMP" && MARINA_HOME="$MARINA_HOME" bash "$EP" runtime status --project "$PID")" || fail "밖에서 status --project 실패: $out"
grep -q "ssh://xbox" <<<"$out" || fail "밖에서 status --project 에 값이 안 보임: $out"
out="$(cd "$TMP" && MARINA_HOME="$MARINA_HOME" bash "$EP" runtime status --global)" || fail "밖에서 status --global 실패"
grep -qi "전역" <<<"$out" || fail "status --global 에 전역이 안 보임: $out"
mrun runtime inherit --project >/dev/null

# 등록 안 된 프로젝트 id · 경로 탈출 id 는 거부
if mrun runtime use ssh://b --project nope-nope >/dev/null 2>&1; then fail "미등록 프로젝트에 써짐"; fi
if mrun runtime use ssh://b --project ../x >/dev/null 2>&1; then fail "../x 가 통과"; fi
# 주소 형식(ssh://) 검증
if mrun runtime use box.local >/dev/null 2>&1; then fail "ssh:// 아닌 주소가 통과"; fi
[[ ! -f "$SD/runtime-target.json" ]] || fail "거부했는데 파일을 썼다"
# --global 과 --project 동시 지정은 모호하다
if mrun runtime use ssh://b --global --project >/dev/null 2>&1; then fail "--global --project 동시 통과"; fi

# 각 계층 값이 status 에 다 나온다
mrun runtime use ssh://g2 --global >/dev/null; mrun runtime use ssh://p2 --project >/dev/null; mrun runtime local >/dev/null
out="$(mrun runtime status)"
grep -q "ssh://g2" <<<"$out" && grep -q "ssh://p2" <<<"$out" || fail "status 가 각 계층 값을 안 보여줌: $out"
mrun runtime inherit >/dev/null; mrun runtime inherit --project >/dev/null; mrun runtime inherit --global >/dev/null

# ════════ 라우팅: marina remote(funnel) 는 그대로, use|inherit 는 안내 ════════
for sub in use inherit; do
  rc=0; out="$(mrun remote $sub 2>&1)" || rc=$?
  [[ "$rc" != 0 ]] || fail "marina remote $sub 가 성공함"
  grep -q "marina runtime" <<<"$out" || fail "remote $sub 가 runtime 으로 안내 안 함: $out"
  grep -q "invalid choice" <<<"$out" && fail "remote $sub 가 argparse 에러로 떨어짐: $out"
done
out="$(mrun remote --help 2>&1 || true)"
grep -q "serve" <<<"$out" || fail "marina remote(funnel) 도움말이 달라짐: $out"
grep -q "runtime" <<<"$out" && fail "funnel 도움말이 오염됨"

echo PASS
