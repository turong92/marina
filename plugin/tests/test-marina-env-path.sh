#!/usr/bin/env bash
# marina_env 는 데몬(launchd/systemd)의 최소 PATH 에 docker 등이 빠져있어도
# 흔한 설치 위치(/usr/local/bin·/opt/homebrew/bin·~/.local/bin)를 PATH 에 보강한다.
# → 대시보드 start/stop/remove 의 shell `command -v docker` 가 데몬에서도 동작.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; export MARINA_HOME="$TMP/home"

# 가짜 docker 를 흔한 위치 흉내 디렉토리에 두고, 최소 PATH 에서 marina_env 후 찾히는지
FAKEBIN="$TMP/.local/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\necho fake\n' > "$FAKEBIN/dockerish"; chmod +x "$FAKEBIN/dockerish"

PATH="/usr/bin:/bin" python3 - "$CTRL" "$TMP" <<'PY'
import importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mctl", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
root = Path(sys.argv[2]); root.mkdir(parents=True, exist_ok=True)
# HOME 을 TMP 로 둬서 ~/.local/bin = $TMP/.local/bin 보강 검증
os.environ["HOME"] = sys.argv[2]
os.environ["PATH"] = "/usr/bin:/bin"
env = m.marina_env(root)
parts = env["PATH"].split(os.pathsep)
assert str(Path(sys.argv[2]) / ".local/bin") in parts, ("~/.local/bin 보강 안 됨", env["PATH"])
# 실제 설치 위치도(있으면) 포함
for d in ("/usr/local/bin", "/opt/homebrew/bin"):
    if os.path.isdir(d):
        assert d in parts, (f"{d} 보강 안 됨", env["PATH"])
print("PASS env-path")
PY

# 서브레포별 java: Dockerfile FROM(JDK base image)이 SoT — 거기서 유도. x-marina.java 가 override.
# sdkman + java 2버전 있을 때만 실증(없으면 SKIP — CI 안전).
JV="$HOME/.sdkman/candidates/java"
if [[ -d "$JV" ]]; then
  V1="$(ls "$JV" | grep -vx current | sed -E 's/^([0-9]+).*/\1/' | sort -un | sed -n '1p')"
  V2="$(ls "$JV" | grep -vx current | sed -E 's/^([0-9]+).*/\1/' | sort -un | sed -n '2p')"
  if [[ -n "$V1" && -n "$V2" ]]; then
    PJ="$TMP/jproj"; mkdir -p "$PJ/be-api"
    # be-api Dockerfile: FROM eclipse-temurin:<V1> → 호스트 빌드 JAVA_HOME 도 java V1 이어야
    printf 'FROM eclipse-temurin:%s\n' "$V1" > "$PJ/be-api/Dockerfile.local"
    cat > "$PJ/docker-compose.yml" <<YML
services:
  batch:
    build: { context: ./be-api, dockerfile: Dockerfile.local }
x-marina: {}
YML
    bash "$HERE/../scripts/marina.sh" project add "$PJ" --compose "$PJ/docker-compose.yml" >/dev/null
    python3 - "$HERE/../scripts/marina_cli.py" "$PJ" "$V1" "$V2" <<'PY'
import importlib.util, os, sys
sys.path.insert(0, os.path.dirname(sys.argv[1]))
spec = importlib.util.spec_from_file_location("mcli", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
from pathlib import Path
root, v1, v2 = Path(sys.argv[2]), sys.argv[3], sys.argv[4]
# 1) Dockerfile FROM eclipse-temurin:v1 → be-api = java v1 (SoT=Dockerfile)
jh = m._subrepo_java_homes(root)
assert jh.get("be-api") and (("/"+v1+".") in jh["be-api"] or jh["be-api"].rstrip("/").split("/")[-1].startswith(v1)), ("Dockerfile FROM 유도 실패", jh, v1)
# 2) x-marina.java override(be-api=v2) 가 Dockerfile(v1) 이김
comp = os.path.join(os.environ["MARINA_HOME"], "jproj", "docker-compose.yml")
s = open(comp).read().replace("x-marina: {}", 'x-marina:\n  java:\n    be-api: "%s"' % v2)
open(comp, "w").write(s)
m._JAVA_HOMES_CACHE.clear()
jh2 = m._subrepo_java_homes(root)
assert jh2.get("be-api") and jh2["be-api"].rstrip("/").split("/")[-1].startswith(v2), ("x-marina.java override 실패", jh2, v2)
print(f"PASS per-subrepo-java (Dockerfile={v1} → override={v2})")
PY
  else
    echo "SKIP per-subrepo-java (java 2버전 미만)"
  fi
else
  echo "SKIP per-subrepo-java (sdkman 없음)"
fi
echo "PASS test-marina-env-path"
