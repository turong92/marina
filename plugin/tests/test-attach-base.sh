#!/usr/bin/env bash
# attach 가 새 브랜치를 어디서 따는지 — 시작점 결정 규칙.
#   1) MARINA_ATTACH_BASE 명시 → 그 ref
#   2) 기본 → 그 레포 원격의 기본 브랜치(<remote>/HEAD). 레포마다 다를 수 있다(main/dev/master).
#   3) 원격 없음 → HEAD 폴백(구 동작)
# source 체크아웃이 stale·detached 여도 새 브랜치는 원격 기본 브랜치에서 태어나야 한다
# (= source 의 우연한 HEAD 를 물려받지 않는다). 기존 브랜치 재사용은 test-attach-branch-mirror 가 커버.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
ATTACH_SCRIPT="$PLUGIN_DIR/scripts/attach-detached-subrepos.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/marina-attach-base.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

marina_home="$tmp/marina"; mkdir -p "$marina_home"
marina_home="$(cd "$marina_home" && pwd -P)"

git_cfg() {
  git -C "$1" config user.email "test@example.invalid"
  git -C "$1" config user.name "Marina Test"
}

# 원격 레포 하나 만든다. $2 = 기본 브랜치명. 그 위에 "new" 커밋(= 최신)까지 올린다.
make_remote() {
  local bare="$1" defbranch="$2" work
  work="$tmp/seed-$(basename "$bare")"
  git init -q --bare "$bare"
  git init -q "$work"; git_cfg "$work"
  printf 'old\n' > "$work/f"
  git -C "$work" add f; git -C "$work" commit -q -m "old"
  git -C "$work" branch -M "$defbranch"
  git -C "$work" push -q "$bare" "$defbranch"
  printf 'new\n' > "$work/f"
  git -C "$work" commit -q -a -m "new (remote only)"
  git -C "$work" push -q "$bare" "$defbranch"
  git -C "$bare" symbolic-ref HEAD "refs/heads/$defbranch"
  rm -rf "$work"
}

# source 서브레포: clone 후 한 커밋 뒤로 reset + detach → 사고 상황 재현
# (로컬 HEAD="old", 원격 기본 브랜치="new")
make_stale_clone() {
  local bare="$1" dst="$2"
  git clone -q "$bare" "$dst"; git_cfg "$dst"
  git -C "$dst" reset -q --hard HEAD~1
  git -C "$dst" checkout -q --detach HEAD
}

subject() {  # 그 워크트리 서브레포가 서 있는 커밋 제목
  git -C "$1" log -1 --format='%s'
}

# ── fixture: 부모 + 서브레포 3개(main / dev / 원격없음) ───────────────────
source_root="$tmp/source/proj"; mkdir -p "$source_root"
git init -q "$source_root"; git_cfg "$source_root"
printf 'ok\n' > "$source_root/README.md"
git -C "$source_root" add README.md
git -C "$source_root" commit -q -m "test: initial"
source_root="$(cd "$source_root" && pwd -P)"

make_remote "$tmp/remote-web.git" main
make_remote "$tmp/remote-ai.git" dev          # 원격 기본이 main 이 아닌 레포
make_stale_clone "$tmp/remote-web.git" "$source_root/web"
make_stale_clone "$tmp/remote-ai.git" "$source_root/ai"

git init -q "$source_root/solo"; git_cfg "$source_root/solo"   # 원격 없는 레포
printf 'x\n' > "$source_root/solo/f"
git -C "$source_root/solo" add f
git -C "$source_root/solo" commit -q -m "solo only"

run_attach() {  # $1=dest, 나머지 env
  local dest="$1"; shift
  env MARINA_HOME="$marina_home" SOURCE_ROOT="$source_root" DEST_ROOT="$dest" \
      MARINA_SUBREPOS="web ai solo" SYNC_IDEA=false "$@" "$ATTACH_SCRIPT"
}

# ── 1) 기본: 각 레포 원격의 기본 브랜치에서 (main / dev), 원격 없으면 HEAD ──
dest1="$tmp/wt/feature-a"
git -C "$source_root" worktree add -q -b feature/a "$dest1"
dest1="$(cd "$dest1" && pwd -P)"
run_attach "$dest1" >/dev/null

got="$(subject "$dest1/web")"
[[ "$got" == "new (remote only)" ]] || { echo "FAIL: web base=$got (expected origin/main tip; stale HEAD 를 물려받음)" >&2; exit 1; }

got="$(subject "$dest1/ai")"
[[ "$got" == "new (remote only)" ]] || { echo "FAIL: ai base=$got (expected origin/dev tip)" >&2; exit 1; }
# origin/HEAD 를 안 보고 main 을 하드코딩하면 여기서 죽는다(이 레포엔 main 자체가 없음)
[[ "$(git -C "$dest1/ai" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" == "origin/dev" ]] \
  || { echo "FAIL: ai upstream != origin/dev" >&2; exit 1; }

