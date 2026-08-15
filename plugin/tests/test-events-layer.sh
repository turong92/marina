#!/usr/bin/env bash
# 변화 감지층 — 마리나가 "무엇이 바뀌었나"를 아는 단 하나의 근거.
#
# 계약: ① 첫 스냅샷은 기준선일 뿐 사건이 아니다(데몬 부팅 때 알림 폭탄 금지) ② 사람을 불러야
# 하는 일(question·idle·blocked·service)과 화면만 갱신하면 되는 일(message)을 구분한다
# ③ 느린 구독자가 전체를 붙잡지 않는다 ④ 훅이 찌르면 주기를 기다리지 않는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import threading
import time

import marina_events as ev

def state(sessions):
    return {"sessions": [{"kind": "agent", "key": k, "root": "/wt", "source": "claude", "sid": k,
                          "title": "T", **v} for k, v in sessions.items()]}

def snap(sessions=None, services=None):
    return {"sessions": ev._session_marks(state(sessions or {})),
            "services": ev._service_marks(services or [])}

# ① 첫 스냅샷은 사건이 아니다 — 이게 없으면 데몬이 뜰 때 살아있는 세션 수만큼 알림이 쏟아진다.
first = snap({"a": {"status": "working", "ts": 10}})
assert ev.diff_marks(None, first) == [], "첫 스냅샷에서 사건이 나왔다"

# ② 작업 끝남 → idle 사건(사람을 부른다).
done = ev.diff_marks(first, snap({"a": {"status": "idle", "ts": 10}}))
assert [e["kind"] for e in done] == ["idle"], done
assert done[0]["session"] == "a" and done[0]["sid"] == "a"

# ③ 질문이 생기면 question. 같은 질문이 계속 있어도 **한 번만** — 폴마다 알리면 진동 지옥이 된다.
asked = snap({"a": {"status": "blocked", "ts": 10, "pendingQuestion": {"token": "q1"}}})
kinds = [e["kind"] for e in ev.diff_marks(first, asked)]
assert "question" in kinds, kinds
assert ev.diff_marks(asked, asked) == [], "같은 질문에 사건이 또 났다"
# 다음 질문(토큰이 다름)은 새 사건이다.
again = snap({"a": {"status": "blocked", "ts": 10, "pendingQuestion": {"token": "q2"}}})
assert "question" in [e["kind"] for e in ev.diff_marks(asked, again)]

# ④ 대화에 새 줄이 붙으면 message — 화면 갱신용이라 알림 대상이 아니다.
typed = ev.diff_marks(first, snap({"a": {"status": "working", "ts": 20}}))
assert [e["kind"] for e in typed] == ["message"], typed
assert "message" not in ev.ALERT_KINDS, "message 로 알림을 보내면 글자마다 진동한다"

# ⑤ 서비스: starting→running 은 준비 완료, error 는 실패.
svc = lambda s: [{"root": "/wt", "alias": "wt", "services": [{"service": "web", "svcState": s}]}]
ready = ev.diff_marks(snap(services=svc("starting")), snap(services=svc("running")))
assert ready and ready[0]["kind"] == "service" and ready[0]["event"] == "ready", ready
failed = ev.diff_marks(snap(services=svc("running")), snap(services=svc("error")))
assert failed and failed[0]["event"] == "failed", failed
assert ev.diff_marks(snap(services=svc("running")), snap(services=svc("running"))) == []

# ⑥ 새 세션이 등장한 것만으론 사람을 부르지 않는다(목록만 갱신). 단 뜨자마자 질문 중이면 부른다.
appeared = ev.diff_marks(first, snap({"a": {"status": "working", "ts": 10},
                                      "b": {"status": "working", "ts": 5}}))
assert appeared == [], appeared
born_asking = ev.diff_marks(first, snap({"a": {"status": "working", "ts": 10},
                                         "b": {"status": "blocked", "ts": 5,
                                               "pendingQuestion": {"token": "q9"}}}))
assert [e["kind"] for e in born_asking] == ["question"], born_asking

print("ok 차이 계산: 기준선·중복 억제·알림/갱신 구분")

# ⑦ 버스: 구독자마다 제 통을 갖고, 넘치면 **오래된 것부터** 버린다(최신이 늘 더 쓸모 있다).
bus = ev.EventBus(queue_max=3)
one, two = bus.subscribe(), bus.subscribe()
bus.publish([{"kind": "message", "n": i} for i in range(5)])
drained = bus.wait(one, 0.01)
assert [e["n"] for e in drained] == [2, 3, 4], drained
assert bus.wait(one, 0.01) == [], "가져간 사건이 또 나온다"
assert [e["n"] for e in bus.wait(two, 0.01)] == [2, 3, 4], "구독자끼리 통을 공유하면 서로 훔친다"
bus.unsubscribe(one)
bus.publish([{"kind": "idle"}])
assert bus.subscriber_count() == 1

# ⑧ 사건이 오면 기다리던 구독자가 깬다 — 이게 폴링과의 차이 전부다.
bus.wait(two, 0.01)      # ⑦에서 남은 것 비우고 시작
woke = []
def waiter():
    woke.extend(bus.wait(two, 2.0))
thread = threading.Thread(target=waiter, daemon=True)
thread.start()
time.sleep(0.05)
bus.publish([{"kind": "question"}])
thread.join(1.5)
assert [e["kind"] for e in woke] == ["question"], f"사건이 나도 안 깼다: {woke}"

print("ok 버스: 구독자별 통·유한 큐·즉시 깨움")

# ⑨ 감시자: 스냅샷이 실패해도 죽지 않는다(감시가 멈추면 화면 전체가 멈춘 것처럼 보인다).
states = [snap({"a": {"status": "working", "ts": 1}}),
          snap({"a": {"status": "idle", "ts": 1}})]
calls = {"n": 0}
def flaky():
    calls["n"] += 1
    if calls["n"] == 2:
        raise RuntimeError("일시적 실패")
    return states[min(calls["n"] - 1, len(states) - 1)]

watcher = ev.ChangeWatcher(flaky, ev.EventBus(), interval=0.01)
assert watcher.tick() == []            # 기준선
assert watcher.tick() == []            # 예외 — 조용히 넘어간다
after = watcher.tick()
assert [e["kind"] for e in after] == ["idle"], after
assert calls["n"] == 3

# ⑩ 훅이 찌르면 주기를 기다리지 않는다.
slow = ev.ChangeWatcher(lambda: snap(), ev.EventBus(), interval=30)
started = time.time()
thread = threading.Thread(target=slow.run_forever, daemon=True)
thread.start()
time.sleep(0.05)
slow.poke()
time.sleep(0.3)
assert time.time() - started < 5, "찔러도 주기를 다 기다렸다"

# ⑪ SSE 프레임은 한 줄이어야 한다 — 개행이 새면 프로토콜이 깨진다.
frame = ev.sse_frame({"kind": "message", "title": "여러\n줄\n제목"})
assert frame.endswith(b"\n\n") and frame.count(b"\n") == 2, frame

print("ok 감시자: 실패 내성·즉시 깨움·프레임 안전")
PY

echo "PASS test-events-layer"
