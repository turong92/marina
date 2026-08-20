#!/usr/bin/env bash
# 폰에서 **만들 수는 있는데 지울 수 없던 것들**.
#
# 형 지적(2026-08-18): "모바일에서 삭제 없는거도 추가해줘".
# 훑어보니 둘 남아 있었다 — 폰에서 보낸 사진(실측 18개·2.5MB, 계속 쌓인다)과
# 폰에서 띄운 대화 프로세스(정지=Esc 는 있는데 아예 끄는 길이 없다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import time
from pathlib import Path

import marina_mobile as mm

up = mm.MOBILE_UPLOADS_DIR
up.mkdir(parents=True, exist_ok=True)
오래된 = up / "old-image.png"
새것 = up / "new-image.png"
오래된.write_bytes(b"x" * 1000)
새것.write_bytes(b"y" * 500)
옛날 = time.time() - 40 * 24 * 3600
import os
os.utime(오래된, (옛날, 옛날))

# ① 뭐가 얼마나 쌓였는지 **먼저 알려준다** — 숫자 없이 "정리할까요?"는 무서워서 못 누른다.
현황 = mm.upload_usage()
assert 현황["files"] == 2 and 현황["bytes"] == 1500, 현황

# ② 기본은 **오래된 것만**. 최근 사진은 대화에 붙어 있어서 지우면 그 메시지의 그림이 깨진다.
결과 = mm.mobile_clear_uploads({"olderThanDays": 30})
assert 결과["removed"] == 1, 결과
assert 새것.exists() and not 오래된.exists(), "최근 사진까지 지웠다"

# ③ 전부 지우기도 된다(형이 명시할 때만).
결과 = mm.mobile_clear_uploads({"olderThanDays": 0})
assert 결과["removed"] == 1 and not 새것.exists(), 결과

# ④ **값이 없으면 기본은 보수적으로 30일**이다. 되돌릴 수 없는 동작의 기본이 "전부"면 안 된다.
오래된.write_bytes(b"x" * 10); 새것.write_bytes(b"y" * 10)
os.utime(오래된, (옛날, 옛날))
assert mm.mobile_clear_uploads({})["removed"] == 1, "기본값이 전부 삭제다"
assert 새것.exists(), "기본값으로 최근 사진까지 지웠다"
assert mm.mobile_clear_uploads({"olderThanDays": "이상한값"})["removed"] == 0, "깨진 값이 전부 삭제로 떨어진다"
새것.unlink()

# ⑤ **업로드 폴더 밖은 절대 안 건드린다.** 경로가 새면 지우기가 무기가 된다.
밖 = up.parent / "지우면안됨.json"
밖.write_text("keep", encoding="utf-8")
mm.mobile_clear_uploads({"olderThanDays": 0})
assert 밖.exists(), "업로드 폴더 밖 파일을 지웠다"
print("ok 업로드 정리: 현황·오래된 것만·전부·폴더 밖 안전")
PY

# ⑥ 대화 끄기 — 폰에서 띄웠으면 폰에서 끌 수 있어야 한다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY2'
import sys
from pathlib import Path

src = (Path(sys.argv[1]) / "marina_handler.py").read_text(encoding="utf-8")
for path in ('"/mobile/api/clear-uploads"', '"/mobile/api/close-chat"'):
    assert path in src, f"{path} 가 라우팅에 없다"
끄기 = src[src.find('if parsed.path == "/mobile/api/close-chat"'):][:500]
assert "safe_root" in 끄기 and "_require_root_access" in 끄기, 끄기
import marina_handler
print("ok 정리·끄기 표면이 붙어 있고 가드를 탄다")
PY2

# ⑦ 화면: **취소는 취소여야 한다.** 확인/취소를 두 갈래 선택지로 쓰면, 놀라서 취소를 눌러도
# 지워진다 — 되돌릴 수 없는 동작에 빠져나올 문이 없어진다.
PYTHONPATH="$SCR" python3 - <<'PY3'
from marina_mobile import render_mobile_html

html = render_mobile_html()
목록 = html[html.find('id="listView"'):html.find('id="chatView"')]
assert "data-clear-uploads" in 목록 or "clearUploads" in html, "사진 정리 손잡이가 없다"
탭 = html[html.find("// ROOM_TABS_START"):html.find("// ROOM_TABS_END")]
assert "data-close-chat" in 탭, f"대화를 끌 방법이 없다: {탭[:300]}"
끄기 = html[html.find("async function closeChatProcess"):][:800]
assert "confirm(" in 끄기, "돌던 일이 끊기는데 안 묻는다"
# **못 껐으면 껐다고 하면 안 된다.** 데몬 재시작 뒤엔 끌 tid 가 없어 서버가 closed:false 를
# 준다 — 폭주 CLI 를 끄려던 순간에 "껐어요"는 거짓말이 된다.
assert "d.closed" in 끄기, f"못 껐는데 껐다고 한다: {끄기[:400]}"
정리 = html[html.find("async function clearUploads"):][:900]
assert "if (!confirm(" in 정리, f"취소해도 지워진다: {정리[:300]}"
assert "olderThanDays: 30" in 정리, 정리[:400]
print("ok 화면에 정리·끄기 손잡이가 있다")
PY3

echo "PASS test-mobile-cleanup"
