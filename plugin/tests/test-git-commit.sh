#!/usr/bin/env bash
# /api/git-commit · /api/git-push — 깃 탭 P2(조작): stage 커밋·푸시 + 안전 가드(경로·빈 메시지) — main 커밋 허용(2026-07-13)
# + 커밋/푸시 후 git-graph 캐시 무효화.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export MARINA_HOME="$TMP/home"
PORT=39732; base="http://127.0.0.1:$PORT"
hdr=(-H "Origin: http://127.0.0.1:$PORT" -H "content-type: application/json")

gi() { mkdir -p "$1"; git -C "$1" init -q -b main; git -C "$1" config user.email t@t.invalid; git -C "$1" config user.name T; echo ok>"$1/r"; git -C "$1" add r; git -C "$1" commit -qm "init $2"; }

# main checkout + 워크트리(feat/commit) — commit 대상은 워크트리에서만 허용된다는 게 핵심 가드
SRC="$TMP/src"; gi "$SRC" root
bash "$SH" project add "$SRC" >/dev/null
WT="$TMP/wt/feature-x"; mkdir -p "$TMP/wt"
git -C "$SRC" worktree add -q -b feat/commit "$WT" main
python3 - "$MARINA_HOME/projects.json" "$TMP/wt/*" <<'PY'
import json, sys
f, glob = sys.argv[1], sys.argv[2]
d = json.load(open(f)); d["projects"][0]["worktreeGlobs"] = [glob]
json.dump(d, open(f, "w"), ensure_ascii=False, indent=2)
PY

echo hello > "$WT/new.txt"     # untracked
echo more >> "$WT/r"           # tracked 수정

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "${hdr[@]}" "$base/api/worktrees" >/dev/null 2>&1 && break; sleep 0.1; done

# ── (a) 정상 커밋: tracked + untracked 함께 stage ───────────────
curl -s "${hdr[@]}" -X POST "$base/api/git-commit" \
  -d "{\"root\":\"$WT\",\"repo\":\".\",\"files\":[\"new.txt\",\"r\"],\"message\":\"test commit p2\"}" \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('ok') is True, d
assert d.get('hash') and len(d['hash']) >= 7, d
assert d.get('summary') == 'test commit p2', d
" || { echo 'FAIL: git-commit ok'; exit 1; }

[[ -z "$(git -C "$WT" status --porcelain)" ]] || { echo 'FAIL: working tree not clean after commit'; exit 1; }
git -C "$WT" log -1 --format=%s | grep -qx "test commit p2" || { echo 'FAIL: commit not in git log'; exit 1; }

# 캐시 무효화 — refresh=1 없이도 새 커밋이 바로 그래프에 보여야 함
curl -s "${hdr[@]}" "$base/api/git-graph?root=$SRC&repo=." | python3 -c "
import json, sys
g = json.load(sys.stdin)
assert 'test commit p2' in [c['subject'] for c in g['commits']], [c['subject'] for c in g['commits']]
" || { echo 'FAIL: git-graph cache not invalidated after commit'; exit 1; }

# ── (b) main 체크아웃 커밋 허용 (보호 해제 — 형 확정 2026-07-13: 도구가 막을 일 아님) ──────
echo x >> "$SRC/r"
out="$(curl -s "${hdr[@]}" -X POST "$base/api/git-commit" \
  -d "{\"root\":\"$SRC\",\"repo\":\".\",\"files\":[\"r\"],\"message\":\"main commit ok\"}")"
echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('ok'), d" \
  || { echo "FAIL: main checkout commit should be allowed now"; exit 1; }

# ── (c) 경로 이탈(..) 거부 ───────────────────────────────────────
echo again >> "$WT/r"
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" -X POST "$base/api/git-commit" \
  -d "{\"root\":\"$WT\",\"repo\":\".\",\"files\":[\"../../../etc/passwd\"],\"message\":\"bad\"}")"
[[ "$code" == 4* ]] || { echo "FAIL: git-commit path traversal expected 4xx, got $code"; exit 1; }

# ── (d) 빈 메시지 거부 ───────────────────────────────────────────
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" -X POST "$base/api/git-commit" \
  -d "{\"root\":\"$WT\",\"repo\":\".\",\"files\":[\"r\"],\"message\":\"\"}")"
[[ "$code" == 4* ]] || { echo "FAIL: git-commit empty message expected 4xx, got $code"; exit 1; }

# (c)/(d) 모두 거부됐으니 r 의 미커밋 변경은 그대로 남아있어야 함
[[ -n "$(git -C "$WT" status --porcelain -- r)" ]] || { echo 'FAIL: rejected commits should not touch working tree'; exit 1; }
git -C "$WT" checkout -q -- r   # 다음 단계 전 정리

# ── (e) 푸시: origin 없음 → 실패가 그대로 전달 ──────────────────
code="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" -X POST "$base/api/git-push" -d "{\"root\":\"$WT\",\"repo\":\".\"}")"
[[ "$code" == 4* ]] || { echo "FAIL: git-push no origin expected 4xx, got $code"; exit 1; }
curl -s "${hdr[@]}" -X POST "$base/api/git-push" -d "{\"root\":\"$WT\",\"repo\":\".\"}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('error'), d
" || { echo 'FAIL: git-push error body missing'; exit 1; }

# ── (e2) 로컬 bare origin 붙이고 실 푸시 성공 경로 ──────────────
BARE="$TMP/bare.git"; git init -q --bare "$BARE"
git -C "$WT" remote add origin "$BARE"
curl -s "${hdr[@]}" -X POST "$base/api/git-push" -d "{\"root\":\"$WT\",\"repo\":\".\"}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('ok') is True, d
assert 'output' in d, d
" || { echo 'FAIL: git-push success (bare origin) failed'; exit 1; }
git --git-dir="$BARE" branch --list feat/commit | grep -q feat/commit || { echo 'FAIL: push did not create branch on bare remote'; exit 1; }
git -C "$WT" rev-parse --abbrev-ref 'feat/commit@{upstream}' >/dev/null 2>&1 || { echo 'FAIL: push -u did not set upstream'; exit 1; }

# 다시 push(이번엔 upstream 있음, plain push 경로) — 새 커밋 하나 만들어 확인
echo push2 >> "$WT/r"; git -C "$WT" add r; git -C "$WT" commit -qm "second"
curl -s "${hdr[@]}" -X POST "$base/api/git-push" -d "{\"root\":\"$WT\",\"repo\":\".\"}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('ok') is True, d
" || { echo 'FAIL: git-push (existing upstream) failed'; exit 1; }
[[ "$(git --git-dir="$BARE" rev-parse feat/commit)" == "$(git -C "$WT" rev-parse feat/commit)" ]] || { echo 'FAIL: bare remote not up to date after 2nd push'; exit 1; }

echo "PASS test-git-commit"
