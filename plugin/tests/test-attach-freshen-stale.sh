#!/usr/bin/env bash
# attach 가 "이미 존재하는" 워크트리 브랜치를 재사용할 때의 born-stale 최신화 규칙.
# Claude/Codex 앱이 stale 로컬 HEAD 에서 브랜치를 먼저 만들어 두면(고유 커밋 0), attach 는
# 신규-브랜치 fetch-fresh 를 못 타고 그 stale 브랜치를 그대로 물려받는다 → 여기서 잡는다.
#   1) 고유 커밋 0 + clean + 뒤처짐 → <remote>/HEAD 로 fast-forward (자동)
#   2) 고유 커밋 있음(진짜 작업)     → 손대지 않음 (작업 보존)
#   3) MARINA_ATTACH_BASE pin        → 사용자 의도 존중, 최신화 건너뜀
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
ATTACH_SCRIPT="$PLUGIN_DIR/scripts/attach-detached-subrepos.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/marina-attach-freshen.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

marina_home="$tmp/marina"; mkdir -p "$marina_home"
marina_home="$(cd "$marina_home" && pwd -P)"

git_cfg() { git -C "$1" config user.email "test@example.invalid"; git -C "$1" config user.name "Marina Test"; }

# 원격: old → new(최신) 2커밋을 main 에 올린다.
make_remote() {
  local bare="$1" work="$tmp/seed-$(basename "$1")"
  git init -q --bare "$bare"
  git init -q "$work"; git_cfg "$work"
  printf 'old\n' > "$work/f"; git -C "$work" add f; git -C "$work" commit -q -m "old"
  git -C "$work" branch -M main; git -C "$work" push -q "$bare" main
  printf 'new\n' > "$work/f"; git -C "$work" commit -q -a -m "new (remote only)"
  git -C "$work" push -q "$bare" main
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  rm -rf "$work"
}

subject() { git -C "$1" log -1 --format='%s'; }

# 부모 레포
source_root="$tmp/source/proj"; mkdir -p "$source_root"
git init -q "$source_root"; git_cfg "$source_root"
printf 'ok\n' > "$source_root/README.md"; git -C "$source_root" add README.md
git -C "$source_root" commit -q -m "test: initial"
source_root="$(cd "$source_root" && pwd -P)"

make_remote "$tmp/remote-web.git"
make_remote "$tmp/remote-app.git"
make_remote "$tmp/remote-pin.git"

run_attach() {  # $1=dest, $2=subrepos, 나머지 env
  local dest="$1" subs="$2"; shift 2
  env MARINA_HOME="$marina_home" SOURCE_ROOT="$source_root" DEST_ROOT="$dest" \
      MARINA_SUBREPOS="$subs" SYNC_IDEA=false "$@" "$ATTACH_SCRIPT"
}

# ── 1)+2) web=stale·clean·고유0(→FF) · app=고유커밋(→보존) : 한 워크트리(feature/foo) ──
git clone -q "$tmp/remote-web.git" "$source_root/web"; git_cfg "$source_root/web"
git -C "$source_root/web" branch feature/foo origin/main~1            # stale, 고유 0, clean

git clone -q "$tmp/remote-app.git" "$source_root/app"; git_cfg "$source_root/app"
git -C "$source_root/app" switch -q -c feature/foo origin/main~1
printf 'mine\n' > "$source_root/app/w"; git -C "$source_root/app" add w
git -C "$source_root/app" commit -q -m "my work"                      # feature/foo 에 고유 커밋
git -C "$source_root/app" switch -q main

dest="$tmp/wt/feature-foo"
git -C "$source_root" worktree add -q -b feature/foo "$dest"
dest="$(cd "$dest" && pwd -P)"
run_attach "$dest" "web app" >/dev/null

got="$(subject "$dest/web")"
[[ "$got" == "new (remote only)" ]] \
  || { echo "FAIL: web 최신화 안 됨 (got=$got, expected 'new (remote only)')" >&2; exit 1; }

got="$(subject "$dest/app")"
[[ "$got" == "my work" ]] \
  || { echo "FAIL: app 의 고유 작업이 최신화로 덮임 (got=$got)" >&2; exit 1; }

# ── 3) MARINA_ATTACH_BASE pin → stale 이어도 freshen 건너뜀 ──────────
git clone -q "$tmp/remote-pin.git" "$source_root/pin"; git_cfg "$source_root/pin"
git -C "$source_root/pin" branch feature/pin origin/main~1            # stale (web 과 동일 조건)

dest2="$tmp/wt/feature-pin"
git -C "$source_root" worktree add -q -b feature/pin "$dest2"
dest2="$(cd "$dest2" && pwd -P)"
run_attach "$dest2" "pin" MARINA_ATTACH_BASE="origin/main" >/dev/null
got="$(subject "$dest2/pin")"
[[ "$got" == "old" ]] \
  || { echo "FAIL: MARINA_ATTACH_BASE pin 인데 freshen 됨 (got=$got, expected 'old')" >&2; exit 1; }

echo "PASS test-attach-freshen-stale"
