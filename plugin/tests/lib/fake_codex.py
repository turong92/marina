#!/usr/bin/env python3
"""테스트용 가짜 코덱스 TUI — tmux 안에서 돈다. 실측(스펙 "실측 결과" S2·S3)의 화면 모양을 흉내 낸다.
사용: fake_codex.py <ctl 폴더> [codex 인자…]
- 입력창 줄 = ESC[1m›ESC[0m + 입력 중인 글(비었으면 흐린 안내문). 붙여넣기(ESC[200~…ESC[201~)는 입력창에 쌓고 Enter 가 보낸다.
- 보낸 글은 $MARINA_CODEX_SESSIONS/2026/10/21/rollout-…-<sid>.jsonl 에 response_item + user_message 두 줄로 적는다(실측 모양).
- <ctl>/swallow 가 있으면 Enter 에 글을 버린다(기록 안 함). <ctl>/busy 가 있으면 'Working (… esc to interrupt)' 줄을 그리고,
  보낸 글을 기록하지 않고 'Messages to be submitted after next tool call' 목록에만 올린다(바쁠 때 steer 모양).
- 받은 키(Esc 등)는 <ctl>/keys 에 한 줄씩 적는다."""
import codecs
import json
import os
import sys
import termios
import time
import tty
import uuid
from pathlib import Path

ctl = Path(sys.argv[1])
args = sys.argv[2:]
sid = args[args.index("resume") + 1] if "resume" in args else str(uuid.uuid4())
root = Path(os.environ.get("MARINA_CODEX_SESSIONS") or "/nonexistent") / "2026" / "10" / "21"
root.mkdir(parents=True, exist_ok=True)
rollout = root / f"rollout-2026-10-21T10-00-00-{sid}.jsonl"
if not rollout.exists():
    meta = {"timestamp": "2026-10-21T10:00:00.000Z", "type": "session_meta",
            "payload": {"id": sid, "session_id": sid, "cwd": os.path.realpath(os.getcwd()), "base_instructions": {"text": "x" * 100}}}
    rollout.write_text(json.dumps(meta) + "\n")


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())


def append_user(text):
    rows = [{"timestamp": now_iso(), "type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": text}]}},
            {"timestamp": now_iso(), "type": "event_msg", "payload": {"type": "user_message", "message": text}}]
    with rollout.open("a", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")


buf, queue = "", []


def draw():
    out = ["\x1b[2J\x1b[H", "OpenAI Codex (fake)\r\n"]
    if (ctl / "busy").exists():
        out.append("◦ Working (3s • esc to interrupt)\r\n")
    if queue:
        out.append("• Messages to be submitted after next tool call (press esc to interrupt and send immediately)\r\n")
        out += [f"  ↳ {q}\r\n" for q in queue]
    shown = buf.replace("\n", "\r\n  ")
    if len(buf) > 1000:
        shown = f"[Pasted Content {len(buf)} chars]"
    out.append("\x1b[1m›\x1b[0m " + (shown if buf else "\x1b[2mUse /skills to list available skills\x1b[0m") + "\r\n")
    sys.stdout.write("".join(out))
    sys.stdout.flush()


fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
sys.stdout.write("\x1b[?2004h")        # bracketed paste on
draw()
pasting, esc = False, ""
dec = codecs.getincrementaldecoder("utf-8")("ignore")
try:
    while True:
        raw = os.read(fd, 1)
        if not raw:
            break
        ch = dec.decode(raw)            # 한글은 여러 바이트 — 다 모일 때까지 ""
        if not ch:
            continue
        if esc or ch == "\x1b":
            esc += ch
            if esc == "\x1b[200~":
                pasting, esc = True, ""
            elif esc == "\x1b[201~":
                pasting, esc = False, ""
            elif len(esc) >= 6 or (len(esc) == 2 and esc[1] not in "["):
                with (ctl / "keys").open("a") as fh:
                    fh.write("Escape\n" if esc == "\x1b" or len(esc) == 2 else "other\n")
                esc = ""
            continue
        if ch in ("\r", "\n") and not pasting:
            if buf.strip():
                text, buf = buf, ""
                if (ctl / "swallow").exists():
                    pass
                elif (ctl / "busy").exists():
                    queue.append(text.replace("\n", " "))
                else:
                    append_user(text)
            draw()
            continue
        buf += "\n" if ch in ("\r", "\n") else ch
        draw()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
