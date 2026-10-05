#!/usr/bin/env bash
# 결과물 자동 공유(2026-10-05 형: "그렇게 말 안해도 알아서 보내야지") — 세션 규칙이 시키지 않아도 share_file 로 보내고
# 열어보기 주소를 reply 본문에 넣으라고 말하는지. 채팅방 규칙은 '파일 받아서 브라우저로 열어' 옛 안내가 없어야(이제 링크로 열린다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import sys, marina_session as ms
fails = []
def check(c, m):
    if not c: fails.append(m)
for name, rules in (("개발", ms.CHANNEL_RULES), ("채팅", ms.CHAT_RULES)):
    check("시키지 않아도" in rules and "share_file" in rules, f"{name}: 알아서 share_file")
    check("열어보기 주소" in rules, f"{name}: 열어보기 주소를 reply 에")
check("브라우저로 열어 줘" not in ms.CHAT_RULES, "채팅: 옛 '파일 받아서 브라우저로' 안내 없음")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-share-rules"
