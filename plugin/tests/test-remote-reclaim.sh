#!/usr/bin/env bash
# 워크트리 삭제·자동 GC 의 이미지·볼륨 회수가 **그 워크트리의 런타임 타깃 데몬**을 본다.
# 프로젝트 단위로 원격을 걸면 mdc 워크트리 전부가 박스에서 도는데, 회수가 로컬 데몬만 보면 로컬의 엉뚱한 것을
# 지우거나(이름이 같으면) 박스의 것은 영영 안 지운다. 박스가 안 닿으면 로컬로 대신하지 않고 건너뛰고 경고한다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$HERE/../scripts"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
R="$TMP/repo"; mkdir -p "$R"
git -C "$R" init -q; git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'services:\n  app:\n    build: .\n' > "$R/docker-compose.yml"
bash "$SCRIPTS/marina.sh" project add "$R" --compose "$R/docker-compose.yml" >/dev/null
mkdir -p "$R/.claude/worktrees"; git -C "$R" worktree add -q "$R/.claude/worktrees/x" -b x
FB="$TMP/fakebin"; mkdir -p "$FB"; LOG="$TMP/docker.log"
cat > "$FB/docker" <<'SH'
#!/usr/bin/env bash
echo "DH=${DOCKER_HOST:-} $*" >> "$DOCKER_LOG"
if [[ "${FAKE_BOX_DOWN:-}" == 1 && -n "${DOCKER_HOST:-}" ]]; then exit 1; fi
case "$*" in
  "volume ls"*) echo marina_vol1 ;;
  "system df"*) echo '{}' ;;
esac
exit 0
SH
chmod +x "$FB/docker"
export DOCKER_LOG="$LOG"

run() {  # $1=FAKE_BOX_DOWN
  : > "$LOG"
  FAKE_BOX_DOWN="$1" PATH="$FB:$PATH" PYTHONPATH="$SCRIPTS" python3 - "$R/.claude/worktrees/x" <<'PY'
import json, sys
from pathlib import Path
import marina_lifecycle
print(json.dumps(marina_lifecycle.reclaim_worktree_docker(Path(sys.argv[1]), volumes="all"), ensure_ascii=False))
PY
}
fail() { echo "FAIL: $1"; exit 1; }

# 로컬(설정 없음): 호출은 전부 DOCKER_HOST 없이, 사전 점검(info)도 추가되지 않는다 — 기존 동작 그대로
run 0 >/dev/null
[[ -s "$LOG" ]] || fail "회수가 docker 를 안 불렀다(픽스처 오류)"
! grep -v "^DH= " "$LOG" | grep -q . || fail "로컬인데 DOCKER_HOST 가 잡힘: $(cat "$LOG")"
! grep -q "^DH= info" "$LOG" || fail "로컬 경로에 사전 점검이 끼어들었다: $(cat "$LOG")"
grep -q "volume rm marina_vol1" "$LOG" || fail "로컬 회수가 볼륨을 안 지움: $(cat "$LOG")"

# 프로젝트 원격: 모든 docker 호출이 박스를 향한다
(cd "$R" && bash "$SCRIPTS/marina-entrypoint.sh" runtime use ssh://pbox --project >/dev/null)
out="$(run 0)"
! grep -v "^DH=ssh://pbox " "$LOG" | grep -q . || fail "원격 워크트리의 회수가 로컬 데몬을 봄: $(cat "$LOG")"
grep -q "volume rm marina_vol1" "$LOG" || fail "원격 회수가 볼륨을 안 지움: $(cat "$LOG")"

# 박스가 안 닿으면: 지우지 않고(로컬 것도 안 건드림) 경고를 결과에 싣는다
out="$(run 1)"
! grep -q " rm " "$LOG" || fail "박스가 죽었는데 rm 을 시도: $(cat "$LOG")"
! grep -v "^DH=ssh://pbox " "$LOG" | grep -q . || fail "박스가 죽었는데 로컬 데몬을 건드림: $(cat "$LOG")"
grep -q "닿지 않" <<<"$out" || fail "닿지 않는다는 경고가 결과에 없다: $out"
echo PASS
