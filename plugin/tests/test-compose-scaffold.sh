#!/usr/bin/env bash
# _detect_subrepos + _compose_scaffold_service: LLM 없이 서브레포를 감지하고 compose 서비스 블록을 스캐폴드한다.
# (서브레포→서비스 만들기가 LLM 없이도 되게 하는 무-LLM 경로). docker 불요.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CTRL="$HERE/../scripts/marina-control.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
T="$TMP/proj"; mkdir -p "$T"
mkdir -p "$T/ai-api"; : > "$T/ai-api/Dockerfile"                      # 루트 Dockerfile
mkdir -p "$T/web/apps/web" "$T/web/.git"; : > "$T/web/apps/web/Dockerfile"   # .git 클론(감지) + 중첩 Dockerfile(스캐폴드)
mkdir -p "$T/legacy"; printf 'services: {}\n' > "$T/legacy/docker-compose.yml"  # compose 있음, Dockerfile 없음
mkdir -p "$T/api"; printf 'FROM python:3-alpine\nEXPOSE 8081\n' > "$T/api/Dockerfile"   # 루트 Dockerfile + EXPOSE
mkdir -p "$T/multi/x" "$T/multi/y"; : > "$T/multi/x/Dockerfile"; : > "$T/multi/y/Dockerfile"  # 여러 Dockerfile(애매)
mkdir -p "$T/node_modules/x"; : > "$T/node_modules/x/Dockerfile"     # 무시돼야
mkdir -p "$T/caps"; : > "$T/caps/DockerFile"; : > "$T/caps/DockerFile_Backup_250908"  # 대문자 F(잡아야) + 백업(제외)
mkdir -p "$T/withcompose/x"; printf 'services:\n  a:\n    build: ./x\n' > "$T/withcompose/docker-compose.yml"; : > "$T/withcompose/x/Dockerfile"  # 자체 compose

python3 - "$CTRL" "$T" <<'PY' || { echo "FAIL: scaffold/detect"; exit 1; }
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
T = Path(sys.argv[2])

subs = mc._detect_subrepos(T)
assert subs == ["ai-api", "api", "caps", "legacy", "web", "withcompose"], subs  # node_modules 제외, multi 는 루트신호 없어 미감지, caps=대문자 Dockerfile·withcompose=자체 compose 감지

# 루트 Dockerfile → build: ./sub. command 템플릿·포트추측 없음. 빈 Dockerfile=EXPOSE 없음 → expose 줄 없음
a = mc._compose_scaffold_service(T, "ai-api")
assert "  ai-api:" in a and "build: ./ai-api" in a, a
assert "command:" not in a and "expose:" not in a, a

# 루트 Dockerfile 없음 → build: ./web (중첩 Dockerfile 추측 안 함)
w = mc._compose_scaffold_service(T, "web")
assert "build: ./web" in w and "context:" not in w, w

# Dockerfile 없음 → build: ./legacy (군더더기 주석 없음)
l = mc._compose_scaffold_service(T, "legacy")
assert "build: ./legacy" in l, l

# 루트 Dockerfile EXPOSE → expose 로(DNS). 하드코딩 3000·command 없음
api = mc._compose_scaffold_service(T, "api")
assert "build: ./api" in api and 'expose: ["8081"]' in api, api
assert "3000" not in api and "command:" not in api, api

