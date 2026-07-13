#!/usr/bin/env bash
# 등록 워크벤치 진입(R1) — GET /api/repo-candidates(marina_handler.py):
# 관례 루트(존재하는 것만) 2단계 스캔 → .git 후보만, hasCompose/registered 뱃지, scanned 에 스캔 루트 노출.
# 3단계 이상은 후보에서 빠지고(비용 가드), 이미 등록된 프로젝트는 registered:true 로 표시(제외 아님).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"; CTRL="$SCR/marina-control.py"

TMP="$(mktemp -d)"
FAKEHOME="$TMP/fakehome"
export MARINA_HOME="$TMP/marinahome"; mkdir -p "$MARINA_HOME"
mkdir -p "$FAKEHOME"
SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

PORT="$(python3 - <<'PY' || exit $?
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", 0))
except PermissionError:
    sys.exit(42)
print(s.getsockname()[1])
s.close()
PY
)" || { code=$?; [[ "$code" == "42" ]] && { echo "SKIP test-repo-candidates (localhost bind unavailable)"; exit 0; }; exit "$code"; }

# ── 관례 루트 아래 후보 구조 (fake HOME) ────────────────────────────────────
git_init() { ( cd "$1" && git init -q && git commit -q --allow-empty -m init ); }

mkdir -p "$FAKEHOME/IdeaProjects/proj-a"; git_init "$FAKEHOME/IdeaProjects/proj-a"                 # level1 후보
mkdir -p "$FAKEHOME/IdeaProjects/org/proj-b"; git_init "$FAKEHOME/IdeaProjects/org/proj-b"         # level2 후보(org 는 git 아님)
mkdir -p "$FAKEHOME/IdeaProjects/org/deep/proj-too-deep"; git_init "$FAKEHOME/IdeaProjects/org/deep/proj-too-deep"  # level3 — 후보 아님
mkdir -p "$FAKEHOME/IdeaProjects/not-a-repo"                                                       # .git 없음 — 후보 아님
mkdir -p "$FAKEHOME/IdeaProjects/proj-reg"; git_init "$FAKEHOME/IdeaProjects/proj-reg"              # 등록될 예정
mkdir -p "$FAKEHOME/projects/proj-c"; git_init "$FAKEHOME/projects/proj-c"
cat > "$FAKEHOME/projects/proj-c/docker-compose.yml" <<'YML'
services:
  web:
    image: nginx
YML
# ~/dev · ~/workspace 는 만들지 않음 — scanned 목록에서 빠져야 함

# proj-reg 를 등록 — registered:true 로 보여야 함 (HOME 오버라이드된 채로 marina.sh 실행)
HOME="$FAKEHOME" MARINA_HOME="$MARINA_HOME" "$SCR/marina.sh" project add "$FAKEHOME/IdeaProjects/proj-reg" >/dev/null

cleanup(){ kill "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }; trap cleanup EXIT
HOME="$FAKEHOME" MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 MARINA_HOME="$MARINA_HOME" python3 "$CTRL" >/dev/null 2>&1 & SRV=$!
b="http://127.0.0.1:$PORT"; H=(-H "Origin: $b")
for i in $(seq 1 50); do curl -s -o /dev/null "$b/api/sessions" && break; sleep 0.1; done

out="$(curl -s "${H[@]}" "$b/api/repo-candidates")"
echo "$out" > "$TMP/candidates.json"

{ python3 - "$FAKEHOME" "$TMP/candidates.json" <<'PY'
import json, sys
fakehome, jpath = sys.argv[1], sys.argv[2]
d = json.load(open(jpath))
cands = {c["path"]: c for c in d["candidates"]}
scanned = d["scanned"]

# scanned — 존재하는 관례 루트만(~/IdeaProjects·~/projects), ~/dev·~/workspace 는 없어야 함
assert any(s.endswith("/IdeaProjects") for s in scanned), scanned
assert any(s.endswith("/projects") for s in scanned), scanned
assert not any(s.endswith("/dev") for s in scanned), scanned
assert not any(s.endswith("/workspace") for s in scanned), scanned

import os
def p(*parts): return os.path.realpath(os.path.join(fakehome, *parts))

# level1 후보
assert p("IdeaProjects", "proj-a") in cands, cands.keys()
assert cands[p("IdeaProjects", "proj-a")]["name"] == "proj-a"
assert cands[p("IdeaProjects", "proj-a")]["hasCompose"] is False
assert cands[p("IdeaProjects", "proj-a")]["registered"] is False

# level2 후보(org 자신은 git 아니라 후보 아님, org/proj-b 는 후보)
assert p("IdeaProjects", "org") not in cands, "org 자신은 .git 없어 후보 아니어야 함"
assert p("IdeaProjects", "org", "proj-b") in cands, cands.keys()

# level3 — 스캔 범위 밖(비용 가드)
assert p("IdeaProjects", "org", "deep", "proj-too-deep") not in cands, "3단계는 후보에 없어야 함"

# .git 없는 디렉토리 — 후보 아님
assert p("IdeaProjects", "not-a-repo") not in cands

# hasCompose 뱃지
assert cands[p("projects", "proj-c")]["hasCompose"] is True

# registered — 이미 등록된 프로젝트도 포함하되 registered:true(제외 아님)
assert cands[p("IdeaProjects", "proj-reg")]["registered"] is True

print("python assertions OK")
PY
} || { echo "FAIL: /api/repo-candidates 응답 검증 실패: $out"; exit 1; }

echo "PASS test-repo-candidates"
