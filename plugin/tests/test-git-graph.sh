#!/usr/bin/env bash
# /api/git-graph · /api/git-diff — 레인 그래프 데이터·diff 본문·검증 가드
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"
PORT=39731; base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT")

gi() { mkdir -p "$1"; git -C "$1" init -q -b main; git -C "$1" config user.email t@t.invalid; git -C "$1" config user.name T; echo ok>"$1/r"; git -C "$1" add r; git -C "$1" commit -qm "init $2"; }

# main checkout: 루트 레포 + 서브레포 a (test-attach-detach-api.sh 와 동일 구조)
SRC="$TMP/src"; gi "$SRC" root; gi "$SRC/a" suba
bash "$SH" project add "$SRC" --subrepos a >/dev/null
# 워크트리: 루트를 feat/x 브랜치로 + 서브레포 a 를 detached 로 attach(브랜치 불일치 시나리오)
WT="$TMP/wt/feature-x"; mkdir -p "$TMP/wt"
git -C "$SRC" worktree add -q -b feat/x "$WT" main
git -C "$SRC/a" worktree add -q --detach "$WT/a" main
python3 - "$MARINA_HOME/projects.json" "$TMP/wt/*" <<'PY'
import json, sys
f, glob = sys.argv[1], sys.argv[2]
d = json.load(open(f)); d["projects"][0]["worktreeGlobs"] = [glob]
json.dump(d, open(f, "w"), ensure_ascii=False, indent=2)
PY
# feat/x 에 커밋 1개(ahead) + 미커밋 변경 1개 + untracked 1개 — 서버 기동 전에 만들어 status 캐시 이슈 회피
echo change >> "$WT/r"; git -C "$WT" add r; git -C "$WT" commit -qm "feat commit"
echo wip >> "$WT/r"
echo new > "$WT/newfile.txt"
FEAT_HEAD="$(git -C "$WT" rev-parse HEAD)"

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

# ── git-graph: 브랜치·커밋·불일치 ──────────────────────────────
curl -s "${hdr[@]}" "$base/api/git-graph?root=$SRC&repo=." | python3 -c "
import json, sys
g = json.load(sys.stdin)
assert g['repo'] == '.' and '.' in g['repos'] and 'a' in g['repos'], g.get('repos', g)
assert g['mainBranch'] == 'main', g['mainBranch']
by = {b['branch']: b for b in g['branches']}
assert 'main' in by and by['main']['isMain'] is True, by
assert 'feat/x' in by, by
fx = by['feat/x']
assert fx['head'] == '$FEAT_HEAD', fx
assert fx['merged'] is False, fx
assert fx['dirtyCount'] >= 2, fx                    # r 수정 + newfile.txt
assert fx['mismatch'], fx                           # a 는 detached attach → 불일치 보강 경로
hashes = {c['hash'] for c in g['commits']}
assert '$FEAT_HEAD' in hashes, 'feat head not in log'
assert all(set(c) >= {'hash','parents','subject','ts','author'} for c in g['commits'])
" || { echo 'FAIL: git-graph'; exit 1; }

# 알 수 없는 repo → 4xx
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" "$base/api/git-graph?root=$SRC&repo=zzz")"
[[ "$code" == 4* ]] || { echo "FAIL: git-graph bad repo expected 4xx, got $code"; exit 1; }

# ── merged 판정: feat/x 를 main 에 머지 후 refresh=1 ───────────
git -C "$SRC" merge -q --no-ff feat/x -m "merge feat/x"
curl -s "${hdr[@]}" "$base/api/git-graph?root=$SRC&repo=.&refresh=1" | python3 -c "
import json, sys
g = json.load(sys.stdin)
fx = next(b for b in g['branches'] if b['branch'] == 'feat/x')
assert fx['merged'] is True, fx
" || { echo 'FAIL: git-graph merged'; exit 1; }

# ── git-diff: working / 커밋 / untracked / 가드 ────────────────
curl -s "${hdr[@]}" "$base/api/git-diff?root=$WT&repo=." | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert '+wip' in d['text'], d['text'][:200]        # 미커밋 변경
assert d['truncated'] is False, d
" || { echo 'FAIL: git-diff working'; exit 1; }

curl -s "${hdr[@]}" "$base/api/git-diff?root=$WT&repo=.&commit=$FEAT_HEAD" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'feat commit' in d['text'] and '+change' in d['text'], d['text'][:300]
" || { echo 'FAIL: git-diff commit'; exit 1; }

curl -s "${hdr[@]}" "$base/api/git-diff?root=$WT&repo=.&file=newfile.txt" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert '+new' in d['text'], d['text'][:200]        # untracked → /dev/null 대비
" || { echo 'FAIL: git-diff untracked'; exit 1; }

# ignored/비상태 파일은 diff API 로 못 읽음 (.env 시크릿·.git 내부 가드) → 4xx
echo ".env" > "$WT/.gitignore"; echo "SECRET=x" > "$WT/.env"
for f in ".env" ".git/config"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" "$base/api/git-diff?root=$WT&repo=.&file=$f")"
  [[ "$code" == 4* ]] || { echo "FAIL: git-diff hidden file ($f) expected 4xx, got $code"; exit 1; }
done

for bad in "file=../../../etc/passwd" "commit=DROP;TABLE" "repo=zzz"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" "$base/api/git-diff?root=$WT&${bad}")"
  [[ "$code" == 4* ]] || { echo "FAIL: git-diff guard ($bad) expected 4xx, got $code"; exit 1; }
done

echo "PASS test-git-graph"
