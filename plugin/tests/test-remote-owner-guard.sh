#!/usr/bin/env bash
# 원격 박스 "주인 확인" 가드.
#
# 박스는 여러 팀원이 같이 쓰는 docker 데몬이고 compose 프로젝트 이름은 `<project-id>-<워크트리>` 뿐이라, 두 사람이
# 같은 id·같은 워크트리 이름(둘 다 mdc/main)을 쓰면 이름이 겹친다. 한 사람의 start/stop/rebuild/회수가 다른 사람의
# 컨테이너·볼륨을 재생성하거나 지운다. 이름을 바꾸면 떠 있는 팀원 스택이 붕 뜨므로 이름은 두고, 원격에서 쓰기 전에
# 라벨 com.docker.compose.project.working_dir 로 주인을 확인한다. 로컬은 한 글자도 안 바뀐다(가드 조회 호출 0).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$HERE/../scripts"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
FB="$TMP/fakebin"; mkdir -p "$FB"; LOG="$TMP/docker.log"
export DOCKER_LOG="$LOG"
fail() { echo "FAIL: $1"; echo "--- docker.log"; cat "$LOG" 2>/dev/null || true; exit 1; }

# 가짜 docker: 호출을 전부 남기고, 라벨 조회(ps -a --filter label=...)에는 FAKE_OWNER_DIRS(줄바꿈 구분)를 답한다.
cat > "$FB/docker" <<'SH'
#!/usr/bin/env bash
echo "DH=${DOCKER_HOST:-} $*" >> "$DOCKER_LOG"
case "$*" in
  "ps -a --filter label=com.docker.compose.project="*)
    [[ "${FAKE_PS_FAIL:-}" == 1 ]] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
    if [[ -n "${FAKE_PS_PIDFILE:-}" ]]; then echo $$ > "$FAKE_PS_PIDFILE"; exec sleep 30; fi
    [[ -n "${FAKE_OWNER_DIRS:-}" ]] && printf '%b\n' "$FAKE_OWNER_DIRS"
    exit 0 ;;
  *"config --format json"*)
    if [[ "${FAKE_CONFIG_APP:-}" == 1 ]]; then echo '{"services":{"app":{"image":"x"}}}'; else echo '{"services":{}}'; fi
    exit 0 ;;
  "info") exit 0 ;;
  "volume ls"*) echo marina_vol1; exit 0 ;;
esac
exit 0
SH
chmod +x "$FB/docker"

SD="$TMP/sd"; mkdir -p "$SD"
printf 'services:\n  app:\n    image: x\n' > "$TMP/stored.yml"
MINE="/Users/me/wt/main"
KAY="/Users/kaypark/Documents/wkwk/wakashorts/mdc"

cz() {  # cz <verb> [args...] — marina-compose.py 를 가짜 docker 로. stdout+stderr 를 OUT 에 모으고 rc 를 RC 에.
  : > "$LOG"; RC=0
  OUT="$(PATH="$FB:$PATH" PYTHONPATH="$SCRIPTS" python3 "$SCRIPTS/marina-compose.py" "$@" 2>&1)" || RC=$?
}
VERB_COMMON=(--project-id mdc --session main --session-dir "$SD")
writes() { grep -v ' ps -a --filter label=' "$LOG" || true; }   # 가드 조회를 뺀 docker 호출

# ── 로컬(설정 없음): 가드 조회 자체가 없고, 호출은 지금과 같다 ─────────────────────────────
rm -f "$SD/runtime-target.json"
FAKE_OWNER_DIRS="$KAY" cz down "${VERB_COMMON[@]}" --project-dir "$MINE"
[[ "$RC" == 0 ]] || fail "로컬 down 이 실패(rc=$RC): $OUT"
! grep -q "working_dir\|ps -a" "$LOG" || fail "로컬에서 가드 조회가 일어났다"
grep -q "^DH= compose -p mdc-main down" "$LOG" || fail "로컬 down 호출이 달라졌다"
FAKE_OWNER_DIRS="$KAY" cz up --stored "$TMP/stored.yml" --project-dir "$MINE" "${VERB_COMMON[@]}"
! grep -q " ps -a" "$LOG" || fail "로컬 up 에서 가드 조회가 일어났다"