[[ "$(subject "$dest1/solo")" == "solo only" ]] || { echo "FAIL: solo (원격 없음) HEAD 폴백 실패" >&2; exit 1; }

# upstream 이 걸려야 git status 가 behind 를 말한다(= 이어받는 세션에서 stale 이 보인다)
[[ "$(git -C "$dest1/web" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" == "origin/main" ]] \
  || { echo "FAIL: web upstream 미설정 — status 가 behind 를 못 알림" >&2; exit 1; }

# ── 2) MARINA_ATTACH_BASE 명시가 원격 기본 브랜치를 이긴다 ──────────────
git -C "$source_root/web" fetch -q origin
dest2="$tmp/wt/feature-b"
git -C "$source_root" worktree add -q -b feature/b "$dest2"
dest2="$(cd "$dest2" && pwd -P)"
run_attach "$dest2" MARINA_ATTACH_BASE="origin/main~1" >/dev/null
got="$(subject "$dest2/web")"
[[ "$got" == "old" ]] || { echo "FAIL: MARINA_ATTACH_BASE 무시됨 (got=$got)" >&2; exit 1; }

# ── 3) 없는 base 를 줘도 attach 는 죽지 않고 HEAD 로 폴백 ───────────────
dest3="$tmp/wt/feature-c"
git -C "$source_root" worktree add -q -b feature/c "$dest3"
dest3="$(cd "$dest3" && pwd -P)"
run_attach "$dest3" MARINA_ATTACH_BASE="origin/nope" >/dev/null \
  || { echo "FAIL: 존재하지 않는 base 에서 attach 가 abort (set -e)" >&2; exit 1; }
[[ -d "$dest3/solo/.git" || -f "$dest3/solo/.git" ]] || { echo "FAIL: base 실패로 뒤쪽 서브레포가 안 붙음" >&2; exit 1; }

# ── 4) 원격에만 있는 브랜치는 추적한다 (base 를 안 탄다) ────────────────
# source 는 아직 이 브랜치를 모른다(fetch 전) — attach 가 브랜치를 고르기 전에 fetch 해야 잡힌다.
seed="$tmp/seed-push"
git clone -q "$tmp/remote-web.git" "$seed"; git_cfg "$seed"
git -C "$seed" push -q origin "origin/main:refs/heads/feature/remote-only"
rm -rf "$seed"
[[ -z "$(git -C "$source_root/web" rev-parse --verify -q origin/feature/remote-only 2>/dev/null || true)" ]] \
  || { echo "FAIL: fixture 오류 — source 가 이미 원격 브랜치를 앎" >&2; exit 1; }

dest4="$tmp/wt/feature-remote-only"
git -C "$source_root" worktree add -q -b feature/remote-only "$dest4"
dest4="$(cd "$dest4" && pwd -P)"
run_attach "$dest4" MARINA_ATTACH_BASE="origin/main~1" >/dev/null
[[ "$(git -C "$dest4/web" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" == "origin/feature/remote-only" ]] \
  || { echo "FAIL: 원격 전용 브랜치를 추적 안 함 — base 에서 갈라진 브랜치를 새로 만듦" >&2; exit 1; }

# ── 5) 원격이 여러 개고 같은 이름이 겹쳐도, 고른 원격(origin)에서 이어받는다 ──
# git DWIM 은 여기서 "matched multiple remote tracking branches" 로 거절한다 → 새 브랜치를 만들면 원격 내용 유실.
git init -q --bare "$tmp/fork-web.git"
git -C "$source_root/web" remote add fork "$tmp/fork-web.git" 2>/dev/null || true
seed2="$tmp/seed-fork"
git clone -q "$tmp/remote-web.git" "$seed2"; git_cfg "$seed2"
git -C "$seed2" push -q "$tmp/fork-web.git" "origin/main~1:refs/heads/feature/dup"   # fork 쪽은 다른 커밋
git -C "$seed2" push -q origin "origin/main:refs/heads/feature/dup"                  # origin 쪽은 최신
rm -rf "$seed2"

dest5="$tmp/wt/feature-dup"
git -C "$source_root" worktree add -q -b feature/dup "$dest5"
dest5="$(cd "$dest5" && pwd -P)"
run_attach "$dest5" >/dev/null
[[ "$(git -C "$dest5/web" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" == "origin/feature/dup" ]] \
  || { echo "FAIL: 원격 이름 충돌 시 origin 을 안 집음 (upstream=$(git -C "$dest5/web" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null))" >&2; exit 1; }
[[ "$(subject "$dest5/web")" == "new (remote only)" ]] \
  || { echo "FAIL: 충돌 시 fork/base 쪽 커밋을 집음" >&2; exit 1; }

echo "PASS test-attach-base"
