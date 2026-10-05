#!/usr/bin/env bash
# HTML 미리보기 높이(2026-10-05): 짧은 페이지인데 1차 촬영 창(1400px)만큼 빈 공간이 붙던 것 — scrollHeight 는 창 높이보다
# 작아지지 않는다. 내용 끝까지만 찍혀야 한다. 실제 크롬이 있을 때만(없으면 SKIP).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$TMPROOT" <<'PY'
import struct, sys
from pathlib import Path
import marina_share as sh
if not sh.find_chrome():
    print("SKIP (크롬 없음)"); sys.exit(0)
tmp = Path(sys.argv[1]); root = tmp / "r"; root.mkdir()
(root / "short.html").write_text('<!doctype html><meta charset=utf-8><body style="margin:16px"><h1>짧은 페이지</h1>'
                                 '<div style="height:300px;background:#eee">상자</div></body>')
png, why = sh.render_html(root / "short.html", root, tmp / "out")
w, h = struct.unpack(">II", png.read_bytes()[16:24])
css_h = h / (w / sh.WIDTH)
if not (350 <= css_h <= 600):
    print(f"FAIL: 짧은 페이지 미리보기 높이 {css_h:.0f}px (기대 약 400px — 빈 공간 없이)"); sys.exit(1)
# PC 폭 페이지는 폭에 맞게 축소(zoom)된다 — 그 높이도 맞아야(요소 좌표는 이미 축소된 값이라 또 곱하면 잘린다)
(root / "wide.html").write_text('<!doctype html><meta charset=utf-8><body style="margin:0"><div style="width:1500px;height:900px;background:#cde">w</div><p>end</p></body>')
png, why = sh.render_html(root / "wide.html", root, tmp / "out")
w, h = struct.unpack(">II", png.read_bytes()[16:24])
css_h = h / (w / sh.WIDTH)
if not (280 <= css_h <= 400):
    print(f"FAIL: 넓은 페이지 미리보기 높이 {css_h:.0f}px (기대 약 320px)"); sys.exit(1)
PY
echo "PASS test-discord-preview-height"
