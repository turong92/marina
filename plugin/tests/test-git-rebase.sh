#!/usr/bin/env bash
# /api/git-rebase · /api/git-fetch · /api/git-pull(rebase) — 깃 탭 D&D 리베이스 라운드.
# 성공(linear 재적용)·충돌 자동 abort(워크트리 원복)·진행 중 가드·fetch 갱신을 실레포로 검증.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"
PORT=39741; base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")

gi() { mkdir -p "$1"; git -C "$1" init -q -b main; git -C "$1" config user.email t@t.invalid; git -C "$1" config user.name T; echo base>"$1/r"; git -C "$1" add r; git -C "$1" commit -qm "init"; }

SRC="$TMP/src"; gi "$SRC"
bash "$SH" project add "$SRC" >/dev/null
WT="$TMP/wt/feat-a"; mkdir -p "$TMP/wt"
git -C "$SRC" worktree add -q -b feat/a "$WT" main
python3 - "$MARINA_HOME/projects.json" "$TMP/wt/*" <<'PY'
import json, sys
f, glob = sys.argv[1], sys.argv[2]
d = json.load(open(f)); d["projects"][0]["worktreeGlobs"] = [glob]
json.dump(d, open(f, "w"), ensure_ascii=False, indent=2)
PY

# 분기: main 은 새 파일 m(충돌 없음) 전진, feat/a 는 f 커밋 → rebase 하면 linear
echo m > "$SRC/m"; git -C "$SRC" add m; git -C "$SRC" commit -qm "main advance"
echo f > "$WT/f"; git -C "$WT" add f; git -C "$WT" commit -qm "feat work"

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

# ── (a) 리베이스 성공 — feat/a 가 main 위로, main advance 를 조상으로 가짐 ──
curl -s "${hdr[@]}" -X POST "$base/api/git-rebase" -d "{\"root\":\"$WT\",\"repo\":\".\",\"onto\":\"main\"}" | python3 -c "
import json, sys; d = json.load(sys.stdin); assert d.get('ok') is True, d; assert d.get('onto') == 'main', d
" || { echo 'FAIL: rebase ok'; exit 1; }
git -C "$WT" merge-base --is-ancestor "$(git -C "$SRC" rev-parse main)" HEAD || { echo 'FAIL: rebase 후 main 이 조상 아님'; exit 1; }
git -C "$WT" log -1 --format=%s | grep -qx "feat work" || { echo 'FAIL: feat 커밋 유실'; exit 1; }

# ── (b) 충돌 리베이스 — 자동 abort 로 원복(REBASE_HEAD 없음·HEAD 불변·워킹트리 클린) ──
echo conflict-main > "$SRC/r"; git -C "$SRC" add r; git -C "$SRC" commit -qm "main touches r"
echo conflict-feat > "$WT/r"; git -C "$WT" add r; git -C "$WT" commit -qm "feat touches r"
BEFORE="$(git -C "$WT" rev-parse HEAD)"
out="$(curl -s "${hdr[@]}" -X POST "$base/api/git-rebase" -d "{\"root\":\"$WT\",\"repo\":\".\",\"onto\":\"main\"}")"
echo "$out" | grep -q "rebase --abort" || { echo "FAIL: 충돌 에러에 abort 안내 없음: $out"; exit 1; }
git -C "$WT" rev-parse -q --verify REBASE_HEAD >/dev/null 2>&1 && { echo 'FAIL: REBASE_HEAD 잔존(abort 안 됨)'; exit 1; }
[[ "$(git -C "$WT" rev-parse HEAD)" == "$BEFORE" ]] || { echo 'FAIL: abort 후 HEAD 변함'; exit 1; }
[[ -z "$(git -C "$WT" status --porcelain)" ]] || { echo 'FAIL: abort 후 워킹트리 더러움'; exit 1; }

# ── (c) 가드 — 잘못된 onto 이름·자기 자신 ──
curl -s "${hdr[@]}" -X POST "$base/api/git-rebase" -d "{\"root\":\"$WT\",\"repo\":\".\",\"onto\":\"--exec=evil\"}" | grep -q error || { echo 'FAIL: onto 검증 없음'; exit 1; }
curl -s "${hdr[@]}" -X POST "$base/api/git-rebase" -d "{\"root\":\"$WT\",\"repo\":\".\",\"onto\":\"feat/a\"}" | grep -q error || { echo 'FAIL: self-rebase 거부 없음'; exit 1; }