# 여러 Dockerfile = 애매 → 인자 없으면 추측 안 함(build: ./multi)
multi = mc._compose_scaffold_service(T, "multi")
assert "build: ./multi" in multi and "context:" not in multi, multi
# 중첩 Dockerfile = 자체 서브레포 → 각 디렉터리가 서비스(이름·컨텍스트), Dockerfile 한 개당 서비스 한 개
mx = mc._compose_scaffold_service(T, "multi", dockerfile="x/Dockerfile")
assert "  x:" in mx and "build: ./multi/x" in mx, mx
my = mc._compose_scaffold_service(T, "multi", dockerfile="y/Dockerfile")
assert "  y:" in my and "build: ./multi/y" in my, my
# 깊은 중첩 → 마지막 디렉터리명이 서비스명, 컨텍스트=그 디렉터리
wb = mc._compose_scaffold_service(T, "web", dockerfile="apps/web/Dockerfile")
assert "  web:" in wb and "build: ./web/apps/web" in wb, wb
# build_context(외부 마운트) + 중첩 → 컨텍스트=마운트/서브경로
exm = mc._compose_scaffold_service(T, "multi", dockerfile="x/Dockerfile", build_context="./.workspace/external/multi")
assert "  x:" in exm and "build: ./.workspace/external/multi/x" in exm, exm
# build_context 주면 그걸로(외부 마운트, 루트 Dockerfile)
ext = mc._compose_scaffold_service(T, "api", build_context="./.workspace/external/api")
assert "build: ./.workspace/external/api" in ext, ext

