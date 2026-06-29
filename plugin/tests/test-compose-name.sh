#!/usr/bin/env bash
# compose_project_name: <id>-<session> 를 docker 허용 문자(소문자/숫자/_/-)로 정규화.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CP="$HERE/../scripts/marina-compose.py"
[[ "$(python3 "$CP" name --project-id MyProj --session abc-123)" == "myproj-abc-123" ]] || { echo "FAIL: lower/keep"; exit 1; }
[[ "$(python3 "$CP" name --project-id ai.api --session 'feat/foo bar')" == "ai-api-feat-foo-bar" ]] || { echo "FAIL: sanitize"; exit 1; }
[[ "$(python3 "$CP" name --project-id=--- --session=)" == "marina" ]] || { echo "FAIL: empty fallback"; exit 1; }
echo "PASS test-compose-name"
