#!/usr/bin/env bash
# 코덱스(chat-bot) 카테고리의 #자료실·#새-작업 — 클로드 프로젝트 카테고리와 같은 두 채널.
#  - 자료실: 코덱스 방의 share_file 결과가 codex.archiveChannelId 로 간다(지워지면 다시 만든다). 클로드 방은 프로젝트 자료실 그대로.
#  - 새-작업: 세션 없이 버튼 패널만. 버튼 → 모달 → new_from_text(코덱스) → 코덱스 방. 권한은 그 프로젝트 allow. 봇 틱이 패널을 보장.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
export CODEX_HOME="$TMPROOT/real-codex-home-must-not-be-used"
mkdir -p "$MARINA_HOME/accounts/codex-b"; echo '{"tokens":{"x":1}}' > "$MARINA_HOME/accounts/codex-b/auth.json"
msess new proj feat/a --codex --no-start >/dev/null 2>&1 || fail "코덱스 방 만들기 실패"
msess new proj feat/c --no-start >/dev/null 2>&1 || fail "클로드 방 만들기 실패"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - "$FD" "$MARINA_HOME" "$FAKE_CODEX_OUT" <<'PY'
import json, os, sys, time
from pathlib import Path
import marina_session as ms
import marina_discord_bot as mb
fd, mh, cout = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
def log(): return [json.loads(l) for l in (fd / "log.jsonl").read_text().splitlines()]
def cfg(): return json.loads((mh / "discord.json").read_text())
def mk(name, mid="m-sent"):
    return [x for x in log() if x["m"] == "POST" and name in json.dumps(x.get("b"), ensure_ascii=False)]

# ── 자료실 ────────────────────────────────────────────────────────────────────
c = cfg(); cat, arch = c["codex"]["categoryId"], c["codex"].get("archiveChannelId")
arch_posts = [x for x in log() if x["m"] == "POST" and x["b"].get("name") == "자료실"]
check(arch and len(arch_posts) == 2, f"자료실 2개(코덱스+프로젝트): {arch_posts}")
check(arch_posts and arch_posts[0]["b"].get("parent_id") == cat and arch_posts[0]["b"].get("type") == 0, f"코덱스 자료실은 chat-bot 아래: {arch_posts[:1]}")
parch = c["projects"]["proj"].get("archiveChannelId")
check(parch and parch != arch, f"프로젝트 자료실은 따로: {parch} / {arch}")
check(len([x for x in arch_posts if x["b"].get("parent_id") == c["projects"]["proj"]["categoryId"]]) == 1, "클로드 방은 프로젝트 카테고리에 자료실 하나")

def share(slug, name):
    rec = ms.find_session(f"proj/{slug}")
    f = Path(rec["root"]) / name; f.write_text("x")
    os.environ["DISCORD_STATE_DIR"] = rec["stateDir"]
    n = len(log())
    out = ms.chat_tool("share_file", {"path": name})
    return out, [x for x in log()[n:] if x["m"] == "POST" and "payload" in x["b"]]
out, up = share("feat/a", "note.txt")
check("#자료실 에도 올렸어" in out and up and up[-1]["p"] == f"/channels/{arch}/messages", f"코덱스 방 share_file → 코덱스 자료실: {out} {up}")
out, up = share("feat/c", "note.txt")
check(up and up[-1]["p"] == f"/channels/{parch}/messages", f"클로드 방 share_file → 프로젝트 자료실(그대로): {up}")

c = cfg(); c["codex"]["archiveChannelId"] = "999"; (mh / "discord.json").write_text(json.dumps(c))     # 직접 지운 것처럼
out, up = share("feat/a", "note2.txt")      # 자료실 보장은 방 만들 때·봇 틱 — 공유는 있는 것만 쓴다(클로드와 같다)
dc = ms.Discord(ms.read_token(ms.load_config()))
check(ms.ensure_codex_archive(dc, ms.load_config(), cat) != "999" and cfg()["codex"]["archiveChannelId"] != "999", "지워진 코덱스 자료실은 다시 만든다")

