#!/usr/bin/env bash
# live overlay — 덮는 것만 덮고 추측으로 벗기지 않는다 (도커 불필요).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CP="$HERE/../scripts/marina-compose.py"

python3 - "$CP" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)

# `docker compose config --format json` 이 주는 형태(ports 는 dict 목록)
config = {"services": {
    "web": {
        "build": {"context": "."},
        "ports": [{"target": 3000, "published": "3000", "protocol": "tcp"}],
        "volumes": ["./src:/app/src", "./data/uploads:/uploads", "named-vol:/var/lib/x"],
        "develop": {"watch": [{"path": "./src", "action": "sync", "target": "/app/src"}]},
    },
    "db": {"image": "postgres:18",
           "ports": [{"target": 5432, "published": "5432", "protocol": "tcp"}]},
}}

dev = mc.build_overlay(config)
live = mc.build_overlay(config, live=True,
                        extra_labels={"marina.live": "1", "marina.project": "p"})

# 1) 개발 overlay 는 포트를 자동 할당으로 덮는다 (현행 동작 — 회귀 방지)
assert "127.0.0.1::3000" in dev, dev

# 2) live overlay 는 포트를 덮지 않는다 — L2 의 Funnel·터널이 가리킬 수 있어야 한다
assert "127.0.0.1::3000" not in live, live
assert "127.0.0.1::5432" not in live, live
assert "ports:" not in live, live

# 3) restart 를 덮는다 — 서비스마다 한 번
assert live.count("restart: unless-stopped") == 2, live

# 4) develop(watch) 을 제거한다. 원본 config 는 변경되지 않는다
assert "develop: !reset null" in live, live
assert "watch" not in live, live
assert config["services"]["web"].get("develop"), "원본 config 가 변경됐다"

# 5) 라벨이 붙는다 (컨테이너 + build 서비스 이미지 + 네트워크)
assert "marina.live" in live and "marina.project" in live, live

# 6) 소스로 보이는 바인드를 **벗기지 않는다** — marina 는 소스와 데이터를 구분할 수 없고,
#    추측해서 벗기면 데이터를 날린다. 경고만 한다.
assert "/app/src" not in live, "live overlay 가 바인드 마운트를 건드렸다"
assert "/uploads" not in live, live

# 7) 경고 대상을 찾아낸다 — 프로젝트 디렉토리 안을 가리키는 바인드만
binds = mc.project_dir_binds(config, "/proj")
assert "./src:/app/src" in binds, binds
assert "./data/uploads:/uploads" in binds, binds
assert not any("named-vol" in b for b in binds), binds

# 8) long syntax 바인드도 잡는다. named volume·tmpfs 는 아니다
cfg2 = {"services": {"a": {"volumes": [
    {"type": "bind", "source": "/proj/conf", "target": "/etc/conf"},
    {"type": "volume", "source": "data", "target": "/var/lib/x"},
    {"type": "tmpfs", "target": "/tmp/x"},
    {"type": "bind", "source": "/elsewhere/conf", "target": "/etc/other"},
]}}}
b2 = mc.project_dir_binds(cfg2, "/proj")
assert b2 == ["/proj/conf:/etc/conf"], b2

# 9) live=False 가 기본값이다 — 기존 호출자가 영향받지 않는다
assert mc.build_overlay(config) == dev

# 9b) build_context_base 는 **build 가 선언된 서비스에만** 붙는다 — image-only 서비스에
#     build: 가 생기면 compose 가 빌드를 시도한다(비침투성 원칙 위반).
livectx = mc.build_overlay(config, live=True, build_context_base="/src",
                           extra_labels={"marina.live": "1"})
assert "context: \"/src\"" in livectx, livectx
# db 는 image-only 다 — 그 블록에 build 가 없어야 한다
import re as _re
def _block(text, svc):
    """overlay 의 한 서비스 블록. 다음 서비스 헤더(들여쓰기 2칸 + 이름 + ':')까지."""
    i = text.index(f"  {svc}:")
    m = _re.search(r"\n  [A-Za-z0-9]", text[i + len(svc) + 3:])
    return text[i:i + len(svc) + 3 + (m.start() if m else len(text))]
db_block, web_block = _block(livectx, "db"), _block(livectx, "web")
assert "image" not in db_block and "build" not in db_block, db_block
assert "restart: unless-stopped" in db_block, db_block     # 블록을 제대로 잘랐는지
assert "build" in web_block and "/src" in web_block, web_block
# 절대경로로 선언된 context 는 그대로 둔다
abscfg = {"services": {"x": {"build": {"context": "/already/abs"}}}}
assert '"/already/abs"' in mc.build_overlay(abscfg, live=True, build_context_base="/src"), \
    mc.build_overlay(abscfg, live=True, build_context_base="/src")

# 10) 바인드가 **어디로 풀리는지** 구분한다. live 는 --project-directory 를
#     ~/.marina/<id>/live 로 주므로 './src' 는 체크아웃(live/src) 자신을 가리키고
#     './data/x' 는 live/data/x 를 가리킨다. 전자는 다음 기동의 하드 리셋에 날아가지만
#     후자는 안전하다 — 둘을 같은 문구로 경고하면 사용자가 경고를 무시하게 된다.
import sys as _sys
_sys.path.insert(0, ".")
import marina_live as L
rows = L.classify_binds(["./src:/app/src", "./data/uploads:/uploads", "../outside:/x"], "p")
by = {r["bind"]: r for r in rows}
assert by["./src:/app/src"]["in_checkout"] is True, rows
assert by["./data/uploads:/uploads"]["in_checkout"] is False, rows
assert str(L.live_data("p")) in by["./data/uploads:/uploads"]["resolved"], rows
# 바깥을 가리키는 것은 체크아웃도 데이터도 아니다 — 그것도 알려준다
assert by["../outside:/x"]["in_checkout"] is False, rows
assert by["../outside:/x"]["in_data"] is False, rows
assert by["../outside:/x"]["in_live"] is False, rows

# 10b) live/ 안이지만 live/data 밖인 바인드는 "live 디렉터리 밖" 이 **아니다**.
#      `--project-directory` 가 live/ 라 `./mysql` 은 live/mysql 로 간다 — 예전엔 이것도
#      "밖" 이라고 거짓으로 경고했다(리뷰 지적 I6 의 세 번째 증상).
rows2 = L.classify_binds(["./mysql:/var/lib/mysql"], "p")
assert rows2[0]["in_live"] is True, rows2
assert rows2[0]["in_data"] is False, rows2
assert str(L.live_root("p")) in rows2[0]["resolved"], rows2
print("ok")
PY
echo "PASS test-live-overlay"
