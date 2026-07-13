#!/usr/bin/env bash
# A2 — env 누락 '시작 전' 감지. ${VAR} 추출 규칙(기본값 제외·:? 포함·중복 dedup) + .env 파싱 + 설정됨 판정
# 우선순위(env>워크트리.env>프로젝트.env>marina 주입) + 실서버 payload 노출 + 프론트 경고줄 배선.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"

# ── 1) ${VAR} 추출 규칙(docker 불요) ──────────────────────────────────────
python3 - "$CTRL" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)

# 기본값 없음 → required
assert mc._required_env_vars("${FOO}") == ["FOO"]
assert mc._required_env_vars("${FOO:?missing}") == ["FOO"]
assert mc._required_env_vars("${FOO?}") == ["FOO"]
# 기본값 있음 → 제외
assert mc._required_env_vars("${FOO:-bar}") == []
assert mc._required_env_vars("${FOO-bar}") == []
# 순서 보존 dedup
assert mc._required_env_vars("a: ${B}\nb: ${A}\nc: ${B}") == ["B", "A"]
# 리터럴 이스케이프 $${FOO} 는 인터폴레이션이 아님 → 제외
assert mc._required_env_vars("cmd: echo $${FOO}") == []
# 혼합
text = "environment:\n  - A=${A}\n  - B=${B:-def}\n  - C=${C:?required}\n  - D=${D-def2}\n"
assert mc._required_env_vars(text) == ["A", "C"], mc._required_env_vars(text)
print("ok _required_env_vars")

# ── .env 파싱 ──────────────────────────────────────
import tempfile, pathlib
with tempfile.TemporaryDirectory() as td:
    p = pathlib.Path(td) / ".env"
    p.write_text(
        "# comment\n"
        "\n"
        "FOO=bar\n"
        'BAZ="quoted value"\n'
        "export QUX=1\n"
        "not-a-line-without-equals\n"
        "  SPACED = 1\n"
    )
    got = mc._env_file_vars(p)
    assert got == {"FOO", "BAZ", "QUX", "SPACED"}, got
    assert mc._env_file_vars(pathlib.Path(td) / "nope.env") == set()   # 파일 없음 → 빈 집합(예외 안 남)
print("ok _env_file_vars")
PY
echo "PASS test-missing-env (extraction+parsing)"

# ── 2) missing_env_vars: 설정됨 판정 우선순위 ──────────────────────────────
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
PROOT="$TMP/proj-root"; WTROOT="$TMP/proj-wt"
mkdir -p "$MARINA_HOME/p1" "$PROOT" "$WTROOT"
cat > "$MARINA_HOME/p1/docker-compose.yml" <<'YML'
services:
  web:
    image: nginx
    environment:
      - PROC_VAR=${PROC_VAR}
      - WT_ENV_VAR=${WT_ENV_VAR}
      - PROJ_ENV_VAR=${PROJ_ENV_VAR}
      - BUILDARG_VAR=${BUILDARG_VAR}
      - PROFILE_VAR=${PROFILE_VAR}
      - HAS_DEFAULT=${HAS_DEFAULT:-ok}
      - TRULY_MISSING=${TRULY_MISSING}
YML
cat > "$MARINA_HOME/p1/build-args.json" <<'JSON'
{"web": {"BUILDARG_VAR": "1"}}
JSON
printf 'WT_ENV_VAR=1\n' > "$WTROOT/.env"
printf 'PROJ_ENV_VAR=1\n' > "$PROOT/.env"

python3 - "$CTRL" "$WTROOT" "$PROOT" <<'PY'
import importlib.util, sys, os, pathlib
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
wtroot, proot = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])

os.environ["PROC_VAR"] = "1"
project = {"id": "p1", "root": proot, "composeEnvVar": "PROFILE_VAR"}
missing = {e["name"]: e for e in mc.missing_env_vars(wtroot, project)}
assert set(missing) == {"TRULY_MISSING"}, missing            # 나머지는 전부 각 경로로 '설정됨' 처리
assert wtroot.name in missing["TRULY_MISSING"]["hint"] or ".env" in missing["TRULY_MISSING"]["hint"], missing
print("ok missing_env_vars priority")

