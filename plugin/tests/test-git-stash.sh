#!/usr/bin/env bash
# /api/git-stash (save/apply/drop) + git-graph stashes 노출 — 깃 탭 STASHES 라운드.
# 워크트리에서 save(untracked 포함) → 그래프 payload 에 브랜치 파싱된 스태시 → apply 로 복원(스태시 유지) → drop.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"
PORT=39742; base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")

SRC="$TMP/src"; mkdir -p "$SRC"
git -C "$SRC" init -q -b main; git -C "$SRC" config user.email t@t.invalid; git -C "$SRC" config user.name T
echo base > "$SRC/r"; git -C "$SRC" add r; git -C "$SRC" commit -qm init
bash "$SH" project add "$SRC" >/dev/null
WT="$TMP/wt/feat-s"; mkdir -p "$TMP/wt"
git -C "$SRC" worktree add -q -b feat/s "$WT" main
python3 - "$MARINA_HOME/projects.json" "$TMP/wt/*" <<'PY'
import json, sys
f, glob = sys.argv[1], sys.argv[2]
d = json.load(open(f)); d["projects"][0]["worktreeGlobs"] = [glob]
json.dump(d, open(f, "w"), ensure_ascii=False, indent=2)
PY

echo dirty >> "$WT/r"          # tracked 수정
echo newfile > "$WT/n.txt"     # untracked

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

# ── (a) save — untracked 포함 전부 치워지고 워킹트리 클린 ──
curl -s "${hdr[@]}" -X POST "$base/api/git-stash" -d "{\"root\":\"$WT\",\"repo\":\".\",\"op\":\"save\",\"message\":\"테스트 스태시\"}" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('ok') is True, d" || { echo 'FAIL: stash save'; exit 1; }
[[ -z "$(git -C "$WT" status --porcelain)" ]] || { echo 'FAIL: save 후 워킹트리 안 비움'; exit 1; }

# ── (b) 그래프 payload — 스태시 노출 + 브랜치 파싱 ──
curl -s "${hdr[@]}" "$base/api/git-graph?root=$SRC&repo=.&refresh=1" | python3 -c "
import json, sys
g = json.load(sys.stdin)
st = g.get('stashes') or []
assert len(st) == 1, st
assert st[0]['ref'] == 'stash@{0}' and st[0]['branch'] == 'feat/s', st[0]
assert '테스트 스태시' in st[0]['msg'], st[0]
" || { echo 'FAIL: graph stashes payload'; exit 1; }

# ── (c) apply — 파일 복원 + 스태시 유지(pop 아님) ──
curl -s "${hdr[@]}" -X POST "$base/api/git-stash" -d "{\"root\":\"$WT\",\"repo\":\".\",\"op\":\"apply\",\"ref\":\"stash@{0}\"}" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('ok') is True, d" || { echo 'FAIL: stash apply'; exit 1; }
grep -q dirty "$WT/r" && [[ -f "$WT/n.txt" ]] || { echo 'FAIL: apply 후 변경 미복원'; exit 1; }
[[ "$(git -C "$WT" stash list | wc -l | tr -d ' ')" == "1" ]] || { echo 'FAIL: apply 가 스태시를 지움'; exit 1; }

# ── (d) 가드 — 나쁜 ref·나쁜 op·변경 없는 save ──
curl -s "${hdr[@]}" -X POST "$base/api/git-stash" -d "{\"root\":\"$WT\",\"repo\":\".\",\"op\":\"apply\",\"ref\":\"stash@{0}; rm -rf /\"}" | grep -q error || { echo 'FAIL: ref 검증 없음'; exit 1; }
curl -s "${hdr[@]}" -X POST "$base/api/git-stash" -d "{\"root\":\"$WT\",\"repo\":\".\",\"op\":\"pop\",\"ref\":\"stash@{0}\"}" | grep -q error || { echo 'FAIL: op 화이트리스트 없음'; exit 1; }

# ── (e) drop — 삭제 후 목록 0 ──
git -C "$WT" checkout -q -- r; rm -f "$WT/n.txt"   # apply 복원분 정리(드롭과 무관하게 클린 상태로)
curl -s "${hdr[@]}" -X POST "$base/api/git-stash" -d "{\"root\":\"$WT\",\"repo\":\".\",\"op\":\"drop\",\"ref\":\"stash@{0}\"}" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('ok') is True, d" || { echo 'FAIL: stash drop'; exit 1; }
[[ -z "$(git -C "$WT" stash list)" ]] || { echo 'FAIL: drop 후 스태시 잔존'; exit 1; }
curl -s "${hdr[@]}" -X POST "$base/api/git-stash" -d "{\"root\":\"$WT\",\"repo\":\".\",\"op\":\"save\"}" | grep -q error || { echo 'FAIL: 변경 없는 save 에러 없음'; exit 1; }

echo "PASS test-git-stash"