# ── 원격 ────────────────────────────────────────────────────────────────────────
printf '{"kind":"remote","host":"ssh://pbox"}\n' > "$SD/runtime-target.json"

# 컨테이너 없음 → 내 것: 진행(down). 조회는 한 번.
FAKE_OWNER_DIRS="" cz down "${VERB_COMMON[@]}" --project-dir "$MINE"
[[ "$RC" == 0 ]] || fail "컨테이너 없음인데 down 이 막힘: $OUT"
grep -q "^DH=ssh://pbox compose -p mdc-main down" "$LOG" || fail "진행하지 않음"
[[ "$(grep -c ' ps -a --filter' "$LOG")" == 1 ]] || fail "가드 조회가 한 번이 아니다"
grep -q "^DH=ssh://pbox ps -a --filter label=com.docker.compose.project=mdc-main" "$LOG" || fail "조회가 박스를 안 향했다"

# 같은 폴더(컨테이너 여러 개) → 진행
FAKE_OWNER_DIRS="$MINE\n$MINE" cz down "${VERB_COMMON[@]}" --project-dir "$MINE"
[[ "$RC" == 0 ]] || fail "같은 폴더인데 막힘: $OUT"
grep -q "compose -p mdc-main down" "$LOG" || fail "같은 폴더인데 진행 안 함"

# 다른 폴더 → 거부: docker 쓰기 0건, 0 아닌 코드, 안내(이름·상대 폴더·해결법 둘)
for verb in down stop restart; do
  FAKE_OWNER_DIRS="$KAY" cz "$verb" "${VERB_COMMON[@]}" --project-dir "$MINE"
  [[ "$RC" != 0 ]] || fail "$verb: 남의 스택인데 성공 코드"
  [[ -z "$(writes)" ]] || fail "$verb: 남의 스택인데 docker 호출이 나갔다: $(writes)"
  grep -q "mdc-main" <<<"$OUT" || fail "$verb: 안내에 프로젝트 이름이 없다: $OUT"
  grep -q "$KAY" <<<"$OUT" || fail "$verb: 안내에 상대 폴더가 없다: $OUT"
  grep -q "MARINA_REMOTE_ADOPT=1" <<<"$OUT" || fail "$verb: 해결법 ②(ADOPT)가 없다: $OUT"
  grep -q "marina project" <<<"$OUT" || fail "$verb: 해결법 ①(이름 바꾸기)이 없다: $OUT"
done
FAKE_OWNER_DIRS="$KAY" cz stop "${VERB_COMMON[@]}" --service web --project-dir "$MINE"
[[ "$RC" != 0 && -z "$(writes)" ]] || fail "서비스 지정 stop 이 가드를 건너뜀"
FAKE_OWNER_DIRS="$MINE\n$KAY" cz down "${VERB_COMMON[@]}" --project-dir "$MINE"
[[ "$RC" != 0 && -z "$(writes)" ]] || fail "내 것·남의 것이 섞였는데 진행"

# up(= start/rebuild/clean-rebuild/restart 의 쓰기·파일 주입 경로): 남의 것이면 config 해석조차 안 간다
FAKE_OWNER_DIRS="$KAY" cz up --stored "$TMP/stored.yml" --project-dir "$MINE" "${VERB_COMMON[@]}" --build
[[ "$RC" != 0 ]] || fail "up: 남의 스택인데 성공 코드"
[[ -z "$(writes)" ]] || fail "up: 남의 스택인데 docker 호출이 나갔다: $(writes)"
grep -q "$KAY" <<<"$OUT" || fail "up: 안내에 상대 폴더가 없다"
# up: 내 것이면 가드를 지나 config 해석까지 간다, 조회는 한 번
FAKE_OWNER_DIRS="$MINE" cz up --stored "$TMP/stored.yml" --project-dir "$MINE" "${VERB_COMMON[@]}"
grep -q "config --format json" "$LOG" || fail "up: 내 것인데 진행하지 않음: $OUT"
[[ "$(grep -c ' ps -a --filter' "$LOG")" == 1 ]] || fail "up: 가드 조회가 한 번이 아니다"

