#!/usr/bin/env bash
# PreToolUse 훅: 등록 프로젝트 안 dev 서버 직접 기동 → deny JSON, 그 외(조회성·탈출구·미등록·깨진 입력)는 전부 무출력(allow)
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK="$HERE/../scripts/marina-pretooluse-hook.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
proj="$TMP/proj"; mkdir -p "$proj"; ( cd "$proj" && git init -q )
"$HERE/../scripts/marina.sh" project add "$proj" >/dev/null

req() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$2"; }
deny()  { out="$(req "$1" "$2" | "$HOOK")"; echo "$out" | grep -q '"permissionDecision": *"deny"' || { echo "FAIL(deny 기대): $1 → [$out]"; exit 1; }; }
allow() { out="$(req "$1" "$2" | "$HOOK")"; [[ -z "$out" ]] || { echo "FAIL(allow 기대): $1 → [$out]"; exit 1; }; }

# 차단: 패턴표 각 계열 대표
deny  "npm run dev" "$proj"
deny  "pnpm run serve" "$proj"
deny  "yarn start" "$proj"
deny  "docker compose up -d" "$proj"
deny  "docker-compose up" "$proj"
deny  "./gradlew bootRun" "$proj"
deny  "cd be && ./mvnw spring-boot:run" "$proj"
deny  "python manage.py runserver 0.0.0.0:8000" "$proj"
deny  "npx vite" "$proj"
deny  "git pull && npm run dev" "$proj"
deny  "uvicorn app.main:app --reload" "$proj"
deny  "cd api && poetry run uvicorn main:app" "$proj"
deny  "python -m uvicorn main:app" "$proj"
# 통과: 조회성·빌드·테스트
allow "npm run build" "$proj"
allow "npm test" "$proj"
allow "docker compose ps" "$proj"
allow "docker compose logs -f be" "$proj"
allow "docker compose config" "$proj"
allow "./gradlew test --dry-run" "$proj"
allow "vite build" "$proj"
# 통과: 오탐 회귀(코덱스 P2) — 따옴표 안 검색어·인용은 판정 비대상
allow "rg 'npm run dev' README.md" "$proj"
allow "echo 'docker compose up'" "$proj"
allow "git commit -m \"docs: docker compose up 금지 안내\"" "$proj"
# 통과: 오탐 회귀(셀프 리뷰) — 파일명 참조·설치·리다이렉트·멀티라인 문장 경계
allow "cat vite.config.ts" "$proj"
allow "pip install uvicorn fastapi" "$proj"
allow "docker compose logs be > up.log" "$proj"
allow "$(printf './gradlew build\nnpm run lint')" "$proj"
allow "$(printf 'docker compose ps\necho please start the server')" "$proj"
# 멀티라인이어도 실제 기동 문장은 차단
deny  "$(printf 'git pull\nnpm run dev')" "$proj"
# 통과: 탈출구
allow "MARINA_DIRECT=1 npm run dev" "$proj"
# 통과: 미등록 레포
other="$TMP/other"; mkdir -p "$other"; ( cd "$other" && git init -q )
allow "npm run dev" "$other"
# fail-open: 깨진 stdin 이어도 exit 0 + 무출력
out="$(echo 'kaput{' | "$HOOK")" && [[ -z "$out" ]] || { echo "FAIL: 깨진 stdin 에 fail-open 아님: [$out]"; exit 1; }
# fail-open: 레지스트리 깨짐(unknown) 은 차단하지 않음
cp "$MARINA_HOME/projects.json" "$TMP/pj.bak"; echo '{broken' > "$MARINA_HOME/projects.json"
allow "npm run dev" "$proj"
cp "$TMP/pj.bak" "$MARINA_HOME/projects.json"
# --is-registered 공유 진입점: 등록=0(+id) · 미등록=1 · 레지스트리 깨짐=2
pid="$(python3 "$HERE/../scripts/marina_pretooluse.py" --is-registered "$proj")" || { echo "FAIL: --is-registered 등록 판정"; exit 1; }
[[ -n "$pid" ]] || { echo "FAIL: --is-registered 가 project id 를 안 냄"; exit 1; }
rc=0; python3 "$HERE/../scripts/marina_pretooluse.py" --is-registered "$other" >/dev/null || rc=$?
[[ $rc -eq 1 ]] || { echo "FAIL: 미등록 exit 1 아님 (rc=$rc)"; exit 1; }
echo '{broken' > "$MARINA_HOME/projects.json"
rc=0; python3 "$HERE/../scripts/marina_pretooluse.py" --is-registered "$proj" >/dev/null || rc=$?
[[ $rc -eq 2 ]] || { echo "FAIL: 판정불가 exit 2 아님 (rc=$rc)"; exit 1; }
cp "$TMP/pj.bak" "$MARINA_HOME/projects.json"
echo "PASS test-pretooluse-block"