# ── #새-작업 패널 ─────────────────────────────────────────────────────────────
n = len(log())
check(ms.ensure_codex_hub() is True, "처음엔 패널을 올린다")
c = cfg(); nch = c["codex"].get("newChannelId")
mk_ch = [x for x in log()[n:] if x["m"] == "POST" and x["b"].get("name") == "새-작업"]
check(nch and len(mk_ch) == 1 and mk_ch[0]["b"].get("parent_id") == cat, f"#새-작업 은 chat-bot 아래: {mk_ch}")
panels = [x for x in log()[n:] if x["m"] == "POST" and x["p"] == f"/channels/{nch}/messages"]
btns = [b for p in panels for row in p["b"].get("components", []) for b in row["components"]]
check(len(panels) == 1 and [b["custom_id"] for b in btns] == ["marina-new:proj"], f"코덱스 방이 있는 프로젝트마다 버튼: {btns}")
check(any(x["m"] == "PUT" and "/pins/" in x["p"] for x in log()[n:]), "패널 pin")
check(c["codex"]["newPanel"]["channelId"] == nch and c["codex"]["newPanel"]["messageId"] == "m-sent", f"패널 저장: {c['codex']}")
check(not any(s.get("channelId") == nch for s in ms.load_sessions()), "세션 없음")
n = len(log()); check(ms.ensure_codex_hub() is False and not [x for x in log()[n:] if x["m"] == "POST"], "있으면 그대로")
(fd / "gone").write_text("m-sent\n"); n = len(log())
check(ms.ensure_codex_hub() is True and len([x for x in log()[n:] if x["m"] == "POST" and "marina-new:proj" in json.dumps(x["b"])]) == 1, "지워졌으면 다시 올림")
(fd / "gone").unlink()
c = cfg(); c["codex"]["newChannelId"] = "888"; (mh / "discord.json").write_text(json.dumps(c))
n = len(log()); ms.ensure_codex_hub()
check(cfg()["codex"]["newChannelId"] != "888" and [x for x in log()[n:] if x["m"] == "POST" and x["b"].get("name") == "새-작업"], "채널이 지워졌으면 다시 만들고 패널도")
c = cfg(); c["projects"]["other"] = {"categoryId": None, "allow": ["U1"]}; c["codex"]["projects"] = ["proj", "other", "ghost"]
(mh / "discord.json").write_text(json.dumps(c)); n = len(log()); ms.ensure_codex_hub()
btns = [b["custom_id"] for x in log()[n:] if x["m"] == "POST" for row in x["b"].get("components", []) for b in row["components"]]
check(btns == ["marina-new:proj", "marina-new:other"], f"codex.projects 우선, 모르는 프로젝트는 뺀다: {btns}")
c = cfg(); del c["codex"]["projects"]; c["codex"]["newPanel"]["messageId"] = "stale"; (mh / "discord.json").write_text(json.dumps(c))

# ── 모달 제출 → 코덱스 방 ─────────────────────────────────────────────────────
nch = cfg()["codex"]["newChannelId"]
ms.suggest_slug = lambda text: "cx-task"
text = "결제 `환불` 버그 @everyone"
check("권한" in mb.new_from_text("proj", "U2", text, nch), "allow 에 없는 사용자 거부")
check(not mb.new_from_text("proj", "U1", text, "777").startswith("열었어"), "새-작업 패널이 아닌 채널 거부")
check("패널" in mb.new_from_text("nope", "U1", text, nch), "패널에 없는 프로젝트 거부")
check("1~500" in mb.new_from_text("proj", "U1", " ", nch), "길이 검사")
n = len(log())
out = mb.new_from_text("proj", "U1", text, nch, "수민")
rec = next((s for s in ms.load_sessions() if s.get("task") == "cx-task"), None)
check(rec and rec.get("kind") == "codex" and out == f"열었어: <#{rec['channelId']}>", f"코덱스 방이 열림: {out} {rec}")
new = log()[n:]
check(any(x["m"] == "POST" and x["p"] == "/guilds/G1/channels" and x["b"].get("parent_id") == cat and x["b"].get("name") == "cx-task" for x in new), "채널은 chat-bot 아래")
posted = [x for x in new if x["m"] == "POST" and rec and x["p"] == f"/channels/{rec['channelId']}/messages"]
check(posted and posted[0]["b"]["content"].startswith("📝 수민") and "@everyone" not in posted[0]["b"]["content"], f"📝 글: {posted}")
for _ in range(60):
    calls = [p for p in cout.iterdir() if (p / "argv").exists() and "cx-task" in (p / "cwd").read_text()] if cout.exists() else []
    if calls: break
    time.sleep(0.1)
last = (calls[0] / "argv").read_bytes().split(b"\0")[-2].decode() if calls else ""
check(rec and f'chat_id="{rec["channelId"]}"' in last and "[Discord 새 작업 버튼]" in last and "환불" in last, f"첫 지시가 codex 인자에: {last!r}")

# ── 봇 틱 ─────────────────────────────────────────────────────────────────────
(fd / "gone").write_text("m-sent\n"); n = len(log())
check(mb.panel_tick(0.0, mb.PANEL_EVERY) == mb.PANEL_EVERY, "간격 지나면 확인")
check(len([x for x in log()[n:] if x["m"] == "POST" and "marina-new:proj" in json.dumps(x["b"]) and "components" in x["b"]]) >= 1, "틱이 코덱스 패널도 보장")
(fd / "gone").unlink()
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-codex-archive-newpanel"