# ADOPT=1 → 가드를 건너뛴다(조회도 없다), 메시지 없이 진행
MARINA_REMOTE_ADOPT=1 FAKE_OWNER_DIRS="$KAY" cz down "${VERB_COMMON[@]}" --project-dir "$MINE"
[[ "$RC" == 0 ]] || fail "ADOPT 인데 막힘: $OUT"
! grep -q " ps -a" "$LOG" || fail "ADOPT 인데 조회를 했다"
grep -q "compose -p mdc-main down" "$LOG" || fail "ADOPT 인데 진행 안 함"

# 조회 실패 → 모르면 건드리지 않는다
FAKE_PS_FAIL=1 cz down "${VERB_COMMON[@]}" --project-dir "$MINE"
[[ "$RC" != 0 ]] || fail "조회 실패인데 진행(성공 코드)"
[[ -z "$(writes)" ]] || fail "조회 실패인데 docker 호출이 나갔다: $(writes)"
grep -q "MARINA_REMOTE_ADOPT=1" <<<"$OUT" || fail "조회 실패 안내에 탈출구가 없다: $OUT"

# 원격인데 내 폴더를 못 받았다(--project-dir 없음) → 판정 불가라 거부
FAKE_OWNER_DIRS="" cz down "${VERB_COMMON[@]}"
[[ "$RC" != 0 && -z "$(writes)" ]] || fail "project-dir 없는 원격 down 이 진행됨"

# status(조회 전용): 가드는 없고, 남의 것이면 stderr 한 줄 경고. stdout 은 그대로.
FAKE_OWNER_DIRS="$KAY" cz status "${VERB_COMMON[@]}" --project-dir "$MINE" --ports-only
[[ "$RC" == 0 ]] || fail "status 가 막힘: $OUT"
grep -q "박스에 같은 이름 \`mdc-main\` 의 다른 사람 스택이 있다 — 주인 폴더: $KAY" <<<"$OUT" || fail "status 경고가 없다: $OUT"
grep -q "compose -p mdc-main ps" "$LOG" || fail "status 가 ps 를 안 불렀다"
FAKE_OWNER_DIRS="$MINE" cz status "${VERB_COMMON[@]}" --project-dir "$MINE" --ports-only
! grep -q "다른 사람 스택" <<<"$OUT" || fail "내 것인데 경고가 나왔다"

# marina_cli 는 로그인 셸의 PATH 를 덧씌운다 — 가짜 셸이 가짜 docker 가 앞선 PATH 를 내놓게 해서 그 경로에서도 가짜 docker 를 탄다.
printf '#!/bin/sh\necho "PATH=%s:%s"\n' "$FB" "$PATH" > "$TMP/fakeshell"; chmod +x "$TMP/fakeshell"

