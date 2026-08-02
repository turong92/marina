#!/usr/bin/env bash
# "내가 만든 파일" 모아보기 — 대화 이미지(test-transcript-images)와는 **다른 축**이다.
# 만들기만 한 파일은 트랜스크립트에 내용이 안 남고 경로만 남는다(실측: 세션 하나에 Write 2 + Edit 44
# 인데 대화 이미지는 0장 → 갤러리로는 아무것도 안 잡힘). 그래서 근거는 도구 호출의 file_path 다.
# 파일 원본 서빙은 새 노출면이라 여기서 단단히 잠근다:
#   ① 목록: Write=새로만듦 / Edit=수정, 손댄 횟수, 워크트리 밖 경로는 아예 제외, 최근 것이 앞
#   ② 전체 파일 스캔(끝 256KB 만 읽는 _json_objects 로는 긴 세션을 놓친다)
#   ③ 서빙: 워크트리 안만 · 심링크/상대/절대/홈 탈출 거부 · 이미지 외 전부 text/plain · svg 제외
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import json
import os
import tempfile
from pathlib import Path

import marina_sessions as ms

tmp = Path(tempfile.mkdtemp())
root = tmp / "wt"
(root / "sub").mkdir(parents=True)
(root / "sub" / "a.txt").write_text("inside", encoding="utf-8")
(root / "page.html").write_text("<script>alert(1)</script>", encoding="utf-8")
(root / "pic.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"x" * 40)
(root / "made.py").write_text("print(1)\n", encoding="utf-8")
outside = tmp / "secret.txt"
outside.write_text("SECRET", encoding="utf-8")
os.symlink(outside, root / "escape.txt")

# ---------- 트랜스크립트 픽스처 ----------
def tool_use(name, **inp):
    return {"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": f"c-{name}-{len(inp)}", "name": name, "input": inp}]}}

rows = [
    tool_use("Write", file_path=str(root / "made.py"), content="print(1)"),
    tool_use("Edit", file_path=str(root / "sub" / "a.txt"), old_string="a", new_string="b"),
    tool_use("Edit", file_path=str(root / "sub" / "a.txt"), old_string="b", new_string="c"),
    tool_use("Read", file_path=str(root / "pic.png")),                 # 읽기는 '만든 파일' 아님
    tool_use("Edit", file_path=str(outside)),                          # 워크트리 밖 — 제외돼야 함
    tool_use("Write", file_path=str(root / "gone.txt"), content="x"),  # 만들었지만 지금은 없음
    tool_use("Bash", command="echo hi"),                               # 파일 도구 아님
]
# 긴 세션을 흉내내 앞쪽 기록이 끝 256KB 밖으로 밀려나게 한다 — 전체 스캔이 아니면 여기서 놓친다.
filler = {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "x" * 900}]}}
path = tmp / "sess.jsonl"
with path.open("w", encoding="utf-8") as fh:
    fh.write(json.dumps(rows[0], ensure_ascii=False) + "\n")           # 맨 앞 = 가장 놓치기 쉬운 자리
    for _ in range(400):
        fh.write(json.dumps(filler, ensure_ascii=False) + "\n")        # ≈360KB
    for row in rows[1:]:
        fh.write(json.dumps(row, ensure_ascii=False) + "\n")
assert path.stat().st_size > 256 * 1024, path.stat().st_size

ms.agent_transcript_path = lambda r, s, i: path                        # 실 경로 해석 우회

# ---------- ① 목록 ----------
listing = ms.agent_session_files(root, "claude", "sess-1234")
by_rel = {f["relPath"]: f for f in listing["files"]}
assert set(by_rel) == {"made.py", "sub/a.txt", "gone.txt"}, sorted(by_rel)
assert by_rel["made.py"]["action"] == "created", by_rel["made.py"]
assert by_rel["sub/a.txt"]["action"] == "edited" and by_rel["sub/a.txt"]["touches"] == 2, by_rel["sub/a.txt"]
assert by_rel["gone.txt"]["exists"] is False and by_rel["gone.txt"]["servable"] is False, by_rel["gone.txt"]
assert by_rel["made.py"]["exists"] is True and by_rel["made.py"]["servable"] is True, by_rel["made.py"]
assert not by_rel["made.py"]["isImage"], by_rel["made.py"]
# Read 한 이미지는 '만든 파일'이 아니다(그건 대화 이미지 축)
assert "pic.png" not in by_rel, by_rel
# 워크트리 밖은 목록에도 없다
assert not any("secret" in rel for rel in by_rel), by_rel
# 최근에 처음 손댄 것이 앞 — 맨 앞 줄의 made.py 가 꼴찌여야 한다
assert listing["files"][-1]["relPath"] == "made.py", [f["relPath"] for f in listing["files"]]

