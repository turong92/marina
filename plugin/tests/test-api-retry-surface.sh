#!/usr/bin/env bash
# CLI 가 **API 오류로 재시도 중**이면 폰에도 그렇게 보여야 한다 — 형: "보냈는데 계속 생각중인데".
#
# **실측(2026-08-24).** 채팅방이 응답을 안 주길래 화면을 열어보니:
#     ✻ API error · Retrying in 1s · attempt 1/10
# 같은 시각 다른 폴더에서도 `api_error_status: 529 Overloaded` — 서버 과부하였다. 마리나
# 잘못이 아닌데도 폰에는 **"생각 중"** 하나만 보여서, 형은 마리나가 먹통인 줄 알고 한참 기다렸다.
# 로그인 화면을 읽어 올리는 것과 같은 방식으로, 이 상태도 화면에서 읽어 올린다(횟수까지).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_login import api_retry

# ① 실물 화면 그대로(ANSI 제거 후). 재시도 횟수까지 뽑는다.
실물 = """
❯ 안녕 한 줄로 답해줘
✻ API error · Retrying in 1s · attempt 1/10
"""
상태 = api_retry(실물)
assert 상태 and 상태["attempt"] == 1 and 상태["total"] == 10, 상태
assert "재시도" in 상태["label"], 상태

# ② 칸이 좁아 공백이 뭉개져도 읽는다(터미널이 그렇게 그린다 — 실측에서 붙어 나왔다).
붙음 = "✻APIerror·Retryingin4s·attempt3/10"
상태2 = api_retry(붙음)
assert 상태2 and 상태2["attempt"] == 3 and 상태2["total"] == 10, 상태2

# ③ 과부하(529)라고 화면이 말하면 사람 말로 옮긴다 — 형이 무엇 때문인지 알아야 한다.
상태3 = api_retry("API Error: 529 Overloaded · attempt 2/10")
assert 상태3 and "혼잡" in 상태3["label"], 상태3

# ④ 평범한 화면에서는 아무것도 아니다 — 멀쩡한 세션에 경고를 띄우면 안 된다.
assert api_retry("❯ 안녕\n· Cogitating… (3s)") is None
assert api_retry("") is None
print("ok 화면에서 재시도 상태를 읽는다(횟수·이유)")
PY

# ⑤ 방 상태에 실려 폰까지 간다.
PYTHONPATH="$SCR" python3 - <<'PY2'
import inspect

import marina_mobile as mm

원본 = inspect.getsource(mm)
assert "api_retry" in 원본, "모바일 상태가 재시도를 읽지 않는다"
화면 = mm.render_mobile_html()
assert "retry" in 화면, "화면이 재시도 상태를 그리지 않는다"
print("ok 재시도 상태가 방 상태·화면까지 이어진다")
PY2

echo "PASS test-api-retry-surface"
