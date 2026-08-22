#!/usr/bin/env bash
# 앱을 안 건드린 방에는 [화면 보기]가 뜨면 안 된다 — 형: "근데 미리보기 할게 없잖아".
#
# **실측(2026-08-21).** `Prod index-api 변동성 확인` 방이 바꾼 것은
# `tasks/prod-autoscale-remediation/README.md` 문서 하나뿐인데, 완료 카드는 [화면 보기]를
# 띄웠다. 눌러 봐야 web 앱이 켜질 뿐 그 결과와는 아무 상관이 없다 — 헛걸음이고, 서버를
# 1분 켜 놓고 기다리게 만든다.
#
# 규칙: 바뀐 파일이 그 서비스의 폴더(compose 빌드 컨텍스트 = subrepo) 안에 있을 때만 앱으로
# 본다. **매핑을 모르면 예전처럼 띄운다** — 몰라서 숨기면 멀쩡한 길을 막는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_rooms import preview_service

앱들 = [{"service": "web", "subrepo": "web-app-monorepo"},
        {"service": "index-api", "subrepo": "be-api"},
        {"service": "mysql"}]

# ① 앱 폴더를 건드렸으면 그 앱을 연다.
assert preview_service(앱들, changed=["web-app-monorepo/src/page.tsx"]) == "web"

# ② 문서만 바꾼 방 — 열어봐야 볼 게 없다. 버튼을 띄우지 않는다.
assert preview_service(앱들, changed=["tasks/prod-autoscale-remediation/README.md"]) == ""

# ③ 서버 쪽만 바꿨어도 그 결과는 앱 화면에 나타난다 — 앱을 연다.
assert preview_service(앱들, changed=["be-api/src/Handler.kt"]) == "web"

# ④ 매핑을 모르면(subrepo 없음) 예전처럼 띄운다 — 몰라서 막지 않는다.
assert preview_service([{"service": "web"}, {"service": "mysql"}],
                       changed=["docs/whatever.md"]) == "web"

# ⑤ 바뀐 목록을 아예 안 주면(=모른다) 예전 동작 그대로다. 커밋까지 끝낸 방은 미커밋 경로가
#    0 이라 여기로 온다 — 그걸 "안 건드렸다"로 읽으면 멀쩡한 방에서 버튼이 사라진다.
assert preview_service(앱들) == "web"
assert preview_service(앱들, changed=None) == "web"

# ⑥ 이미 도는 앱이 있으면 그건 그대로 연다 — 이미 켜져 있는 걸 숨길 이유가 없다.
assert preview_service([{"service": "web", "subrepo": "web-app-monorepo", "running": True}],
                       changed=["docs/only.md"]) == "web"
print("ok 미리보기: 앱을 건드린 방에서만 · 모르면 막지 않는다")
PY

# ⑦ 방 목록이 그 판단에 필요한 재료(바뀐 파일 경로)를 실제로 들고 있어야 한다.
PYTHONPATH="$SCR" python3 - <<'PY2'
import inspect

import marina_rooms as mr

원본 = inspect.getsource(mr.room_has_changes)
assert "\"paths\"" in 원본 or "'paths'" in 원본, "요약에 경로가 없다 — 판단할 재료가 없다"
요약 = inspect.getsource(mr.change_summary)
assert "paths" in 요약, "change_summary 가 경로를 안 돌려준다"
print("ok 바뀐 파일 경로가 요약에 실린다")
PY2

echo "PASS test-preview-relevance"
