#!/usr/bin/env bash
# 슬래시 명령은 **보류함에 들어가지 않는다.**
#
# 실측 사고(2026-09-09): 형이 마리나에서 `/resume` 을 보냈다. 그건 Claude Code 의 **세션 선택
# 다이얼로그**를 여는 명령이라 CLI 가 그 자리에서 멈췄고(`waitingFor: "dialog open"`), 멈춘
# 세션은 클라우드 브리지까지 붙들어 데스크탑 앱이 47분간 스피너였다. 그동안 마리나는 그
# `/resume` 을 보류함에 넣고 **14번 재시도**했다 — 풀어줄 때마다 다시 갇히는 재감염 고리다.
#
# 일반 메시지는 되풀이해도 "한 번 더 말한 것"이지만, 명령은 화면 상태를 바꾸는 물건이라
# 마리나가 그 결과를 확인할 수단이 없다. **결과를 모르는 것을 되풀이하지 않는다**가 규칙이다.
#
# 계약: ① 명령은 보류함에 안 들어간다(정직하게 거절) ② 일반 메시지는 종전대로 들어간다
# ③ 이미 디스크에 남은 명령 기록은 드레이너가 재시도하지 않고 걷어낸다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PYTHONPATH="$SCR" python3 - "$TMP" "$HERE" <<'PY'
import json
import sys
from pathlib import Path

import marina_mobile as mm

tmp, root = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
mm.OUTBOX_DIR = tmp / "outbox"
mm.safe_root = lambda value: Path(str(value)).resolve()

# ① 명령은 거절된다 — 조용히 삼키지도, 성공인 척하지도 않는다.
for 명령 in ("/resume", "  /resume  ", "/clear", "/agents"):
    try:
        mm.mobile_outbox_put(root, "claude", "sid-cmd", 명령)
    except ValueError as exc:
        assert "대기열" in str(exc) or "명령" in str(exc), f"이유를 안 말한다: {exc}"
    else:
        raise AssertionError(f"명령이 보류함에 들어갔다: {명령!r}")
assert mm.mobile_outbox_pending(root, "claude", "sid-cmd") == [], "거절했는데 파일이 남았다"

# ②-1 일반 메시지는 종전대로. 슬래시로 시작하지 '않는' 것은 명령이 아니다.
mm.mobile_outbox_put(root, "claude", "sid-ok", "이거 확인해줘")
assert mm.mobile_outbox_pending(root, "claude", "sid-ok") == ["이거 확인해줘"]

# ②-2 경로처럼 생긴 것을 명령으로 오해하지 않는다 — 형은 절대경로를 자주 붙여넣는다.
mm.mobile_outbox_put(root, "claude", "sid-path", "/Users/sumin/a.png 이거 봐줘")
assert mm.mobile_outbox_pending(root, "claude", "sid-path") == ["/Users/sumin/a.png 이거 봐줘"]

# ③ 이미 디스크에 남은 명령 기록은 **재시도하지 않고 걷어낸다**(사고 당시 attempts=14 였다).
감염 = mm.OUTBOX_DIR / "claude-sid-old.json"
감염.write_text(json.dumps({
    "source": "claude", "sid": "sid-old", "root": str(root),
    "messages": ["/resume"], "ts": 9e9, "attempts": 14,
}), encoding="utf-8")
보낸것 = []
mm.mobile_send = lambda body: 보낸것.append(body)
mm._native_agent_active = lambda r, s, i: False
mm.mobile_outbox_drain()
assert not 감염.exists(), "명령 기록이 보류함에 그대로 남았다 — 재감염 고리가 안 끊겼다"
# 같은 드레인에서 **정상 메시지는 그대로 전달된다** — 명령 하나 때문에 보류함 전체가 멎으면
# 그건 다른 고장이다. 명령만 안 나가면 된다.
보낸글 = [b["text"] for b in 보낸것]
assert not any("/resume" in t for t in 보낸글), f"명령을 다시 보냈다: {보낸글}"
assert "이거 확인해줘" in 보낸글, f"정상 메시지까지 멎었다: {보낸글}"

print("ok")
PY
echo "PASS: 슬래시 명령은 보류·재시도되지 않는다"
