#!/usr/bin/env bash
# 폰을 울리는 건 **데몬 하나뿐**이어야 한다.
#
# 형 지적(2026-08-20): "푸시 메세지 오는게 스팸일 수 있다고 뜨는데".
# 추적해 보니 마리나 프로세스가 둘 돌고 있었다 — 진짜 데몬과, 내가 화면을 확인하려고 띄운
# 프리뷰 서버(다른 포트, 같은 ~/.marina). 둘 다 감지 루프를 돌려 **각자 푸시를 쏘고**,
# 프리뷰를 다시 띄울 때마다 중복 억제 상태(_last_fired)가 초기화됐다.
# 실측 흔적: 같은 세션·같은 종류의 "작업이 끝났어요"가 5초 간격으로, 심지어 같은 초에 두 번.
# 그렇게 쌓인 무의미한 알림이 브라우저의 스팸 판정을 부른다.
#
# 조심해서 될 문제가 아니다 — 두 번째 인스턴스가 형 폰으로 쏠 수 있는 구조 자체를 막는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from pathlib import Path

import marina_notify as nf

home = Path(nf.ALERTS_FILE).parent
home.mkdir(parents=True, exist_ok=True)
bind = home / "dashboard-bind.env"

# ① 데몬이 쓰는 포트와 같으면 **내가 그 데몬이다** — 알린다.
bind.write_text("MARINA_CONTROL_HOST=localhost\nMARINA_CONTROL_PORT=3900\n", encoding="utf-8")
assert nf.is_primary_notifier(3900) is True

# ② 다른 포트로 떠 있으면 **두 번째 인스턴스**다 — 폰을 울리지 않는다.
assert nf.is_primary_notifier(3977) is False, "프리뷰가 형 폰으로 푸시를 쏜다"

# ③ 기록 파일이 없으면(첫 실행·수동 기동) 막지 않는다 — 알림이 통째로 죽는 쪽이 더 나쁘다.
bind.unlink()
assert nf.is_primary_notifier(3977) is True

# ④ 파일이 깨져 있어도 막지 않는다.
bind.write_text("쓰레기\n", encoding="utf-8")
assert nf.is_primary_notifier(3900) is True
print("ok 두 번째 인스턴스는 폰을 안 울린다(모르면 막지 않는다)")
PY

# ⑤ 실제 알림 경로가 그 판정을 탄다 — 함수만 있고 안 쓰면 소용없다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY2'
import sys
from pathlib import Path

src = (Path(sys.argv[1]) / "marina_handler.py").read_text(encoding="utf-8")
블록 = src[src.find("def _on_events"):][:1200]
assert "is_primary_notifier" in 블록, f"알림 경로가 판정을 안 탄다: {블록[:400]}"
# 기록도 같이 막아야 한다 — 두 인스턴스가 같은 파일에 쓰면 알림이 두 배로 쌓인다.
기록자리 = 블록.find("record_alerts")
가드자리 = 블록.find("is_primary_notifier")
assert 0 <= 가드자리 < 기록자리, f"기록보다 뒤에서 막는다: {블록[:500]}"
import marina_handler
print("ok 알림 경로가 판정을 탄다")
PY2

echo "PASS test-single-notifier"
