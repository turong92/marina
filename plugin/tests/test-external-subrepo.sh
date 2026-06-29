#!/usr/bin/env bash
# 외부 서브레포: project add --external name=path 로 registry 기록 + attach 가 워크트리마다 git worktree+브랜치로
# .workspace/external/<name> 에 체크아웃 + teardown 정리. git 필요.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
command -v git >/dev/null 2>&1 || { echo "SKIP test-external-subrepo (git 없음)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"
P="$TMP/proj"; mkdir -p "$P"
EXT="$TMP/ext-lib"; mkdir -p "$EXT"
git -C "$EXT" init -q
git -C "$EXT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# B1: 등록 → registry externalRepos
bash "$SH" project add "$P" --external "be-api=$EXT" >/dev/null
python3 - "$MARINA_HOME" "$P" "$EXT" <<'PY' || { echo "FAIL: registry externalRepos"; exit 1; }
import json, os, sys
home, P, EXT = sys.argv[1], os.path.realpath(sys.argv[2]), os.path.realpath(sys.argv[3])
d = json.load(open(os.path.join(home, "projects.json")))
norm = lambda p: os.path.realpath(os.path.expanduser(p))
pr = next(x for x in d["projects"] if norm(x["root"]) == P)
er = pr.get("externalRepos") or []
assert er and er[0]["name"] == "be-api" and norm(er[0]["source"]) == EXT, er
PY
echo "PASS test-external-subrepo (registry)"

# B2: attach 가 외부 레포를 워크트리에 git worktree + per-worktree 브랜치로 (MARINA_EXTERNAL_REPOS env 주입)
DEST="$TMP/wt"; mkdir -p "$DEST"
git -C "$EXT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c2
SOURCE_ROOT="$P" DEST_ROOT="$DEST" MARINA_HOME="$MARINA_HOME" BRANCH_PREFIX=claude \
  MARINA_EXTERNAL_REPOS="be-api=$EXT" \
  bash "$HERE/../scripts/attach-detached-subrepos.sh" >/dev/null 2>&1 || true
[[ -e "$DEST/.workspace/external/be-api/.git" ]] || { echo "FAIL: external worktree 없음"; exit 1; }
br="$(git -C "$DEST/.workspace/external/be-api" branch --show-current)"
[[ "$br" == claude/* ]] || { echo "FAIL: external 브랜치 '$br' (claude/* 아님)"; exit 1; }
echo "PASS test-external-subrepo (attach)"

# B3: 워크트리 제거(dst rm) 후 re-attach → prune 으로 stale 항목 정리하고 재생성, 누적 안 됨
rm -rf "$DEST/.workspace/external/be-api"
SOURCE_ROOT="$P" DEST_ROOT="$DEST" MARINA_HOME="$MARINA_HOME" BRANCH_PREFIX=claude \
  MARINA_EXTERNAL_REPOS="be-api=$EXT" \
  bash "$HERE/../scripts/attach-detached-subrepos.sh" >/dev/null 2>&1 || true
[[ -e "$DEST/.workspace/external/be-api/.git" ]] || { echo "FAIL: re-attach 후 worktree 없음(prune 안 됨)"; exit 1; }
cnt="$(git -C "$EXT" worktree list | grep -c "external/be-api" || true)"
[[ "$cnt" -le 1 ]] || { echo "FAIL: stale worktree 누적 ($cnt)"; exit 1; }
echo "PASS test-external-subrepo (re-attach/prune)"