# ── 워크트리 삭제 회수(marina_lifecycle) ────────────────────────────────────────
R="$TMP/repo"; mkdir -p "$R"
git -C "$R" init -q; git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'services:\n  app:\n    build: .\n' > "$R/docker-compose.yml"
bash "$SCRIPTS/marina.sh" project add "$R" --compose "$R/docker-compose.yml" >/dev/null
mkdir -p "$R/.claude/worktrees"; git -C "$R" worktree add -q "$R/.claude/worktrees/x" -b x
WT="$(cd "$R/.claude/worktrees/x" && pwd -P)"   # marina 가 compose 에 넘기는 $ROOT 는 물리 경로(pwd -P)
(cd "$R" && bash "$SCRIPTS/marina-entrypoint.sh" runtime use ssh://pbox --project >/dev/null)

reclaim() {
  : > "$LOG"
  PATH="$FB:$PATH" PYTHONPATH="$SCRIPTS" python3 - "$WT" <<'PY'
import json, sys
from pathlib import Path
import marina_lifecycle
print(json.dumps(marina_lifecycle.reclaim_worktree_docker(Path(sys.argv[1]), volumes="all"), ensure_ascii=False))
PY
}
out="$(FAKE_OWNER_DIRS="$KAY" reclaim)"
! grep -qE " (volume|image) rm " "$LOG" || fail "남의 스택인데 회수가 지웠다"
grep -q "다른 사람 스택" <<<"$out" || fail "회수 결과에 건너뛴 이유가 없다: $out"
out="$(FAKE_OWNER_DIRS="$WT" reclaim)"
grep -q "volume rm marina_vol1" "$LOG" || fail "내 스택 회수가 안 지웠다: $out"
# I3: 컨테이너 0개(상대가 내려 둔 동안)는 주인을 모른다 — 이 워크트리가 띄운 기록이 없으면 지우지 않는다(실패 방향은 누수)
out="$(FAKE_OWNER_DIRS="" reclaim)"
! grep -qE " (volume|image) rm " "$LOG" || fail "컨테이너 0개·기록 없음인데 회수가 지웠다"
grep -q "이 워크트리가 이 박스에 띄운 기록이 없어 회수를 건너뜀" <<<"$out" || fail "기록 없음 안내가 없다: $out"
mark_owned() {  # $1=워크트리 $2=host $3=compose 프로젝트 이름
  PYTHONPATH="$SCRIPTS" python3 - "$1" "$2" "$3" <<'PY'
import sys
from pathlib import Path
import marina_paths, marina_remote_owner
marina_remote_owner.write_owned(str(marina_paths.session_dir(Path(sys.argv[1]))), sys.argv[2], sys.argv[3])
PY
}
mark_owned "$WT" ssh://pbox repo-x
out="$(FAKE_OWNER_DIRS="" reclaim)"
grep -q "volume rm marina_vol1" "$LOG" || fail "컨테이너 0개·기록 있음인데 회수가 안 지웠다: $out"
mark_owned "$WT" ssh://otherbox repo-x
out="$(FAKE_OWNER_DIRS="" reclaim)"
! grep -qE " (volume|image) rm " "$LOG" || fail "다른 박스의 기록으로 회수가 지웠다"
WT_REC="$(PYTHONPATH="$SCRIPTS" python3 -c 'import sys; from pathlib import Path; import marina_paths; print(marina_paths.session_dir(Path(sys.argv[1])) / "remote-owned.json")' "$WT")"
rm -f "${WT_REC:?}"
out="$(MARINA_REMOTE_ADOPT=1 FAKE_OWNER_DIRS="$KAY" reclaim)"
grep -q "volume rm marina_vol1" "$LOG" || fail "ADOPT 인데 회수가 막혔다"

clear_fn() {  # $1 = clear_worktree_images | clear_worktree_cache
  : > "$LOG"
  PATH="$FB:$PATH" PYTHONPATH="$SCRIPTS" python3 - "$WT" "$1" <<'PY'
import sys
from pathlib import Path
import marina_lifecycle
# 픽스처를 단순하게: 지울 대상이 있다고 치고(compose 해석은 이 테스트의 관심사가 아니다) 가드 위치만 본다.
marina_lifecycle.compose_build_image_items = lambda root: [{"type": "image", "imageId": "sha256:abc", "sizeMb": 1}]
marina_lifecycle.cache_items_by_category = lambda root: {"nm": [{"type": "volume", "volume": "repo-x_nm", "sizeMb": 1}]}
try:
    getattr(marina_lifecycle, sys.argv[2])(Path(sys.argv[1]))
    print("NOERR")
except ValueError as exc:
    print("VALUEERROR " + str(exc))
PY
}
for fn in clear_worktree_images clear_worktree_cache; do
  out="$(FAKE_OWNER_DIRS="$KAY" clear_fn "$fn")"
  grep -q "^VALUEERROR .*다른 사람 스택" <<<"$out" || fail "$fn: 남의 스택인데 거부 안 함: $out"
  ! grep -qE " (volume|image) rm " "$LOG" || fail "$fn: 남의 스택인데 지웠다"
done

# ── CLI 끝에서 끝까지: marina stop --all / status 가 내 폴더($ROOT)를 --project-dir 로 넘긴다 ──
cli() { : > "$LOG"; RC=0; OUT="$(cd "$WT" && SHELL="$TMP/fakeshell" PATH="$FB:$PATH" bash "$SCRIPTS/marina-entrypoint.sh" "$@" 2>&1)" || RC=$?; }
FAKE_OWNER_DIRS="$KAY" cli stop --all
[[ "$RC" != 0 ]] || fail "marina stop --all: 남의 스택인데 성공 코드: $OUT"
! grep -q "compose -p repo-x down" "$LOG" || fail "marina stop --all: 남의 스택인데 down 이 나갔다"
grep -q "MARINA_REMOTE_ADOPT=1" <<<"$OUT" || fail "marina stop --all: 안내가 없다: $OUT"
FAKE_OWNER_DIRS="$WT" cli stop --all
[[ "$RC" == 0 ]] || fail "marina stop --all: 내 스택인데 막힘(rc=$RC): $OUT"
grep -q "DH=ssh://pbox compose -p repo-x down" "$LOG" || fail "marina stop --all: 내 스택인데 down 이 안 나갔다"
FAKE_OWNER_DIRS="$KAY" cli status
grep -q "다른 사람 스택이 있다 — 주인 폴더: $KAY" <<<"$OUT" || fail "marina status: 경고가 없다: $OUT"
# ── C1: 남의 스택에서 marina start → docker 쓰기 0건 + watch 갱신 0건 ──────────────────
no_writes() {  # 가드 조회·읽기 전용 호출을 뺀 나머지(쓰기·watch·갱신)가 하나도 없어야 한다
  ! grep -vE ' ps -a --filter label=| info$| compose version' "$LOG" | grep -q .
}
for verb in "start --all" "restart --all" "rebuild --all" "clean-rebuild --all" "stop --all"; do
  FAKE_OWNER_DIRS="$KAY" cli $verb
  [[ "$RC" != 0 ]] || fail "marina $verb: 남의 스택인데 성공 코드: $OUT"
  no_writes || fail "marina $verb: 남의 스택인데 docker 호출(쓰기·watch 갱신)이 나갔다: $(cat "$LOG")"
  [[ "$(grep -c ' ps -a --filter' "$LOG")" == 1 ]] || fail "marina $verb: 조회가 한 번이 아니다"
done
FAKE_OWNER_DIRS="$KAY" cli stop --app
{ [[ "$RC" != 0 ]] && no_writes; } || fail "marina stop --app: 남의 스택인데 호출이 나갔다: $(cat "$LOG")"
# cmd_watch 자체도 가드(남의 스택에 watcher 를 붙이지 않는다)
FAKE_OWNER_DIRS="$KAY" cz watch --stored "$TMP/stored.yml" --project-dir "$MINE" "${VERB_COMMON[@]}" --service web
[[ "$RC" == 3 ]] || fail "watch: 남의 스택인데 rc=$RC: $OUT"
! grep -q " watch" "$LOG" || fail "watch: 남의 스택에 watcher 가 붙었다"
FAKE_OWNER_DIRS="$MINE" cz watch --stored "$TMP/stored.yml" --project-dir "$MINE" "${VERB_COMMON[@]}" --service web
grep -q "compose .* watch" "$LOG" || fail "watch: 내 스택인데 watcher 가 안 떴다: $OUT"
# 거부 종류가 갈린다: 남의 것=3, 확인 불가=4 (워크트리 삭제가 둘을 다르게 다룬다)
FAKE_OWNER_DIRS="$KAY" cz down "${VERB_COMMON[@]}" --project-dir "$MINE"; [[ "$RC" == 3 ]] || fail "남의 것의 rc 가 3 이 아니다: $RC"
FAKE_PS_FAIL=1 cz down "${VERB_COMMON[@]}" --project-dir "$MINE"; [[ "$RC" == 4 ]] || fail "확인 불가의 rc 가 4 가 아니다: $RC"

# ── S1: 내 스택이면 한 명령에 조회는 한 번(앞단에서 통과하면 up 에서 다시 묻지 않는다) ─────
FAKE_OWNER_DIRS="$WT" cli start --all
[[ "$(grep -c ' ps -a --filter' "$LOG")" == 1 ]] || fail "marina start: 조회가 한 번이 아니다: $(grep -c ' ps -a --filter' "$LOG")"
grep -q "config --format json" "$LOG" || fail "marina start: 내 스택인데 up 까지 못 갔다: $OUT"
FAKE_OWNER_DIRS="$WT" cli restart --all
[[ "$(grep -c ' ps -a --filter' "$LOG")" == 1 ]] || fail "marina restart --all: down+up 인데 조회가 한 번이 아니다"

# ── I3: up 성공 기록 + 기록 없는 0개 스택에 같은 이름 볼륨이 있으면 경고 ──────────────────
rm -f "${SD:?}/remote-owned.json"
FAKE_CONFIG_APP=1 FAKE_OWNER_DIRS="" cz up --stored "$TMP/stored.yml" --project-dir "$MINE" "${VERB_COMMON[@]}"
[[ "$RC" == 0 ]] || fail "up 이 실패(rc=$RC): $OUT"
grep -q "박스에 같은 이름의 볼륨이 이미 있다 — 다른 사람이 내려 둔 스택일 수 있다" <<<"$OUT" || fail "볼륨 경고가 없다: $OUT"
[[ -f "$SD/remote-owned.json" ]] || fail "up 성공 뒤 remote-owned.json 이 없다"
python3 - "$SD/remote-owned.json" <<'PY' || fail "remote-owned.json 내용이 틀리다"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["host"] == "ssh://pbox" and d["project"] == "mdc-main" and d["at"], d
PY
FAKE_CONFIG_APP=1 FAKE_OWNER_DIRS="" cz up --stored "$TMP/stored.yml" --project-dir "$MINE" "${VERB_COMMON[@]}"
! grep -q "볼륨이 이미 있다" <<<"$OUT" || fail "기록이 있는데 볼륨 경고가 나왔다"
rm -f "${SD:?}/remote-owned.json"
printf '{"kind":"local"}\n' > "$SD/runtime-target.json"
FAKE_CONFIG_APP=1 cz up --stored "$TMP/stored.yml" --project-dir "$MINE" "${VERB_COMMON[@]}"
! grep -q "volume ls" "$LOG" || fail "로컬 up 이 볼륨을 조회했다"
[[ ! -f "$SD/remote-owned.json" ]] || fail "로컬 up 이 기록을 남겼다"
printf '{"kind":"remote","host":"ssh://pbox"}\n' > "$SD/runtime-target.json"

# ── I5·I3: 워크트리 삭제 ─────────────────────────────────────────────────────────
rm_wt() {  # $1=루트 레포 $2=워크트리 이름 — remove_worktree(force) 결과를 찍는다
  : > "$LOG"
  SHELL="$TMP/fakeshell" PATH="$FB:$PATH" PYTHONPATH="$SCRIPTS" python3 - "$1/.claude/worktrees/$2" <<'PY' 2>&1
import json, sys
from pathlib import Path
import marina_lifecycle
try:
    print("RESULT " + json.dumps(marina_lifecycle.remove_worktree(Path(sys.argv[1]), force=True), ensure_ascii=False, default=str))
except Exception as exc:
    print("RAISED " + str(exc))
PY
}
git -C "$R" worktree add -q "$R/.claude/worktrees/y" -b y
mark_owned "$(cd "$R/.claude/worktrees/y" && pwd -P)" ssh://pbox repo-y
# 이름이 겹친 워크트리 삭제: stop·회수는 건너뛰고 삭제는 진행한다(이유는 결과에)
out="$(FAKE_OWNER_DIRS="$KAY" rm_wt "$R" y)"
grep -q "^RESULT" <<<"$out" || fail "남의 스택과 이름이 겹친 워크트리 삭제가 막혔다: $out"
[[ ! -d "$R/.claude/worktrees/y" ]] || fail "삭제가 진행되지 않았다"
grep -q "stopSkipped" <<<"$out" || fail "건너뛴 이유가 결과에 없다: $out"
! grep -qE " (down|stop|volume rm|image rm)" "$LOG" || fail "남의 스택인데 stop·회수가 나갔다: $(cat "$LOG")"
# 박스가 안 닿으면(확인 불가) 지금처럼 중단한다
git -C "$R" worktree add -q "$R/.claude/worktrees/w" -b w
out="$(FAKE_PS_FAIL=1 rm_wt "$R" w)"
grep -q "^RAISED" <<<"$out" || fail "박스 불통인데 삭제가 진행됐다: $out"
[[ -d "$R/.claude/worktrees/w" ]] || fail "박스 불통인데 워크트리가 지워졌다"
# 세션 계층에만 원격 설정이 있는 워크트리: 세션 폴더가 지워진 뒤에도 회수가 그 박스를 본다
R2="$TMP/repo2"; mkdir -p "$R2"
git -C "$R2" init -q; git -C "$R2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'services:\n  app:\n    build: .\n' > "$R2/docker-compose.yml"
bash "$SCRIPTS/marina.sh" project add "$R2" --compose "$R2/docker-compose.yml" >/dev/null
mkdir -p "$R2/.claude/worktrees"; git -C "$R2" worktree add -q "$R2/.claude/worktrees/z" -b z
Z="$(cd "$R2/.claude/worktrees/z" && pwd -P)"
SZ="$(PYTHONPATH="$SCRIPTS" python3 -c 'import sys; from pathlib import Path; import marina_paths; print(marina_paths.session_dir(Path(sys.argv[1])))' "$Z")"
mkdir -p "$SZ"; printf '{"kind":"remote","host":"ssh://pbox"}\n' > "$SZ/runtime-target.json"
mark_owned "$Z" ssh://pbox repo2-z
out="$(FAKE_OWNER_DIRS="" rm_wt "$R2" z)"
grep -q "^RESULT" <<<"$out" || fail "세션 원격 워크트리 삭제 실패: $out"
grep -q "DH=ssh://pbox volume rm marina_vol1" "$LOG" || fail "세션 원격 설정인데 회수가 박스를 안 봤다: $(cat "$LOG")"
! grep -q "^DH= volume rm" "$LOG" || fail "세션 폴더가 지워진 뒤 회수가 로컬 데몬을 봤다"

# ── S4·S5: 조회 타임아웃 문구, 중단 시 자식 정리 ───────────────────────────────────
PATH="$FB:$PATH" PYTHONPATH="$SCRIPTS" FAKE_PS_PIDFILE="$TMP/ps.pid" python3 - "$TMP/ps.pid" <<'PY' || fail "S4/S5 단위 확인 실패"
import os, signal, sys, threading, time
import marina_remote_owner as ro
v = ro.check("mdc-main", "/x", dict(os.environ), timeout=1)
assert not v.ok and v.reason == "unreachable", vars(v)
assert "응답하지 않았다" in v.detail and "timed out" not in v.detail, v.detail
assert "응답하지 않았다" in ro.message("mdc-main", v), ro.message("mdc-main", v)
pidfile = sys.argv[1]
threading.Timer(0.7, lambda: os.kill(os.getpid(), signal.SIGINT)).start()
try:
    ro.check("mdc-main", "/x", dict(os.environ), timeout=20)
    raise SystemExit("KeyboardInterrupt 가 안 올라왔다")
except KeyboardInterrupt:
    pass
pid = int(open(pidfile).read())
time.sleep(0.3)
try:
    os.kill(pid, 0)
    raise SystemExit("중단 뒤 자식 프로세스가 남았다")
except ProcessLookupError:
    pass
PY
echo PASS
