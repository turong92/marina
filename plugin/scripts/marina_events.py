"""무엇이 바뀌었나 — 마리나의 단일 변화 감지층.

**왜 필요한가.** 지금까지 화면은 3초마다 "지금 어때?"를 물었다. 그래서 ① 폰이 답을 받기까지
최대 3초가 늦고 ② 아무 일 없어도 계속 왕복하고 ③ "방금 바뀌었다"를 아는 곳이 없어 알림을
보낼 근거가 없었다. 이 모듈이 그 하나뿐인 근거가 된다.

**어떻게 아는가.** 두 가지를 합친다.
  · 훅이 찌르면 즉시(poke) — 질문·턴 종료·막힘은 이미 훅이 잡고 있으니 지연이 0이다.
  · 못 미더운 나머지는 짧은 주기로 직접 확인 — 훅이 없는 세션(밖에서 띄운 CLI), 서비스 상태,
    훅이 유실된 경우까지 덮는 안전망. 상태 계산이 0.08초로 싸졌기에 가능해진 선택이다.
파일 감시(fsevents)를 쓰지 않은 이유: 외부 의존성이 필요하고, 파일 교체·새 세션 등장에서
조용히 놓치는 실패가 생긴다 — 우리가 방금 캐시에서 잡아낸 바로 그 부류다.

**무엇을 알리는가.** 사람을 불러야 하는 일(question·idle·blocked·service)과 화면만 따라가면
되는 일(message)을 구분한다. 이 구분이 곧 알림을 보낼지의 기준이라, 규칙이 흩어지지 않는다.

**이 모듈은 누가 듣는지 모른다.** SSE 도 푸시도 그냥 손님이다. 그래서 따로 테스트된다.
"""
from __future__ import annotations

import json
import threading
import time
from typing import Any, Callable, Iterable

# 사람을 불러야 하는 사건 — 알림 대상. message 는 화면 갱신 전용이라 여기 없다.
ALERT_KINDS = ("question", "idle", "blocked", "service")
WATCH_INTERVAL_S = 0.3          # 훅이 못 잡는 변화의 안전망 주기
POKE_DEBOUNCE_S = 0.05          # 훅 여러 개가 동시에 찔러도 한 바퀴만