# 서비스명 sanitize (점·대문자 → -, 소문자)
n = mc._compose_scaffold_service(T, "Web.App")
assert "  web-app:" in n, n
# A1: Dockerfile 감지 헬퍼 (루트 우선·정렬, EXPOSE 추출)
assert mc._list_dockerfiles(T / "ai-api") == ["Dockerfile"], mc._list_dockerfiles(T / "ai-api")
assert mc._list_dockerfiles(T / "multi") == ["x/Dockerfile", "y/Dockerfile"], mc._list_dockerfiles(T / "multi")
assert mc._list_dockerfiles(T / "web") == ["apps/web/Dockerfile"], mc._list_dockerfiles(T / "web")
assert mc._list_dockerfiles(T / "nope") == []
assert mc._dockerfile_expose(T / "api" / "Dockerfile") == "8081", mc._dockerfile_expose(T / "api" / "Dockerfile")
assert mc._dockerfile_expose(T / "ai-api" / "Dockerfile") is None
# 케이싱: DockerFile(대문자 F) 는 잡고, _Backup 류는 제외 (이름 규칙)
assert mc._is_dockerfile_name("DockerFile") and mc._is_dockerfile_name("Dockerfile.dev") and mc._is_dockerfile_name("app.dockerfile"), "casing"
assert not mc._is_dockerfile_name("DockerFile_Backup_250908") and not mc._is_dockerfile_name("readme.md"), "backup excluded"
assert mc._list_dockerfiles(T / "caps") == ["DockerFile"], mc._list_dockerfiles(T / "caps")
# 자체 compose 감지: 있으면 파일명, Dockerfile 만 있으면 ""
assert mc._subrepo_compose(T / "withcompose") == "docker-compose.yml", mc._subrepo_compose(T / "withcompose")
assert mc._subrepo_compose(T / "api") == "", mc._subrepo_compose(T / "api")
# 검증 전 외부 include 제거(attach 전): 외부만이면 include 키째 제거, 서비스는 유지
y1 = "include:\n  - ./.workspace/external/ai-api/docker-compose.yml\nservices:\n  web:\n    build: ./web\n"
r1 = mc._yaml_without_external_includes(y1)
assert "external" not in r1 and "include:" not in r1 and "web" in r1, r1
# 내부 include 는 유지, 외부만 제거
y2 = "include:\n  - ./sub/docker-compose.yml\n  - ./.workspace/external/x/docker-compose.yml\nservices:\n  a: {}\n"
r2 = mc._yaml_without_external_includes(y2)
assert "./sub/docker-compose.yml" in r2 and "external" not in r2 and "include:" in r2, r2
# 서비스 → 서브레포 라벨(빌드 컨텍스트 출처): 외부=.workspace/external/<name>, 내부=top dir, 루트/없음=""
assert mc._subrepo_label_from_context("/proj/.workspace/external/ai-stack/svc_a", Path("/proj")) == "ai-stack"
assert mc._subrepo_label_from_context("/proj/be-api/user-api", Path("/proj")) == "be-api"
assert mc._subrepo_label_from_context("/proj/web", Path("/proj")) == "web"
assert mc._subrepo_label_from_context("/proj", Path("/proj")) == "."        # 루트(단일레포) → '.'
assert mc._subrepo_label_from_context("/proj/../x", Path("/proj")) == ""    # 워크트리 밖 → ""
assert mc._subrepo_label_from_context(None, Path("/proj")) == ""
# 코덱스 감사 #8: 심볼릭 root(macOS /tmp→/private/tmp 등) — realpath 양쪽 해석이라 라벨 안 사라짐
import os as _os
_link = T.parent / "projlink8"
try: _os.symlink(T, _link)
except (OSError, FileExistsError): _link = None
if _link: assert mc._subrepo_label_from_context(str(T / "ai-api"), _link) == "ai-api", mc._subrepo_label_from_context(str(T / "ai-api"), _link)
# 외부 주입 감지: ARG / 필수(가드 -z) / 아티팩트(*.jar) / 런타임 힌트
dft = 'FROM x\nARG BUILD_ENV\nARG PROFILE\nRUN if [ -z "$BUILD_ENV" ]; then exit 1; fi\nCOPY user-api*.jar app.jar\n# AWS 자격증명은 런타임에 주입\n'
inj = mc._detect_injections(dft)
assert inj["args"] == ["BUILD_ENV", "PROFILE"], inj
assert inj["requiredArgs"] == ["BUILD_ENV"], inj            # 가드 있는 것만 필수
assert any(".jar" in a for a in inj["artifacts"]), inj      # 선빌드 필요
assert any("런타임" in r for r in inj["runtime"]), inj       # 런타임 주입 힌트
assert mc._detect_injections("") == {"args": [], "requiredArgs": [], "artifacts": [], "runtime": []}
# 코덱스 감사 #7: 주석 속 가드 오탐 안 함, ${X:?} 가드 인정, COPY --from(multistage 내부)은 아티팩트 아님
inj7 = mc._detect_injections('ARG TOKEN\nARG PORT\n# RUN test -z "$TOKEN"\nRUN : ${PORT:?required}\nCOPY --from=build /app/x.jar y.jar\n')
assert "TOKEN" not in inj7["requiredArgs"], inj7
assert "PORT" in inj7["requiredArgs"], inj7
assert inj7["artifacts"] == [], inj7
# 마운트 자동제안: WORKDIR(마지막) / 설정파일 찾기
assert mc._workdir_from_dockerfile("FROM x\nWORKDIR /app\nWORKDIR /srv\n") == "/srv"
assert mc._workdir_from_dockerfile("FROM x") == ""
cfgdir = T / "cfgsvc" / "src" / "main" / "resources"
cfgdir.mkdir(parents=True, exist_ok=True)
(cfgdir / "application-local.yml").write_text("spring:\n  data:\n    redis:\n      host: localhost\n")
cf = mc._find_config_files(T / "cfgsvc")
assert any("application-local.yml" in c for c in cf), cf
# 단일레포/root: 루트 Dockerfile → '.' 후보 + 루트 스캐폴드(context ".", 이름=프로젝트명) — 모든 프로젝트 동작
rootp = T / "singlerepo"; rootp.mkdir()
(rootp / "Dockerfile").write_text("FROM python:3-alpine\nEXPOSE 5000\n")
assert "." in mc._detect_subrepos(rootp), mc._detect_subrepos(rootp)
rs = mc._compose_scaffold_service(rootp, ".")
assert "  singlerepo:" in rs and "build: ." in rs and 'expose: ["5000"]' in rs, rs
assert mc._subrepo_label_from_context(str(rootp), rootp) == ".", mc._subrepo_label_from_context(str(rootp), rootp)
print("ok detect+scaffold:", subs)
PY
echo "PASS test-compose-scaffold"
