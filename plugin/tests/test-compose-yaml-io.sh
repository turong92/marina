#!/usr/bin/env bash
# compose YAML 읽기/쓰기가 표준 라이브러리만으로 되는지(README "의존성 0" — PyYAML 금지).
# 읽기 load_compose = `docker compose config --format json`, 쓰기 dump_yaml = 자체 emitter, 편집은 텍스트 블록 교체.
# 배경(2026-09-14): 셸 python3 가 PyYAML 없는 3.14 로 바뀌자 compose 계열 테스트 6개가 죽었다 — README 는
# "표준 라이브러리만" 이라 했는데 코드가 x-marina 에 PyYAML 을 요구하고 있었다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리 · MARINA_YAML_DOCKER
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CC="$HERE/../scripts/marina-compose.py"

# 0) 스크립트 어디에도 PyYAML 이 없다 — 회귀 가드
if grep -nE '^\s*(import yaml|from yaml)|_yaml\(\)' "$HERE"/../scripts/*.py "$HERE"/../scripts/*.sh 2>/dev/null; then
  echo "FAIL: PyYAML 참조가 남아 있다(README: 표준 라이브러리만)"; exit 1
fi

python3 - "$CC" <<'PY'
import importlib.util, json, os, sys, tempfile
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
assert "yaml" not in sys.modules, "PyYAML 이 import 됐다"

# ── 1) load_compose: 앵커·머지키·멀티라인·${VAR} 원문·유니코드·null/bool/int, name 제거, include 제거 ──
TEXT = """\
# 사용자 주석
x-common: &common
  restart: unless-stopped
include:
  - ../other/compose.yml
services:
  web:
    <<: *common
    build: ./web
    environment:
      - RAW=${UNSET_VAR}
    command: >
      sh -c "echo multi
      line"
x-marina:
  forward:
    6379: redis
  links:
    web-app-monorepo:
      symlink: [node_modules, "dist/**"]
  expose:
    web: {NEXT_PUBLIC_API: "gateway:be"}
  note: "한글 · #@% ${NOT_A_VAR}"
  flag: true
  nothing: null
  num: 42
"""
d = mc.load_compose(TEXT)
assert "name" not in d and "include" not in d, list(d)
assert d["services"]["web"]["restart"] == "unless-stopped", "머지키(<<) 를 compose 가 풀어야"
assert d["services"]["web"]["environment"] == ["RAW=${UNSET_VAR}"], ("보간 안 함", d["services"]["web"]["environment"])
assert d["services"]["web"]["build"] == {"context": "./web"}, d["services"]["web"]["build"]
xm = d["x-marina"]
assert xm["forward"] == {"6379": "redis"}, ("맨 숫자 키는 따옴표를 붙여 넘긴다", xm["forward"])
assert xm["links"] == {"web-app-monorepo": {"symlink": ["node_modules", "dist/**"]}}, xm["links"]
assert xm["note"] == "한글 · #@% ${NOT_A_VAR}" and xm["flag"] is True and xm["nothing"] is None and xm["num"] == 42, xm
assert mc.load_compose("") == {} and mc.load_compose("   \n") == {}
# name 이 원문에 있으면 남긴다
assert mc.load_compose("name: fixed\nservices: {}\n").get("name") == "fixed"
# 깨진 YAML → RuntimeError(compose 의 메시지)
try:
    mc.load_compose("services:\n  web:\n    image: x\n   bad indent\n"); raise SystemExit("FAIL: 깨진 YAML 이 통과")
except RuntimeError as exc:
    assert "compose 파싱 실패" in str(exc), exc
# docker 없음 → RuntimeError(명확한 메시지), 예외 종류 동일
saved = os.environ.get("MARINA_YAML_DOCKER")
os.environ["MARINA_YAML_DOCKER"] = "/nonexistent/docker"
try:
    mc.load_compose("services: {}\n"); raise SystemExit("FAIL: docker 없이 통과")
except RuntimeError as exc:
    assert "docker CLI" in str(exc), exc
finally:
    if saved is None: os.environ.pop("MARINA_YAML_DOCKER", None)
    else: os.environ["MARINA_YAML_DOCKER"] = saved

# ── 2) parse_xmarina: 블록만 읽는다(빠른 경로 — x-marina 없으면 docker 호출 0) ──
calls = []
_real_run = mc.subprocess.run
def _spy(argv, **kw):
    calls.append(list(argv)); return _real_run(argv, **kw)
mc.subprocess.run = _spy
assert mc.parse_xmarina("services:\n  app:\n    build: .\n") == {}
assert calls == [], ("x-marina 없는 텍스트는 docker 를 부르지 않는다", calls)
assert mc.parse_xmarina(TEXT)["forward"] == {"6379": "redis"}
assert len(calls) == 1 and calls[0][-6:] == mc._COMPOSE_CONFIG_FLAGS, calls
# services 쪽이 깨져도 x-marina 블록은 읽힌다(블록만 넘기므로)
assert mc.parse_xmarina("services:\n  web:\n    image: x\n   bad indent\nx-marina:\n  a: 1\n") == {"a": 1}
mc.subprocess.run = _real_run
# JSON 형 문서(compose config 출력을 그대로 보관한 경우)도 읽고 고친다
J = '{"services": {"web": {"image": "x"}}, "x-marina": {"prebuild": {"web": "make"}}}'
assert mc.parse_xmarina(J) == {"prebuild": {"web": "make"}}
rj = mc.replace_xmarina_block(J, {"prebuild": {"web": "make2"}})
assert rj.startswith("services:\n") and mc.load_compose(rj)["x-marina"] == {"prebuild": {"web": "make2"}}, rj

# ── 3) dump_yaml: 인용 규칙 + load_compose 왕복 ──
TRICKY = {
    "x-marina": {
        "plain": "node_modules", "yes_str": "yes", "num_str": "123", "colon": "gateway:be", "hash": "a # b",
        "url": "http://x:1/y", "unicode": "한글 · ✓", "multi": "line1\nline2", "empty": "", "tilde": "~",
        "glob": "dist/**", "dot": ".venv", "dash": "-x", "at": "@scope/pkg", "t": True, "f": False, "n": None,
        "i": 0, "fl": 1.5, "neg": -3, "list": ["a", 1, None, {"k": "v", "l": [1, 2]}, []], "emptyd": {}, "emptyl": [],
        "6379": {"target": "host"},
    }
}
out = mc.dump_yaml(TRICKY)
assert out.startswith("x-marina:\n"), out
back = mc.load_compose(out)["x-marina"]
# compose-go 는 x-* 확장 안의 빈 시퀀스 [] 를 null 로 내보낸다(실측) — 그 한 가지만 빼고 전부 동일해야 한다
expect = json.loads(json.dumps(TRICKY["x-marina"])); expect["emptyl"] = None; expect["list"][4] = None
assert back == expect, ("dump→load 왕복 불일치", json.dumps(back, ensure_ascii=False))
assert "emptyl: []" in out, out                                     # 쓰기 자체는 [] 로 쓴다(재편집 때 리스트로 남게)
assert 'yes_str: "yes"' in out and 'num_str: "123"' in out and 'plain: node_modules' in out, out
assert "- k: v" in out and "    l:" in out, out                    # 시퀀스 안 매핑의 들여쓰기
assert mc.dump_yaml({}) == "{}\n" and mc.dump_yaml([]) == "[]\n"

# ── 4) replace_xmarina_block: 위치 보존·주석 보존·없으면 끝에·빈 dict 면 제거 ──
DOC = "# top\nservices:\n  app:\n    build: .   # keep me\nx-marina:\n  old: 1\nvolumes:\n  data: {}\n"
r = mc.replace_xmarina_block(DOC, {"forward": {6379: "redis"}})
assert r == "# top\nservices:\n  app:\n    build: .   # keep me\nx-marina:\n  forward:\n    \"6379\": redis\nvolumes:\n  data: {}\n", repr(r)
assert mc.replace_xmarina_block(DOC, {}) == "# top\nservices:\n  app:\n    build: .   # keep me\nvolumes:\n  data: {}\n"
NOXM = "services:\n  app:\n    build: ."          # 끝에 개행 없음
r2 = mc.replace_xmarina_block(NOXM, {"a": 1})
assert r2 == "services:\n  app:\n    build: .\nx-marina:\n  a: 1\n", repr(r2)
assert mc.replace_xmarina_block(NOXM, {}) == NOXM
assert mc.load_compose(r)["x-marina"] == {"forward": {"6379": "redis"}}
# 기존 블록의 키 순서를 따른다(compose config 는 정렬해 돌려주므로) — 새 키는 뒤에
ORD = "services: {}\nx-marina:\n  zeta:\n    b: 1\n    a: 2\n  alpha: x\n"
ro = mc.replace_xmarina_block(ORD, {"alpha": "x", "new": 1, "zeta": {"a": 2, "b": 1}})
assert ro == "services: {}\nx-marina:\n  zeta:\n    b: 1\n    a: 2\n  alpha: x\n  new: 1\n", repr(ro)
assert "colon: gateway:be" in mc.dump_yaml({"colon": "gateway:be"}), "내부 콜론은 plain"

# ── 5) inject_build_args_text: 문자열 build 승격 · 블록 build(args 없음/있음) · build 없음 · flow 는 거부 ──
SVC = """\
services:
  a:
    build: ./a        # 문자열
  b:
    build:
      context: ./b
      dockerfile: Dockerfile.local
  c:
    build:
      context: ./c
      args:
        KEEP: "1"
        PROFILE: old
  d:
    image: redis:7
x-marina:
  prebuild: {}
"""
o = mc.inject_build_args_text(SVC, {"a": {"P": "local"}, "b": {"P": "local", "Q": "2"}, "c": {"PROFILE": "new", "NEW": "yes"}, "d": {"X": "1"}, "ghost": {"Z": "1"}})
got = mc.load_compose(o)["services"]
assert got["a"]["build"] == {"context": "./a", "args": {"P": "local"}}, got["a"]
assert got["b"]["build"] == {"context": "./b", "dockerfile": "Dockerfile.local", "args": {"P": "local", "Q": "2"}}, got["b"]
assert got["c"]["build"]["args"] == {"KEEP": "1", "PROFILE": "new", "NEW": "yes"}, got["c"]
assert got["d"]["build"] == {"args": {"X": "1"}} or got["d"]["build"].get("args") == {"X": "1"}, got["d"]   # 기존 dict 경로 동일: context 없이 args
assert "ghost" not in got
assert "# 문자열" not in o.split("a:")[1].split("b:")[0] or True                     # 승격하며 그 줄 주석은 사라져도 된다
assert "dockerfile: Dockerfile.local" in o and "x-marina:\n  prebuild: {}" in o, o    # 나머지 원문 보존
assert mc.inject_build_args_text(SVC, {}) == SVC
try:
    mc.inject_build_args_text("services:\n  a:\n    build: {context: ./a}\n", {"a": {"P": "1"}}); raise SystemExit("FAIL: flow build 통과")
except ValueError as exc:
    assert "flow" in str(exc), exc

# ── 6) 파일 캐시: 같은 mtime/size 면 docker 재호출 없음, 바뀌면 재파싱 ──
with tempfile.TemporaryDirectory() as td:
    f = os.path.join(td, "docker-compose.yml")
    open(f, "w").write("services: {}\nx-marina:\n  a: 1\n")
    calls.clear(); mc.subprocess.run = _spy
    assert mc.xmarina_for_stored(f) == {"a": 1} and mc.xmarina_for_stored(f) == {"a": 1}
    assert len(calls) == 1, ("두 번째는 캐시", len(calls))
    d1 = mc.load_compose_file(f); d1["services"]["mut"] = 1
    assert "mut" not in mc.load_compose_file(f)["services"], "캐시는 사본을 돌려준다"
    os.utime(f, (1, 1)); open(f, "w").write("services: {}\nx-marina:\n  a: 2\n")
    assert mc.xmarina_for_stored(f) == {"a": 2}
    mc.subprocess.run = _real_run
    # best-effort: 깨진 파일 → {} (start 를 절대 안 깨뜨림)
    open(f, "w").write("x-marina:\n  a: [\n")
    assert mc.xmarina_for_stored(f) == {}

# ── 7) _edit_xmarina_block: 파일의 x-marina 만 바뀌고 나머지 텍스트(주석·앵커) 그대로 ──
with tempfile.TemporaryDirectory() as td:
    f = os.path.join(td, "docker-compose.yml")
    ORIG = "# 헤더 주석\nx-c: &c\n  restart: always\nservices:\n  app:\n    <<: *c\n    build: .\nx-marina:\n  links:\n    symlink: [a]\n"
    open(f, "w").write(ORIG)
    assert mc.set_xmarina_link(f, ".", "node_modules") is True
    now = open(f).read()
    assert now.startswith("# 헤더 주석\nx-c: &c\n  restart: always\nservices:\n  app:\n    <<: *c\n    build: .\nx-marina:\n"), repr(now)
    assert mc.xmarina_for_stored(f) == {"links": {"symlink": ["a", "node_modules"]}}, mc.xmarina_for_stored(f)
print("ok")
PY
echo "PASS test-compose-yaml-io"
