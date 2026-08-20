#!/usr/bin/env bash
# 클로드 CLI 로그인이 풀린 걸 **알아보고 말해준다.**
#
# 형 지적(2026-08-18): 클로드 로그인이 풀렸는데 폰에서는 왜 안 되는지 알 수가 없다.
# 마리나는 api_error 를 "문제"로만 표시했다 — 잠깐 먹통(529·타임아웃, 알아서 재시도됨)과
# 로그인 만료(형이 맥에서 손을 대야 풀림)가 같은 얼굴이었다.
#
# 문구 근거는 CLI 바이너리에서 직접 뽑았다(2026-08-18, v2.1.237):
#   "Not logged in · Please run /login"   ← 실제 실행으로 확인
#   "Please run /login", "Invalid API key", "Run /login to sign in with your claude.ai account"
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_sessions import api_error_reason

# ① 로그인이 풀린 것 — 형이 손을 대야 풀린다.
assert api_error_reason({"message": "Not logged in · Please run /login"}) == "needs_login"
assert api_error_reason({"message": "Invalid API key · Please run /login", "status": 401}) == "needs_login"
assert api_error_reason({"message": 'Run /login to sign in with your claude.ai account'}) == "needs_login"
assert api_error_reason({"message": '{"type":"authentication_error","message":"x"}', "status": 401}) == "needs_login"
# 상태코드만 401 이어도 인증 문제다.
assert api_error_reason({"message": "unexpected", "status": 401}) == "needs_login"

# ② **알아서 낫는 것과 구별한다.** 이걸 섞으면 잠깐 먹통일 때마다 "로그인하세요"가 뜬다.
assert api_error_reason({"message": "Request timed out."}) == "api_error"
assert api_error_reason({"message": '529 {"type":"overloaded_error"}', "status": 529}) == "api_error"
assert api_error_reason({"message": "rate limited", "status": 429}) == "api_error"
assert api_error_reason({}) == "api_error"
assert api_error_reason(None) == "api_error"

# ③ 한도 소진도 형이 손대야 하지만 **로그인과는 다른 조치**다 — 섞으면 엉뚱한 걸 시킨다.
assert api_error_reason({"message": "Credit balance too low"}) == "needs_credit"
assert api_error_reason({"message": "usage limit reached"}) == "needs_credit"
print("ok 로그인 만료를 잠깐 먹통과 구별한다")
PY

# ④ 그 사유가 세션 상태에 실려 폰까지 간다 — 감지만 하고 안 보여주면 소용없다.
PYTHONPATH="$SCR" python3 - <<'PY'
import json
import tempfile
import time
from pathlib import Path

import marina_sessions as ms

# **레포 안에 쓰지 않는다.** 예전엔 plugin/tests/ 아래에 픽스처를 만들어, 돌릴 때마다 워킹트리가
# 더러워지고 그 파일이 커밋마다 딸려 들어갔다(harness.sh 는 ~/.marina 만 격리한다).
tmp = Path(tempfile.mkdtemp())
path = tmp / "session.jsonl"
now = time.time()
rows = [
    {"type": "user", "timestamp": now - 10},
    {"type": "system", "subtype": "api_error", "timestamp": now,
     "error": {"message": "Not logged in · Please run /login", "status": 401}},
]
path.write_text("\n".join(json.dumps(r) for r in rows), encoding="utf-8")

후보, _ = ms._agent_status_candidates(path, "claude")
실패 = [c for c in 후보 if c[0] == "failed"]
assert 실패, 후보
assert 실패[-1][2] == "needs_login", 후보
print("ok 트랜스크립트에서 로그인 만료를 읽어낸다")
PY

# ⑤ 화면에 사람 말로 뜬다 — 사유 코드만 보내면 형은 여전히 모른다.
PYTHONPATH="$SCR" python3 - <<'PY'
from marina_mobile import render_mobile_html

html = render_mobile_html()
assert "needs_login" in html, "화면이 로그인 만료 사유를 모른다"
assert "로그인" in html
블록 = html[html.find("// STATUS_REASON_START"):html.find("// STATUS_REASON_END")]
assert 블록, "STATUS_REASON 블록이 없다"
assert "needs_login" in 블록 and "needs_credit" in 블록, 블록
# ⑥ **방 목록에서 바로 보인다.** 문구만 만들고 안 걸면 형은 대화를 열어보기 전엔 모른다.
assert "blockedReason" in html, "방이 막힌 사유를 안 나른다"
목록 = html[html.find("// ROOM_LIST_START"):html.find("// ROOM_LIST_END")]
assert "statusReasonText" in 목록, 목록[-500:]
print("ok 폰이 사람 말로 알려준다")

PY

echo "PASS test-login-detect"
