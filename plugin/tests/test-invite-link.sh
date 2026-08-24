#!/usr/bin/env bash
# 계정은 **초대**로 만든다 — 형: "초대가 맞아 가입이 맞아?" → 초대.
#
# 마리나엔 회원가입 엔드포인트가 없다(공개 경로는 login·status·bootstrap·claim 뿐). 계정은
# 관리자가 `user add` 로 만드는데, 지금 흐름은 군더더기가 둘이다:
#   ① 초대받은 사람이 **있지도 않은 비밀번호**를 아무거나 넣어야 "비밀번호 설정" 화면이 뜬다
#   ② 비번을 정하면 pending_approval 이라 관리자가 **또 승인**해야 한다
#      (관리자가 만든 계정인데 관리자가 다시 승인 — 만든 순간 이미 승인한 것이다)
# 그래서: add 가 초대 링크를 내주고, 그 링크로 들어오면 바로 설정 화면, 정하면 **즉시 활성**.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
ENTRY="$SCR/marina-entrypoint.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"

# ① add 가 초대 링크를 출력한다.
out="$(bash "$ENTRY" user add teammate --name 팀원 --role member 2>&1)"
grep -q "login?claim=teammate" <<<"$out" || { echo "FAIL: 초대 링크가 없다: $out"; exit 1; }

# ② 관리자가 만든 계정은 비번을 정하면 **바로 활성**이다(승인 단계 없음).
PYTHONPATH="$SCR" python3 - <<'PY'
from marina_auth import AuthStore
from marina_state import MARINA_HOME

store = AuthStore(MARINA_HOME / "auth.db")
사람 = store.claim_user("teammate", "충분히-긴-비밀번호-1234")
assert 사람.status == "active", f"초대받은 계정이 또 승인을 기다린다: {사람.status}"
print("ok 초대 계정: 비밀번호 정하면 즉시 활성")
PY

# ③ 로그인 화면이 ?claim=<이름> 을 알아듣고 바로 설정 폼을 연다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY2'
import sys
from pathlib import Path

js = (Path(sys.argv[1]) / "marina-web" / "auth-login.js").read_text(encoding="utf-8")
assert "claim" in js and "URLSearchParams" in js, "로그인 화면이 초대 링크를 안 읽는다"
html = (Path(sys.argv[1]) / "marina-web" / "login.html").read_text(encoding="utf-8")
assert "승인 요청" not in html, "초대인데 아직 '승인 요청'이라고 말한다"
print("ok 초대 링크로 들어오면 바로 비밀번호 설정")
PY2

echo "PASS test-invite-link"
