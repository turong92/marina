#!/usr/bin/env bash
# 미리보기 그림 줄이기(2026-11-10): 폰 폭 2배 PNG 가 4MB 까지 커져 폰에서 늦게 뜬다 → 보내기 전에 WebP(cwebp)·JPEG(sips)로 바꾼다.
# 바꿀 도구가 없거나 결과가 더 크면 원본 PNG 를 그대로 쓴다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$TMPROOT" <<'PY'
import os, shutil, struct, sys, zlib
from pathlib import Path
import marina_share as sh

tmp = Path(sys.argv[1])

def png(path: Path, w: int, h: int) -> Path:
    rows = b"".join(b"\x00" + bytes(c for x in range(w) for c in ((x * 7 + y * 3) % 256, (x ^ y) % 256, (y * 5) % 256)) for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))
    return path

if not (shutil.which("cwebp") or shutil.which("sips")):
    print("SKIP (cwebp·sips 없음)"); sys.exit(0)

src = png(tmp / "big.png", 400, 1200)
before = src.stat().st_size
out = sh.compact_image(src)
if out.suffix not in (".webp", ".jpg"):
    print(f"FAIL: 바뀌지 않았어 ({out})"); sys.exit(1)
if not out.is_file() or out.stat().st_size >= before:
    print(f"FAIL: 더 작아지지 않았어 ({before} → {out.stat().st_size if out.is_file() else '없음'})"); sys.exit(1)
if src.exists():
    print("FAIL: 원본 PNG 가 남아 있어 — 같은 그림이 두 번 올라간다"); sys.exit(1)

# 바꿀 도구가 없으면 원본 그대로
src2 = png(tmp / "keep.png", 50, 50)
os.environ["PATH"] = str(tmp / "nothing-here")
out2 = sh.compact_image(src2)
if out2 != src2 or not src2.is_file():
    print(f"FAIL: 도구가 없는데 원본을 잃었어 ({out2})"); sys.exit(1)

# PNG 가 아니면 손대지 않는다
other = tmp / "a.txt"; other.write_text("x")
if sh.compact_image(other) != other:
    print("FAIL: PNG 가 아닌 파일을 건드렸어"); sys.exit(1)
PY
echo "PASS test-discord-preview-compact"