# 캐시 — 같은 mtime 이면 반복 호출도 동일 결과(재파싱 여부는 결과로 간접 확인)
again = {e["name"] for e in mc.missing_env_vars(wtroot, project)}
assert again == {"TRULY_MISSING"}
# .env 추가 후(mtime 변경) 즉시 반영 — 캐시가 stale 값을 고집하지 않음
with open(wtroot / ".env", "a") as f:
    f.write("TRULY_MISSING=1\n")
after = {e["name"] for e in mc.missing_env_vars(wtroot, project)}
assert after == set(), after
print("ok missing_env_vars cache invalidation")

# compose 없음/project 정보 부족 → 예외 없이 빈 목록
assert mc.missing_env_vars(wtroot, {"id": "no-such-project", "root": proot}) == []
PY
echo "PASS test-missing-env (priority+cache)"

# ── 3) 실서버 — /api/sessions payload 에 missingEnv 노출 ──────────────────
TMP2="$(mktemp -d)"; export MARINA_HOME="$TMP2/home"
export MARINA_GATEWAY=off
P="$TMP2/proj-$$"; mkdir -p "$P"; P="$(cd "$P" && pwd -P)"
mkdir -p "$MARINA_HOME/srv1"
cat > "$MARINA_HOME/srv1/docker-compose.yml" <<'YML'
services:
  web:
    image: nginx
    environment:
      - API_KEY=${API_KEY}
YML
mkdir -p "$MARINA_HOME"
python3 - "$MARINA_HOME/projects.json" "$P" <<'PY'
import json, sys
path, root = sys.argv[1], sys.argv[2]
json.dump({"projects": [{"id": "srv1", "root": root, "kind": "compose", "composeFile": "docker-compose.yml"}]}, open(path, "w"))
PY
PORT=39714
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 MARINA_HOME="$MARINA_HOME" python3 "$CTRL" >/dev/null 2>&1 &
SRV=$!
cleanup(){ kill "$SRV" 2>/dev/null || true; rm -rf "$TMP2"; }
trap cleanup EXIT
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/api/sessions" >/dev/null 2>&1 && break; sleep 0.1; done
printf '%s' "$(curl -sf "http://127.0.0.1:$PORT/api/sessions")" | python3 -c '
import json, sys
d = json.load(sys.stdin)
s = next((x for x in d["sessions"] if x.get("kind") == "compose" and x.get("missingEnv")), None)
assert s, [x.get("missingEnv") for x in d["sessions"]]
names = {e["name"] for e in s["missingEnv"]}
assert names == {"API_KEY"}, names
assert s["missingEnv"][0]["hint"], "hint 비어있음"
print("ok /api/sessions missingEnv", names)
'
# .env 추가 후 사라짐 확인(실사용 흐름 — 유저가 .env 채우면 경고 소멸)
printf 'API_KEY=x\n' > "$P/.env"
printf '%s' "$(curl -sf "http://127.0.0.1:$PORT/api/sessions")" | python3 -c '
import json, sys
d = json.load(sys.stdin)
s = next(x for x in d["sessions"] if x.get("kind") == "compose")
assert not s.get("missingEnv"), s.get("missingEnv")
print("ok missingEnv cleared after .env")
'
kill "$SRV" 2>/dev/null || true
trap - EXIT
rm -rf "$TMP2"
echo "PASS test-missing-env (real server payload)"

# ── 4) 프론트 — 경고줄·팝오버 배선 존재 ─────────────────────────────────
J5B="$HERE/../scripts/marina-web/app-5b-actions.js"
CSS="$HERE/../scripts/marina-web/styles.css"
grep -q "function envWhyLine" "$J5B" || { echo "FAIL: envWhyLine 없음"; exit 1; }
grep -q "session.missingEnv" "$J5B" || { echo "FAIL: missingEnv 미소비"; exit 1; }
grep -q "data-why-env" "$J5B" || { echo "FAIL: data-why-env 배선 없음"; exit 1; }
grep -q "function openEnvHintPopover" "$J5B" || { echo "FAIL: openEnvHintPopover 없음"; exit 1; }
grep -q "\.svc-why\.warn" "$CSS" || { echo "FAIL: 경고줄(.svc-why.warn) 스타일 없음"; exit 1; }
if command -v node >/dev/null 2>&1; then
  for f in "$HERE/../scripts/marina-web/"app-*.js; do
    node --check "$f" || { echo "FAIL: 문법 오류 $f"; exit 1; }
  done
fi
echo "PASS test-missing-env (frontend wiring)"

echo "PASS test-missing-env"
