#!/usr/bin/env bash
# 대화 안 이미지(붙여넣은 스크린샷 · Read 한 png · 캡처)를 모바일에서 볼 수 있어야 한다.
# 트랜스크립트엔 base64 로 통째 박혀 있어서(장당 수 MB) 타임라인엔 **참조(ref)만** 싣고,
# 바이트는 요청이 올 때 그 줄만 다시 읽어 준다. 이 테스트가 그 계약을 잠근다:
#   ① 타임라인이 이미지 ref 를 붙인다(메시지 · tool_result 둘 다) — base64 는 절대 안 싣는다
#   ② ref 로 원본 바이트를 정확히 되찾는다 + 잘못된 ref 는 거부한다
#   ③ 모아보기 목록이 세션 전체 이미지를 최신순으로 준다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import base64
import json
import tempfile
from pathlib import Path

import marina_sessions as ms

# 1x1 png / 1x1 gif — 실제 바이트가 왕복하는지 보려면 서로 달라야 한다.
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
GIF = base64.b64decode("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")

tmp = Path(tempfile.mkdtemp())
path = tmp / "sess.jsonl"

rows = [
    # ① 사용자가 텍스트 + 스크린샷을 같이 붙여넣은 턴
    {"type": "user", "timestamp": "2026-07-29T00:00:01Z", "message": {"role": "user", "content": [
        {"type": "text", "text": "이거 봐줘"},
        {"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                     "data": base64.b64encode(PNG).decode()}},
    ]}},
    # ② 도구 호출 + 그 결과가 그림인 경우(Read 한 png · 브라우저 캡처)
    {"type": "assistant", "timestamp": "2026-07-29T00:00:02Z", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": "call-1", "name": "Read", "input": {"file_path": "/tmp/shot.gif"}},
    ]}},
    {"type": "user", "timestamp": "2026-07-29T00:00:03Z", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "call-1", "content": [
            {"type": "text", "text": "읽었어요"},
            {"type": "image", "source": {"type": "base64", "media_type": "image/gif",
                                         "data": base64.b64encode(GIF).decode()}},
        ]},
    ]}},
    # ③ 텍스트 없이 이미지만 있는 턴 — 말풍선이 통째로 사라지면 안 된다
    {"type": "user", "timestamp": "2026-07-29T00:00:04Z", "message": {"role": "user", "content": [
        {"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                     "data": base64.b64encode(PNG).decode()}},
    ]}},
    # ④ base64 가 아닌 소스 — 우리가 되읽어 줄 수 없으니 참조를 만들지 않는다
    {"type": "user", "timestamp": "2026-07-29T00:00:05Z", "message": {"role": "user", "content": [
        {"type": "text", "text": "링크 이미지"},
        {"type": "image", "source": {"type": "url", "url": "https://example.invalid/a.png"}},
    ]}},
]
path.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows), encoding="utf-8")

# ---------- ① 타임라인: ref 만, base64 는 없다 ----------
page = ms._transcript_page(path, "claude", None, 50)
timeline = page["timeline"]
raw = json.dumps(timeline, ensure_ascii=False)
assert base64.b64encode(PNG).decode()[:32] not in raw, "타임라인에 base64 원본이 새면 안 됨"

messages = [it for it in timeline if it.get("kind") == "message"]
with_images = [it for it in timeline if it.get("images")]
assert len(with_images) == 3, [it.get("id") for it in with_images]

paired = next(it for it in messages if it.get("text", "").startswith("이거 봐줘"))
assert len(paired["images"]) == 1 and paired["images"][0]["mediaType"] == "image/png", paired
assert paired["images"][0]["bytes"] == len(PNG), paired["images"][0]

image_only = next(it for it in messages if it.get("id", "").endswith(":img"))
assert image_only["text"] == "" and len(image_only["images"]) == 1, image_only

activity = next(it for it in timeline if it.get("kind") == "activity")
assert activity["images"] and activity["images"][0]["mediaType"] == "image/gif", activity
assert activity["images"][0]["ref"].count("-") == 2, "tool_result 안 이미지는 중첩 ref"

url_row = [it for it in messages if it.get("text") == "링크 이미지"]
assert url_row and not url_row[0].get("images"), "base64 아닌 소스엔 ref 를 만들지 않는다"

# ---------- ② ref → 원본 바이트 ----------
ms.agent_transcript_path = lambda root, source, sid: path      # 실 경로 해석 우회
data, media = ms.agent_transcript_image(Path("/tmp"), "claude", "sess-1234", paired["images"][0]["ref"])
assert data == PNG and media == "image/png", (len(data), media)
data, media = ms.agent_transcript_image(Path("/tmp"), "claude", "sess-1234", activity["images"][0]["ref"])
assert data == GIF and media == "image/gif", (len(data), media)

for bad in ("", "abc", "../../etc/passwd", "1-2-3-4", "999999999-0", "0-99"):
    try:
        ms.agent_transcript_image(Path("/tmp"), "claude", "sess-1234", bad)
    except ValueError:
        pass
    else:
        raise AssertionError(f"expected rejection for ref {bad!r}")

try:
    ms.agent_transcript_image(Path("/tmp"), "codex", "sess-1234", paired["images"][0]["ref"])
except ValueError:
    pass
else:
    raise AssertionError("codex 는 아직 이미지 소스가 없다 — 거부해야 함")

# ---------- ③ 모아보기 ----------
gallery = ms.agent_transcript_images(Path("/tmp"), "claude", "sess-1234")
assert gallery["total"] == 3, gallery
refs = [img["ref"] for img in gallery["images"]]
assert len(refs) == 3 and len(set(refs)) == 3, refs
# 최신이 앞 — 마지막 줄(이미지 전용 턴)이 첫 칸
assert gallery["images"][0]["origin"] == "message" and gallery["images"][0]["ts"].endswith("00:04Z"), gallery["images"][0]
assert any(img["origin"] == "tool" for img in gallery["images"]), gallery["images"]
first, _ = ms.agent_transcript_image(Path("/tmp"), "claude", "sess-1234", refs[0])
assert first == PNG, len(first)

assert ms.agent_transcript_images(Path("/tmp"), "codex", "sess-1234")["images"] == []

print("PASS part A (transcript images): 타임라인 ref-only + 원본 왕복 + 잘못된 ref 거부 + 모아보기 최신순")
PY

# ---------- Part B: 모바일 렌더가 ref 를 썸네일로 그린다 ----------
PYTHONPATH="$SCR" python3 - <<'PY'
from marina_mobile import render_mobile_html

html = render_mobile_html()
required = [
    'id="galleryBtn"',            # 대화 헤더의 모아보기 버튼
    'id="gallerySheet"',          # 모아보기 시트
    'id="imageViewer"',           # 전체보기
    "transcriptImageUrl",         # ref → /mobile/api/transcript-image
    "renderTimelineImages",       # 말풍선/활동 카드 썸네일
    "data-image-ref",             # 탭 → 전체보기 위임 훅
    "/mobile/api/images",         # 모아보기 목록
]
for needle in required:
    assert needle in html, needle
# 썸네일은 말풍선과 활동 카드 **둘 다**에 붙어야 한다(스크린샷 결과는 활동 카드 안에 있다).
assert html.count("renderTimelineImages(") >= 3, html.count("renderTimelineImages(")
print("PASS part B (mobile render): 썸네일 + 모아보기 + 전체보기 배선")
PY

echo "PASS test-transcript-images"
