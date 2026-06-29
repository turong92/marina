#!/usr/bin/env bash
# 충돌 안전 id: 폴더명(basename)만 같은 별개 프로젝트 2개를 등록하면 두 번째 id 에 -<해시> 가 붙어 분리된다.
# 안 그러면 -p <id>-main 과 ~/.marina/<id> 가 겹쳐 docker 컨테이너·보관 compose 가 서로 덮어쓴다. docker 불요.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SH="$HERE/../scripts/marina.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME"

# 같은 basename 'app' 의 서로 다른 두 프로젝트(다른 부모 경로)
mkdir -p "$TMP/a/app" "$TMP/b/app"
A="$TMP/a/app"; B="$TMP/b/app"
printf 'services:\n  web:\n    image: nginx\n' > "$A/docker-compose.yml"
printf 'services:\n  web:\n    image: nginx\n' > "$B/docker-compose.yml"
bash "$SH" project add "$A" --compose "$A/docker-compose.yml" >/dev/null
bash "$SH" project add "$B" --compose "$B/docker-compose.yml" >/dev/null

python3 - "$MARINA_HOME" "$A" "$B" <<'PY' || { echo "FAIL: collision-safe id"; exit 1; }
import json, os, sys
home, A, B = sys.argv[1], os.path.realpath(sys.argv[2]), os.path.realpath(sys.argv[3])
d = json.load(open(os.path.join(home, "projects.json"), encoding="utf-8"))
norm = lambda p: os.path.realpath(os.path.expanduser(p))
by = {norm(p["root"]): p for p in d["projects"]}
ia, ib = by[A]["id"], by[B]["id"]
assert ia != ib, f"두 id 가 같음(충돌): {ia} {ib}"          # 핵심: 분리됐는가
assert "app" in (ia, ib), (ia, ib)                          # 선착순 하나는 basename 그대로(백워드 호환)
assert ia.startswith("app") and ib.startswith("app"), (ia, ib)
# 보관 compose 가 각자 id 디렉터리에 따로 저장됐는가(덮어쓰기 없음)
assert os.path.exists(os.path.join(home, ia, "docker-compose.yml")), f"missing stored: {ia}"
assert os.path.exists(os.path.join(home, ib, "docker-compose.yml")), f"missing stored: {ib}"
# 같은 root 재등록은 id 유지(해시 중복 부여 안 함)
print("ok collision-safe ids:", ia, "|", ib)
PY

# 같은 root(A) 재등록 → id 그대로(증식 안 함)
bash "$SH" project add "$A" --compose "$A/docker-compose.yml" >/dev/null
python3 - "$MARINA_HOME" "$A" <<'PY' || { echo "FAIL: re-add changed id"; exit 1; }
import json, os, sys
home, A = sys.argv[1], os.path.realpath(sys.argv[2])
d = json.load(open(os.path.join(home, "projects.json"), encoding="utf-8"))
norm = lambda p: os.path.realpath(os.path.expanduser(p))
rows = [p for p in d["projects"] if norm(p["root"]) == A]
assert len(rows) == 1 and rows[0]["id"] == "app", rows     # 재등록해도 'app' 유지, 중복 항목 없음
PY
echo "PASS test-compose-collision-id"
