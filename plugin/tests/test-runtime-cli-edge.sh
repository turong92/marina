#!/usr/bin/env bash
# marina runtime — 리뷰 지적(2026-10-07) 고정: 서브레포 cwd 의 root, 주소 없는 use 거부, 물려받은 주소 표시,
# 깨진 설정 경고, 워크트리 밖 가드, --help, 프로젝트 원격이 실제 docker 호출까지 닿는지(가짜 docker).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
EP="$HERE/../scripts/marina-entrypoint.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
fail() { echo "FAIL: $1"; exit 1; }
ep() { (cd "$CWD" && bash "$EP" "$@"); }
git_init() { git -C "$1" init -q && git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; }

# ── 서브레포가 있는 워크스페이스 프로젝트 ──
W="$TMP/ws"; mkdir -p "$W/sub"; git_init "$W"; git_init "$W/sub"
printf 'services:\n  app:\n    build: .\n' > "$W/docker-compose.yml"
bash "$SH" project add "$W" --compose "$W/docker-compose.yml" --subrepos sub >/dev/null
PID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["projects"][0]["id"])' "$MARINA_HOME/projects.json")"
SD="$(cd "$W" && bash "$SH" print-session-dir)"

# 1) 서브레포 안에서 친 세션 단위 runtime 은 워크스페이스 루트의 세션 폴더에 쓰이고, 루트에서 보는 것과 같다
CWD="$W"; ep runtime use ssh://pbox --project >/dev/null
CWD="$W/sub"; ep runtime local >/dev/null || fail "서브레포에서 runtime local 실패"
[[ -f "$SD/runtime-target.json" ]] || fail "세션 파일이 워크스페이스 루트 세션 폴더($SD)에 없다"
[[ ! -d "$W/sub/.workspace" ]] || fail "서브레포 안에 세션 폴더가 생겼다"
a="$(CWD="$W/sub" ep runtime status | head -n1)"; b="$(CWD="$W" ep runtime status | head -n1)"
[[ "$a" == "$b" && "$a" == *로컬* ]] || fail "서브레포·루트 status 가 다르다: [$a] [$b]"
CWD="$W/sub"; ep runtime inherit >/dev/null
a="$(ep runtime status | head -n1)"; [[ "$a" == *ssh://pbox* ]] || fail "서브레포 status 가 프로젝트 원격을 못 봄: $a"

# 2) 주소를 어디서도 못 얻는 use 는 거부(성공 메시지 + 실제 로컬 금지)
CWD="$W"; ep runtime inherit --project >/dev/null
for scope in "" "--project"; do
  rc=0; out="$(ep runtime use $scope 2>&1)" || rc=$?
  [[ "$rc" != 0 ]] || fail "주소 없는 use $scope 가 성공: $out"
  grep -q "박스 주소가 없다" <<<"$out" || fail "거부 문구 없음($scope): $out"
done
[[ ! -f "$SD/runtime-target.json" && ! -f "$MARINA_HOME/$PID/runtime-target.json" ]] || fail "거부했는데 파일을 썼다"
ep runtime use ssh://gbox --global >/dev/null
ep runtime use >/dev/null || fail "전역 주소가 있으면 주소 없는 use 는 통과해야 한다"
ep runtime inherit >/dev/null

# 3) 주소를 물려받는 중이면 status 가 그 host 를 보여 준다
ep runtime use --project >/dev/null
out="$(ep runtime status)"
grep -q "주소 없음 → ssh://gbox 물려받음" <<<"$out" || fail "물려받은 host 미표시: $out"
grep -q "상위 주소 없음" <<<"$out" && fail "물려받는데 '상위 주소 없음': $out"
ep runtime inherit --project >/dev/null; ep runtime inherit --global >/dev/null

# 4) 깨진 세션 설정 + 프로젝트 원격 → 프로젝트를 따르고, 경고는 '건너뜁니다'
ep runtime use ssh://pbox --project >/dev/null
mkdir -p "$SD"; printf '{ not json' > "$SD/runtime-target.json"
err="$(ep runtime status 2>&1 >/dev/null)"
grep -q "건너뜁니다" <<<"$err" || fail "경고 문구가 '건너뜁니다' 가 아님: $err"
[[ "$(grep -c "runtime-target" <<<"$err")" == 1 ]] || fail "경고가 중복 출력됨: $err"
out="$(ep runtime status 2>/dev/null | head -n1)"
[[ "$out" == *ssh://pbox* ]] || fail "깨진 세션 + 프로젝트 원격이면 프로젝트를 따라야 한다: $out"
rm -f "$SD/runtime-target.json"; ep runtime inherit --project >/dev/null

# 5) 등록된 프로젝트 밖(무관한 폴더)에서는 세션 쓰기·id 생략 --project 거부 — 프로젝트가 1개뿐이어도
O="$TMP/other"; mkdir -p "$O"; git_init "$O"
for args in "use ssh://x" "local" "use ssh://x --project" "inherit --project"; do
  CWD="$O"; rc=0; out="$(ep runtime $args 2>&1)" || rc=$?
  [[ "$rc" != 0 ]] || fail "무관한 폴더에서 'runtime $args' 가 통과: $out"
done
[[ ! -e "$O/.workspace" && ! -f "$MARINA_HOME/$PID/runtime-target.json" ]] || fail "거부했는데 무언가 써졌다"
CWD="$O"; ep runtime status --global >/dev/null || fail "밖에서 status --global 은 되어야 한다"

# 6) --help 는 rc 0 + 사용법
CWD="$W"; rc=0; out="$(ep runtime --help 2>&1)" || rc=$?
[[ "$rc" == 0 ]] && grep -q "usage: marina runtime" <<<"$out" || fail "runtime --help rc=$rc: $out"

# 8) 실제 .claude/worktrees/x 모양 + 세션 설정 없이 프로젝트 원격 → docker 호출이 그 박스를 향한다(가짜 docker)
R="$TMP/repo"; mkdir -p "$R"; git_init "$R"
printf 'services:\n  app:\n    build: .\n' > "$R/docker-compose.yml"
bash "$SH" project add "$R" --compose "$R/docker-compose.yml" >/dev/null
RID="$(python3 -c 'import json,sys;print([p["id"] for p in json.load(open(sys.argv[1]))["projects"] if p["root"].endswith("/repo")][0])' "$MARINA_HOME/projects.json")"
mkdir -p "$R/.claude/worktrees"; git -C "$R" worktree add -q "$R/.claude/worktrees/x" -b x
FB="$TMP/fakebin"; mkdir -p "$FB"; DLOG="$TMP/docker.log"
cat > "$FB/docker" <<'SH'
#!/usr/bin/env bash
echo "DH=${DOCKER_HOST:-} $*" >> "$DOCKER_LOG"
case "$*" in "compose version"*) echo 2.30.0 ;; esac
exit 1
SH
chmod +x "$FB/docker"
# marina_env 는 로그인 셸 PATH 를 맨 앞에 병합한다 — 가짜 docker 가 이기도록 PATH 만 그대로 찍는 가짜 셸을 쓴다
printf '#!/bin/sh\necho "PATH=$PATH"\n' > "$FB/fakeshell"; chmod +x "$FB/fakeshell"
dock() { : > "$DLOG"; (cd "$R/.claude/worktrees/x" && SHELL=$FB/fakeshell PATH="$FB:$PATH" DOCKER_LOG="$DLOG" bash "$EP" "$@" >"$TMP/dock.out" 2>&1) || true; }
dock status
[[ -s "$DLOG" ]] || fail "status 가 docker 를 안 불렀다(픽스처 오류): $(cat "$TMP/dock.out")"
! grep -v "^DH= " "$DLOG" | grep -q . || fail "설정 없는데 DOCKER_HOST 가 잡힘(로컬이 바뀜): $(cat "$DLOG")"
dock start --all
! grep -v "^DH= " "$DLOG" | grep -q . || fail "로컬 start 의 docker 호출에 DOCKER_HOST 가 섞임: $(cat "$DLOG")"
(cd "$R" && bash "$EP" runtime use ssh://pbox --project "$RID" >/dev/null)
dock status
! grep -v "^DH=ssh://pbox " "$DLOG" | grep -q . || fail "프로젝트 원격인데 docker 호출 일부가 로컬: $(cat "$DLOG")"
# 10) start 경로의 docker info·compose ps 도 박스를 향한다
dock start --all
grep -q "^DH=ssh://pbox info" "$DLOG" || fail "docker info 가 박스를 안 향함: $(cat "$DLOG")"
! grep -v "^DH=ssh://pbox " "$DLOG" | grep -q . || fail "start 의 docker 호출 일부가 로컬: $(cat "$DLOG")"
# env 하위명령: 설정 없으면 빈 출력, 원격이면 DOCKER_HOST= 줄
(cd "$R" && bash "$EP" runtime inherit --project "$RID" >/dev/null)
out="$(cd "$R/.claude/worktrees/x" && bash "$EP" runtime env)"; [[ -z "$out" ]] || fail "로컬인데 env 출력이 있다: $out"

echo PASS