def _session_marks(state: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """상태에서 **비교할 것만** 뽑는다. 전체를 비교하면 preview 한 글자에도 사건이 터진다."""
    marks: dict[str, dict[str, Any]] = {}
    for session in state.get("sessions") or []:
        key = str(session.get("key") or "")
        if not key or session.get("kind") != "agent":
            continue
        question = session.get("pendingQuestion") if isinstance(session.get("pendingQuestion"), dict) else None
        marks[key] = {
            "status": str(session.get("status") or ""),
            "questionToken": str((question or {}).get("token") or (question or {}).get("toolUseId") or ""),
            "ts": float(session.get("ts") or 0),
            "root": str(session.get("root") or ""),
            "source": str(session.get("source") or ""),
            "sid": str(session.get("sid") or ""),
            "title": str(session.get("title") or ""),
        }
    return marks


def _service_marks(sessions: Iterable[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    marks: dict[str, dict[str, Any]] = {}
    for session in sessions or []:
        root = str(session.get("root") or "")
        for service in session.get("services") or []:
            name = str(service.get("service") or "")
            if not name:
                continue
            marks[f"{root}\n{name}"] = {
                "state": str(service.get("svcState") or service.get("state") or ""),
                "root": root,
                "service": name,
                "alias": str(session.get("alias") or session.get("id") or root),
            }
    return marks


def diff_marks(previous: dict[str, Any] | None, current: dict[str, Any]) -> list[dict[str, Any]]:
    """두 스냅샷의 차이를 사건 목록으로. **순수 함수** — 시계도 파일도 안 본다(그래서 테스트된다).

    첫 스냅샷(previous=None)은 기준선일 뿐 사건이 아니다. 이게 없으면 데몬이 뜨는 순간
    살아있는 세션 수만큼 알림이 쏟아진다."""
    if previous is None:
        return []
    events: list[dict[str, Any]] = []
    prev_sessions = previous.get("sessions") or {}
    for key, mark in (current.get("sessions") or {}).items():
        before = prev_sessions.get(key)
        base = {"session": key, "root": mark.get("root"), "source": mark.get("source"),
                "sid": mark.get("sid"), "title": mark.get("title")}
        if before is None:
            # 새 세션 자체는 사건이 아니다(목록만 갱신). 단 뜨자마자 질문 중이면 사람을 불러야 한다.
            if mark.get("questionToken"):
                events.append({**base, "kind": "question"})
            continue
        if mark.get("questionToken") and mark["questionToken"] != before.get("questionToken"):
            events.append({**base, "kind": "question"})
        status, was = mark.get("status"), before.get("status")
        if status != was:
            if status in ("idle", "completed") and was in ("working", "blocked"):
                events.append({**base, "kind": "idle", "status": status})
            elif status in ("blocked", "failed"):
                events.append({**base, "kind": "blocked", "status": status})
            else:
                events.append({**base, "kind": "status", "status": status})
        if float(mark.get("ts") or 0) > float(before.get("ts") or 0):
            events.append({**base, "kind": "message"})

    prev_services = previous.get("services") or {}
    for key, mark in (current.get("services") or {}).items():
        before = prev_services.get(key)
        if before is None or mark.get("state") == before.get("state"):
            continue
        state, was = mark.get("state"), before.get("state")
        if state == "running" and was == "starting":
            events.append({"kind": "service", "event": "ready", **mark})
        elif state == "error":
            events.append({"kind": "service", "event": "failed", **mark})
    return events


class EventBus:
    """구독자에게 사건을 나눠준다. 느린 구독자가 전체를 붙잡지 않도록 각자 유한한 통을 갖는다."""

    def __init__(self, queue_max: int = 256) -> None:
        self._lock = threading.Lock()
        self._subscribers: dict[int, list[dict[str, Any]]] = {}
        self._conditions: dict[int, threading.Condition] = {}
        self._next_id = 1
        self._queue_max = queue_max

    def subscribe(self) -> int:
        with self._lock:
            token = self._next_id
            self._next_id += 1
            self._subscribers[token] = []
            self._conditions[token] = threading.Condition(self._lock)
            return token

    def unsubscribe(self, token: int) -> None:
        with self._lock:
            self._subscribers.pop(token, None)
            condition = self._conditions.pop(token, None)
        if condition is not None:
            with self._lock:
                condition.notify_all()

    def publish(self, events: list[dict[str, Any]]) -> None:
        if not events:
            return
        with self._lock:
            for token, queue in self._subscribers.items():
                queue.extend(events)
                if len(queue) > self._queue_max:
                    # 넘치면 **오래된 것부터** 버린다. 최신 상태가 늘 더 쓸모 있고,
                    # 놓친 사건은 구독자가 전체 상태를 한 번 새로 받으면 복구된다.
                    del queue[:-self._queue_max]
                self._conditions[token].notify_all()

    def wait(self, token: int, timeout: float) -> list[dict[str, Any]]:
        """쌓인 사건을 가져온다. 없으면 timeout 까지 기다린다(빈 목록이면 하트비트를 보낼 때)."""
        with self._lock:
            condition = self._conditions.get(token)
            if condition is None:
                return []
            queue = self._subscribers.get(token)
            if not queue:
                condition.wait(timeout)
                queue = self._subscribers.get(token)
            if not queue:
                return []
            drained, queue[:] = list(queue), []
            return drained

    def subscriber_count(self) -> int:
        with self._lock:
            return len(self._subscribers)


class ChangeWatcher:
    """스냅샷을 떠서 비교하고 사건을 낸다. 훅이 찌르면 기다리지 않고 즉시 한 바퀴 돈다."""

    def __init__(self, snapshot: Callable[[], dict[str, Any]], bus: EventBus,
                 interval: float = WATCH_INTERVAL_S,
                 interval_fn: Callable[[], float] | None = None) -> None:
        self._snapshot = snapshot
        self._bus = bus
        self._interval = interval
        self._interval_fn = interval_fn
        self._previous: dict[str, Any] | None = None
        self._wake = threading.Event()
        self._lock = threading.Lock()
        self.last_events: list[dict[str, Any]] = []

    def poke(self) -> None:
        """훅이 '방금 뭔가 했다'고 알려온다 — 다음 주기를 기다리지 않는다."""
        self._wake.set()

    def tick(self) -> list[dict[str, Any]]:
        """한 바퀴. 실패해도 죽지 않는다 — 감시가 멈추면 화면 전체가 멈춘 것처럼 보인다."""
        try:
            current = self._snapshot()
        except Exception:
            return []
        with self._lock:
            events = diff_marks(self._previous, current)
            self._previous = current
        self.last_events = events
        self._bus.publish(events)
        return events

    def interval(self) -> float:
        """지금 얼마나 자주 볼지. **아무도 안 듣고 있으면 느리게 돈다.**

        듣는 사람이 없으면 사건을 즉시 만들 이유가 없다(훅이 찌르면 어차피 곧장 깬다).
        실측: 0.3초 고정이면 코어의 5.4%를 계속 먹는다 — 노트북에서 이유 없이 낼 값이 아니다.
        느리게 돌아도 캐시는 계속 데워져서 '오랜만에 열었을 때 첫 화면이 느린' 문제는 그대로 막힌다."""
        if self._interval_fn is None:
            return self._interval
        try:
            return max(self._interval, float(self._interval_fn()))
        except Exception:
            return self._interval

    def run_forever(self) -> None:
        while True:
            self.tick()
            # 훅이 찌르면 즉시 깨고, 아니면 주기만큼 잔다. 찔림이 몰리면 잠깐 뭉쳐 한 번만 돈다.
            if self._wake.wait(self.interval()):
                self._wake.clear()
                time.sleep(POKE_DEBOUNCE_S)


SERVICE_EVERY_N_TICKS = 10       # 서비스 상태는 대화만큼 자주 안 바뀐다 — 0.3초 × 10 = 3초


def build_snapshot(watch_state: Callable[[], dict[str, Any]],
                   service_sessions: Callable[[], list[dict[str, Any]]] | None = None,
                   previous_services: dict[str, Any] | None = None) -> dict[str, Any]:
    """비교용 스냅샷 한 장. 실패한 쪽은 비워두고 나머지는 살린다 —
    서비스 조회가 실패했다고 대화 갱신까지 멈추면 안 된다.

    service_sessions 가 None 이면 지난 서비스 표를 그대로 물려준다(이번 틱은 건너뛴다).
    서비스 조회는 compose·git 을 타서 비싸다 — 0.3초마다 하면 배보다 배꼽이 커진다."""
    try:
        sessions = _session_marks(watch_state())
    except Exception:
        sessions = {}
    if service_sessions is None:
        services = dict(previous_services or {})
    else:
        try:
            services = _service_marks(service_sessions())
        except Exception:
            services = dict(previous_services or {})
    return {"sessions": sessions, "services": services}


# ── 데몬 하나에 하나씩 ────────────────────────────────────────────────────────
# 감시 루프도 버스도 프로세스당 한 벌이다. 손님(SSE 연결·푸시)이 몇이든 계산은 한 번만 한다 —
# 이게 폴링 대비 진짜 이득이다(폰 3대가 붙어도 서버 일은 그대로).
_BUS: EventBus | None = None
_WATCHER: ChangeWatcher | None = None
_SINGLETON_LOCK = threading.Lock()


def event_bus() -> EventBus:
    global _BUS
    with _SINGLETON_LOCK:
        if _BUS is None:
            _BUS = EventBus()
        return _BUS


IDLE_INTERVAL_S = 15.0           # 듣는 사람이 없을 때. 훅이 찌르면 어차피 즉시 깬다
                                 # (3초로 뒀더니 하는 일 없이 코어의 2.7%를 계속 먹었다)


def start_watching(snapshot: Callable[[], dict[str, Any]],
                   on_events: Callable[[list[dict[str, Any]]], None] | None = None,
                   interval: float = WATCH_INTERVAL_S,
                   interval_fn: Callable[[], float] | None = None) -> ChangeWatcher:
    """데몬 부팅 때 한 번. on_events 는 알림 판단층으로 가는 갈래다(버스와 별개로 받는다)."""
    global _WATCHER
    with _SINGLETON_LOCK:
        if _WATCHER is not None:
            return _WATCHER
        bus = _BUS if _BUS is not None else EventBus()
        globals()["_BUS"] = bus

        class _Watcher(ChangeWatcher):
            def tick(self) -> list[dict[str, Any]]:
                events = super().tick()
                if events and on_events is not None:
                    try:
                        on_events(events)
                    except Exception:
                        pass          # 알림이 실패해도 화면 갱신은 계속돼야 한다
                return events

        _WATCHER = _Watcher(snapshot, bus, interval, interval_fn)
        threading.Thread(target=_WATCHER.run_forever, daemon=True, name="marina-events").start()
        return _WATCHER


def poke() -> bool:
    """훅이 '방금 뭔가 했다'고 알린다. 감시가 아직 안 떴으면 조용히 무시(다음 주기가 잡는다)."""
    watcher = _WATCHER
    if watcher is None:
        return False
    watcher.poke()
    return True


def sse_frame(event: dict[str, Any]) -> bytes:
    """SSE 한 프레임. 개행이 섞이면 프로토콜이 깨지므로 JSON 한 줄로만 싣는다."""
    return b"data: " + json.dumps(event, ensure_ascii=False).encode("utf-8") + b"\n\n"
