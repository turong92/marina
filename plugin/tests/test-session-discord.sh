#!/usr/bin/env bash
# marina session — Discord REST: 카테고리·채널 생성/삭제, 카테고리 ID 저장·재사용·재생성, 401/403/429.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord

PYTHONPATH="$SCRIPTS" python3 - "$FD" <<'PY'
import json, sys
from pathlib import Path
import marina_session as ms
fd = Path(sys.argv[1])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def posts(): return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines() if '"POST"' in l]

cfg = ms.load_config()
dc = ms.Discord("test-token")

cat = ms.ensure_category(dc, cfg, "proj")
check(posts()[-1]["b"] == {"name": "PROJ", "type": 4}, f"카테고리 생성 요청: {posts()[-1]}")
check(ms.load_config()["projects"]["proj"]["categoryId"] == cat, "categoryId 를 discord.json 에 저장")
n = len(posts())
check(ms.ensure_category(dc, ms.load_config(), "proj") == cat and len(posts()) == n, "두 번째는 재사용(POST 없음)")

ch = dc.create_text_channel("G1", "feat-one", cat)
check(posts()[-1]["b"] == {"name": "feat-one", "type": 0, "parent_id": cat}, "카테고리 아래 텍스트 채널")
check(ms.find_text_channel(dc, "G1", cat, "feat-one") == ch, "이름으로 채널 찾기")
check(ms.find_text_channel(dc, "G1", cat, "nope") is None, "없는 채널 → None")
check(ch in ms.channel_ids(dc, "G1"), "channel_ids")

dc.delete_channel(ch)
check(ch not in ms.channel_ids(dc, "G1"), "채널 삭제")
try:
    dc.delete_channel(ch); check(False, "없는 채널 삭제는 DiscordError")
except ms.DiscordError as exc:
    check(exc.code == 404, f"없는 채널 삭제 → 404: {exc.code}")

dc.delete_channel(cat)                                   # Discord 에서 카테고리를 직접 지운 상황
cat2 = ms.ensure_category(dc, ms.load_config(), "proj")
check(cat2 != cat and ms.load_config()["projects"]["proj"]["categoryId"] == cat2, "사라진 카테고리 → 새로 만들고 설정 갱신")

try:
    ms.Discord("wrong").list_channels("G1"); check(False, "잘못된 토큰은 실패해야")
except ms.DiscordError as exc:
    check(exc.code == 401 and "401" in str(exc), f"401 안내: {exc}")

(fd / "fail_post").write_text("403")
try:
    dc.create_text_channel("G1", "x", cat2); check(False, "403 은 실패해야")
except ms.DiscordError as exc:
    check(exc.code == 403 and "채널 관리" in str(exc), f"403 안내: {exc}")
(fd / "fail_post").write_text("429once")
check(bool(dc.create_text_channel("G1", "after-429", cat2)), "429 한 번 뒤 재시도 성공")

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-session-discord"
