#!/usr/bin/env bash
# 올릴 이미지·인쇄본 뽑기(2026-10-16): 미리보기(폰 폭 500)와 달리 쇼핑몰에 그대로 올리는 제 크기 PNG,
# 그리고 인쇄소에 넘기는 PDF 다.
# 폭이 지정대로여야 하고, 길면 섹션 경계에서 나뉘어야 한다(글자 중간에서 잘리면 못 쓴다).
# 나누는 계산은 크롬 없이도, 실제 촬영은 크롬이 있을 때만(없으면 그 부분만 SKIP).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$TMPROOT" <<'PY'
import struct, sys
from pathlib import Path
import marina_share as sh

fail = []
def check(ok, msg):
    if not ok:
        fail.append(msg)

# ── 나누는 계산: 경계가 있으면 거기서, 없으면 상한에서. 끝이 토막나면 앞 장에 붙인다
check(sh.slice_plan(2500, [1200], 3000) == [(0, 2500)], "상한 안에 드는데 나눴다")
check(sh.slice_plan(9000, [], 3000) == [(0, 3000), (3000, 3000), (6000, 3000)], "경계가 없으면 상한대로 잘라야")
check(sh.slice_plan(9000, [2800, 5600, 8400], 3000) == [(0, 2800), (2800, 2800), (5600, 2800), (8400, 600)],
      "섹션 경계에 맞춰 자르지 않았다")
check(sh.slice_plan(9001, [9000], 3000) == [(0, 3000), (3000, 3000), (6000, 3001)],
      "끝에 1px 토막이 한 장으로 남았다")
check(sh.slice_plan(9001, [3100, 6200, 9000], 3000) == [(0, 3100), (3100, 3100), (6200, 2801)],
      "상한을 조금 넘더라도 경계에 맞추는 쪽이 낫다")
check(len(sh.slice_plan(50000, [], 3000)) > sh.MAX_PARTS, "너무 긴 페이지를 걸러낼 수 없다")

if not sh.find_chrome():
    print("\n".join(fail) or "SKIP (크롬 없음 — 촬영은 건너뜀)")
    sys.exit(1 if fail else 0)

tmp = Path(sys.argv[1]); root = tmp / "x"; root.mkdir()
sec = ('<section style="height:2500px;background:{}">{}</section>')
(root / "long.html").write_text(
    '<!doctype html><meta charset=utf-8><body style="margin:0"><div class=page>'
    + sec.format("#eef", "하나") + sec.format("#efe", "둘") + sec.format("#fee", "셋")
    + "</div></body>", encoding="utf-8")
files, why = sh.export_html(root / "long.html", root, tmp / "out", width=860, slice_h=3000)
check(len(files) == 3, f"섹션 3개(각 2500px)는 3장이어야 하는데 {len(files)}장 ({why})")
for f in files:
    w, h = struct.unpack(">II", f.read_bytes()[16:24])
    check(w == 860, f"{f.name}: 폭이 860 이 아니라 {w}")
    check(abs(h - 2500) <= 2, f"{f.name}: 섹션 경계(2500px)가 아니라 {h}px 에서 잘렸다")

# 짧은 페이지는 한 장, 파일 이름에 번호가 붙지 않는다
(root / "short.html").write_text('<!doctype html><meta charset=utf-8><body style="margin:0">'
                                 '<div style="height:600px;background:#ddd">짧다</div></body>', encoding="utf-8")
one, why = sh.export_html(root / "short.html", root, tmp / "out", width=780, slice_h=3000)
check(len(one) == 1 and one[0].name == "short.png", f"짧은 페이지가 한 장이 아니다: {[f.name for f in one]} ({why})")
if one:
    w, _ = struct.unpack(">II", one[0].read_bytes()[16:24])
    check(w == 780, f"지정한 폭(780)이 아니라 {w}")

# ── 다시 뽑으면 지난번 조각은 치우되, 이름이 비슷한 다른 페이지의 결과물은 건드리지 않는다
out = tmp / "out"
(out / "long-9.png").write_text("옛 조각")          # 지난번에 더 잘게 나뉜 것
(out / "long-B.png").write_text("다른 안")          # long-B.html 의 결과물
(out / "long-최종.png").write_text("보관본")
again, _ = sh.export_html(root / "long.html", root, out, width=860, slice_h=3000)
check(not (out / "long-9.png").exists(), "지난번 조각이 안 치워졌다")
check((out / "long-B.png").exists() and (out / "long-최종.png").exists(),
      "이름이 비슷한 다른 파일까지 지웠다")
check(len(again) == 3 and all(f.exists() for f in again), "다시 뽑은 결과가 온전하지 않다")

# ── 인쇄용 PDF: 화면 폭에 맞춰 줄이지 말고 페이지가 정한 @page 규격(여기선 A4+재단 3mm)을 그대로
(root / "leaf.html").write_text(
    '<!doctype html><meta charset=utf-8><style>@page{size:216mm 303mm;margin:0}'
    'html,body{margin:0}.p{width:216mm;height:303mm;page-break-after:always}</style>'
    '<body><div class=p>앞</div><div class=p>뒤</div></body>', encoding="utf-8")
pdf, why = sh.export_pdf(root / "leaf.html", root, tmp / "out")
check(pdf is not None, f"PDF 를 못 만들었다 ({why})")
if pdf:
    import re
    data = pdf.read_bytes()
    box = set(re.findall(rb"/MediaBox\s*\[([^\]]*)\]", data))
    check(len(box) == 1, f"페이지마다 크기가 다르다: {box}")
    v = [float(x) for x in box.pop().split()]
    mm = ((v[2] - v[0]) / 72 * 25.4, (v[3] - v[1]) / 72 * 25.4)
    check(abs(mm[0] - 216) < 1 and abs(mm[1] - 303) < 1, f"@page 규격(216x303mm)이 아니라 {mm[0]:.0f}x{mm[1]:.0f}mm")
    check(len(re.findall(rb"/Type\s*/Page[^s]", data)) == 2, "두 면짜리가 두 쪽으로 안 나왔다")

print("\n".join("FAIL: " + m for m in fail))
sys.exit(1 if fail else 0)
PY
echo "PASS test-discord-export-image"
