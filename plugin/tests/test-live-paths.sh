#!/usr/bin/env bash
# live 경로 계산과 레지스트리 읽기 — 순수 함수라 도커 불필요.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../scripts"

python3 - "$SCRIPTS" <<'PY'
import sys, pathlib
sys.path.insert(0, sys.argv[1])
import marina_live as L

home = pathlib.Path(__import__("os").environ["MARINA_HOME"])

assert L.LIVE_SESSION == "live", L.LIVE_SESSION
assert L.LIVE_LABEL == "marina.live", L.LIVE_LABEL
assert L.PROJECT_LABEL == "marina.project", L.PROJECT_LABEL
assert L.live_root("ovation") == home / "ovation" / "live", L.live_root("ovation")
assert L.live_src("ovation") == home / "ovation" / "live" / "src"
assert L.live_data("ovation") == home / "ovation" / "live" / "data"
assert L.live_overlay_path("ovation") == home / "ovation" / "live" / "overlay.yml"

reg = {"projects": [
    {"id": "ovation", "root": "/x", "composeFile": "docker-compose.yml",
     "live": {"ref": "v1", "services": ["server"]}},
    {"id": "plain", "root": "/y", "composeFile": "docker-compose.yml"},
]}

cfg = L.live_config(reg, "ovation")
assert cfg["ref"] == "v1", cfg
assert cfg["services"] == ["server"], cfg
# composeFile 생략 시 프로젝트 기본값으로 채워진다
assert cfg["composeFile"] == "docker-compose.yml", cfg
assert cfg["root"] == "/x", cfg          # 체크아웃 원본 — 호출자가 레지스트리를 다시 안 읽게

assert L.live_config(reg, "plain") is None

# 없는 프로젝트는 에러 — 조용히 None 이면 오타가 "live 설정 없음" 으로 보인다
try:
    L.live_config(reg, "nope")
    raise AssertionError("없는 프로젝트인데 통과했다")
except L.LiveConfigError as e:
    assert "nope" in str(e), e

# ref 없는 live 블록은 에러
reg2 = {"projects": [{"id": "a", "root": "/a", "live": {"services": ["s"]}}]}
try:
    L.live_config(reg2, "a")
    raise AssertionError("ref 없는데 통과했다")
except L.LiveConfigError as e:
    assert "ref" in str(e), e

# 레지스트리 읽기/쓰기 — pin 이 쓰고 up 이 읽는 같은 파일
import json
p = home / "projects.json"
p.write_text(json.dumps(reg), encoding="utf-8")
assert L.load_registry()["projects"][0]["id"] == "ovation"
L.pin_ref("ovation", "v2")
assert L.live_config(L.load_registry(), "ovation")["ref"] == "v2"
# live 블록이 없던 프로젝트도 pin 으로 생긴다
L.pin_ref("plain", "main")
assert L.live_config(L.load_registry(), "plain")["ref"] == "main"
# 없는 프로젝트에 pin 은 거부
try:
    L.pin_ref("nope", "x")
    raise AssertionError("없는 프로젝트에 pin 이 통과했다")
except L.LiveConfigError as e:
    assert "nope" in str(e), e
print("ok")
PY
echo "PASS test-live-paths"