# ---------- ③ 서빙 보안 ----------
data, media = ms.agent_session_file_bytes(root, str(root / "sub" / "a.txt"))
assert data == b"inside" and media.startswith("text/plain"), (data, media)
_, media = ms.agent_session_file_bytes(root, str(root / "page.html"))
assert media.startswith("text/plain"), f"HTML 을 그대로 서빙하면 대시보드 오리진 XSS: {media}"
_, media = ms.agent_session_file_bytes(root, str(root / "pic.png"))
assert media == "image/png", media
_, media = ms.agent_session_file_bytes(root, "sub/a.txt")               # 상대경로는 root 기준
assert media.startswith("text/plain"), media

for bad in (str(outside), "../secret.txt", "sub/../../secret.txt", str(root / "escape.txt"),
            "/etc/passwd", "~/.ssh/id_rsa", ""):
    try:
        ms.agent_session_file_bytes(root, bad)
    except ValueError:
        pass
    else:
        raise AssertionError(f"탈출 허용됨: {bad!r}")

assert ".svg" not in ms._SESSION_FILE_IMAGE_TYPES, "svg 는 스크립트를 품을 수 있어 이미지 취급 금지"
assert ms.session_file_in_root(root, str(root / "sub")) == (root / "sub").resolve()
assert ms.session_file_in_root(root, str(outside)) is None

print("PASS part A: 목록(created/edited·횟수·밖 제외·없는 파일) + 전체스캔(>256KB) + 서빙 보안(탈출 7종 거부·HTML→text/plain·svg 제외)")
PY

# ---------- 모바일 UI 배선 ----------
PYTHONPATH="$SCR" python3 - <<'PY'
from marina_mobile import render_mobile_html
html = render_mobile_html()
for needle in ('data-gallery-tab="images"', 'data-gallery-tab="files"', 'id="galleryFiles"',
               "/mobile/api/session-files", "sessionFileUrl", "data-file-path", "loadGalleryFiles"):
    assert needle in html, needle
# 이미지가 0장일 때 '만든 파일' 탭으로 안내해야 한다 — 안 그러면 형이 또 "안 보인다"가 된다.
assert "'만든 파일' 탭에 있어요" in html, "빈 갤러리에서 다른 축으로 안내가 없음"

# 파일을 누르면 **앱 안 뷰어**로 열어야 한다 — 새 탭을 띄우면 모아보기 흐름이 끊기고 폰에 탭이 쌓인다.
assert "window.open(sessionFileUrl" not in html, "파일을 새 탭으로 띄우면 안 된다"
assert "openTextViewer(sessionFileUrl(path), name)" in html, "텍스트 파일이 앱 안 뷰어로 안 열림"
assert "openImageViewer(sessionFileUrl(path), name)" in html, "이미지 파일이 앱 안 뷰어로 안 열림"
for needle in ('id="viewerText"', 'id="viewerName"', "VIEWER_TEXT_MAX", 'data-file-name'):
    assert needle in html, needle
# 본문 클릭이 뷰어를 닫으면 텍스트를 스크롤/선택할 수 없다 — 배경만 닫는다.
assert "event.target === imageViewer || event.target === viewerBar" in html, \
    "뷰어 본문 클릭이 닫히면 텍스트를 읽을 수 없다"
# Esc 는 뷰어가 위에 있으면 뷰어부터 닫는다(드로어보다 우선).
assert "if (viewerOpen()) { closeImageViewer(); return; }" in html, "Esc 가 뷰어를 먼저 닫지 않음"

# ＋CC/＋CX 는 좁은 드로어에서 두 줄로 접히면 안 된다 — 전역 button{width:100%} 를 덮어야 한다.
import re
launch = re.search(r"\.wtLaunchBtn \{([^}]*)\}", html).group(1)
for prop in ("width: auto", "white-space: nowrap", "flex: none"):
    assert prop in launch, f"＋CC 버튼에 {prop} 가 없어 좁은 폭에서 접힌다: {launch.strip()}"

print("PASS part B: 탭 2개 + 앱 안 뷰어(텍스트/이미지·배경만 닫힘·Esc 우선) + ＋CC 줄바꿈 방지 + 빈 상태 안내")
PY

echo "PASS test-session-files"
