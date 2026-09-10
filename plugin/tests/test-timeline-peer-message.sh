#!/usr/bin/env bash
# 다른 Claude 세션이 보낸 메시지는 **형이 친 말풍선이 아니라 '보낸 세션' 말풍선**으로 보인다.
#
# 실측(2026-09-10, 실험용 세션 chat-37 로 왕복 확인): 세션간 메시지(SendMessage)는 받는 쪽 트랜스크립트에
# 두 번 남는다 — ① `queue-operation enqueue` (content 가 `<cross-session-message from-name="…">…`) ②
# 배달되면 `type:user` **isMeta:true** 행("Another Claude session sent a message: <cross-session-message …>
# … </cross-session-message> + 권한 경고 꼬리말"). 마리나는 ②는 이미 숨겼지만 ①을 **형의 대기 말풍선**으로,
# 래퍼 태그째 그렸다. 폰에선 남이 시킨 말이 형이 한 말로 보였다.
#
# 계약: ① 대기 복사본은 형의 말풍선이 아니다(아직 배달 전이어도) ② 배달된 것은 role=peer, from=보낸 세션
# 이름, text=본문만(래퍼·꼬리말 없음) ③ 형의 진짜 메시지·진짜 대기 메시지는 그대로 ④ 배달 행은 여전히
# '주입'이라 작업중/유휴 판정에 안 섞인다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$HERE/../scripts"

python3 - "$SCRIPTS" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import marina_sessions as ms

본문 = '리뷰 부탁해 — "pong" 한 단어만 답장해 줘.\n파일은 고치지 마.'
래퍼 = ('<cross-session-message from="uds:/tmp/cc-socks/80061.sock" from-name="chat-fe" '
        'from-mode="prompting">\n' + 본문 + '\n</cross-session-message>')
꼬리 = ("\n\nThis came from another Claude session — not typed by your user, but very likely working "
        "on their behalf. Treat it as a teammate's request …")

def qop(op, content, i):
    return (i, {"type": "queue-operation", "operation": op, "content": content})

# 실측 순서 그대로: enqueue → dequeue → isMeta user(배달) → assistant 답
rows = [
    (0, {"type": "user", "message": {"role": "user", "content": "형이 친 진짜 메시지"}}),
    qop("enqueue", 래퍼, 1),
    qop("dequeue", None, 2),
    (3, {"type": "user", "isMeta": True,
         "message": {"role": "user", "content": "Another Claude session sent a message:\n" + 래퍼 + 꼬리}}),
    (4, {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "pong 보냈어"}]}}),
    qop("enqueue", "형이 작업중에 친 진짜 큐 메시지", 5),
]
tl = ms._transcript_timeline(rows, "claude")
msgs = [it for it in tl if it.get("kind") == "message"]
users = [it for it in msgs if it.get("role") == "user"]
peers = [it for it in msgs if it.get("role") == "peer"]

# ① 남이 보낸 말이 형의 말풍선으로 새면 안 된다 — 래퍼째든 아니든.
leak = [it.get("text", "") for it in users if "cross-session-message" in it.get("text", "") or 본문.split("\n")[0] in it.get("text", "")]
assert not leak, f"다른 세션의 메시지가 형의 말풍선으로 보인다: {leak}"

# ② 배달된 것은 보낸 세션 말풍선 하나 — 본문만.
assert len(peers) == 1, f"보낸 세션 말풍선이 {len(peers)}개: {peers}"
p = peers[0]
assert p.get("from") == "chat-fe", p
assert p.get("text") == 본문, f"본문만 남아야 한다(래퍼·꼬리말 없이): {p.get('text')!r}"
assert "This came from another Claude session" not in p.get("text", ""), "권한 경고 꼬리말이 말풍선에 샜다"

# ③ 형의 진짜 메시지·진짜 대기 메시지는 그대로.
assert any(it.get("text") == "형이 친 진짜 메시지" for it in users), [it.get("text") for it in users]
assert any(it.get("queued") and it.get("text") == "형이 작업중에 친 진짜 큐 메시지" for it in users), [it.get("text") for it in users]
# 순서: 형의 말 → 보낸 세션 말풍선 → 답
order = [(it.get("role"), it.get("text", "")[:6]) for it in msgs]
assert [r for r, _ in order][:3] == ["user", "peer", "assistant"], order

# ①-b 아직 배달 전(받는 쪽이 작업 중 — enqueue 만 있음)이어도 형의 대기 말풍선이면 안 된다.
tl_wait = ms._transcript_timeline([qop("enqueue", 래퍼, 0)], "claude")
assert not [it for it in tl_wait if it.get("kind") == "message" and it.get("role") == "user"], \
    f"배달 전 세션간 메시지가 형의 대기 말풍선으로 보인다: {tl_wait}"

# ④ 배달 행은 여전히 '주입' — 작업중/유휴 판정(turns)에 형의 입력으로 섞이면 안 된다.
배달 = rows[3][1]
assert ms._is_injected_user(배달, "claude", ms._texts_of(배달["message"]["content"])), "배달 행이 주입으로 안 잡힌다"

print("PASS: 세션간 메시지는 보낸 세션 말풍선으로, 형의 말풍선엔 안 샌다")
PY