# ── (d) fetch — bare origin 에 새 커밋 → fetch 후 그래프 원격 ref 갱신 ──
BARE="$TMP/origin.git"; git init -q --bare -b main "$BARE"
git -C "$SRC" remote add origin "$BARE"
git -C "$SRC" push -qu origin main 2>/dev/null
CLONE="$TMP/clone"; git clone -q "$BARE" "$CLONE"; git -C "$CLONE" config user.email t@t.invalid; git -C "$CLONE" config user.name T
echo remote-new > "$CLONE/z"; git -C "$CLONE" add z; git -C "$CLONE" commit -qm "remote only commit"; git -C "$CLONE" push -q
curl -s "${hdr[@]}" -X POST "$base/api/git-fetch" -d "{\"root\":\"$SRC\",\"repo\":\".\"}" | python3 -c "
import json, sys; assert json.load(sys.stdin).get('ok') is True
" || { echo 'FAIL: git-fetch'; exit 1; }
curl -s "${hdr[@]}" "$base/api/git-graph?root=$SRC&repo=." | python3 -c "
import json, sys
g = json.load(sys.stdin)
assert 'remote only commit' in [c['subject'] for c in g['commits']], '(fetch 후 원격 커밋이 그래프에 없음)'
assert any(b['branch'] == 'origin/main' and b.get('remote') for b in g['branches']), g['branches']
" || { echo 'FAIL: fetch 후 그래프 갱신'; exit 1; }

# ── (d2) 원격 전용 브랜치 — 기본은 숨김(소음 방지), all=1(REMOTE '전체' 토글)이면 노출 ──
git -C "$CLONE" checkout -qb feature/remote-only
echo ro > "$CLONE/ro"; git -C "$CLONE" add ro; git -C "$CLONE" commit -qm "remote only branch"; git -C "$CLONE" push -qu origin feature/remote-only 2>/dev/null
curl -s "${hdr[@]}" -X POST "$base/api/git-fetch" -d "{\"root\":\"$SRC\",\"repo\":\".\"}" >/dev/null
curl -s "${hdr[@]}" "$base/api/git-graph?root=$SRC&repo=.&refresh=1" | python3 -c "
import json, sys
g = json.load(sys.stdin)
assert not any(b['branch'] == 'origin/feature/remote-only' for b in g['branches']), '기본 뷰에 원격 전용 브랜치 노출(소음)'
" || { echo 'FAIL: 기본 뷰 원격 필터'; exit 1; }
curl -s "${hdr[@]}" "$base/api/git-graph?root=$SRC&repo=.&refresh=1&all=1" | python3 -c "
import json, sys
g = json.load(sys.stdin)
assert any(b['branch'] == 'origin/feature/remote-only' and b.get('remote') for b in g['branches']), [b['branch'] for b in g['branches']]
assert 'remote only branch' in [c['subject'] for c in g['commits']]
" || { echo 'FAIL: all=1 원격 전체 노출'; exit 1; }
git -C "$CLONE" checkout -q main

# ── (e) pull --rebase — 로컬 main 커밋 + 원격 전진(diverged) → 리베이스로 해소 ──
echo local-side > "$SRC/l"; git -C "$SRC" add l; git -C "$SRC" commit -qm "local only commit"
echo remote-2 > "$CLONE/z2"; git -C "$CLONE" add z2; git -C "$CLONE" commit -qm "remote second"; git -C "$CLONE" push -q
curl -s "${hdr[@]}" -X POST "$base/api/git-pull" -d "{\"root\":\"$SRC\",\"repo\":\".\",\"rebase\":true}" | python3 -c "
import json, sys; d = json.load(sys.stdin); assert d.get('ok') is True, d
" || { echo 'FAIL: pull --rebase'; exit 1; }
git -C "$SRC" log --format=%s | head -3 | grep -q "local only commit" || { echo 'FAIL: pull --rebase 후 로컬 커밋 유실'; exit 1; }

echo "PASS test-git-rebase"
