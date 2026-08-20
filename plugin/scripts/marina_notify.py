"""알림을 보낼지 정한다 — 사건과 전송 사이의 판단층.

**왜 따로 두나.** 사건은 초당 여러 개 난다. 그대로 폰에 흘리면 진동 지옥이 되고, 반대로
규칙을 전송 코드에 섞으면 SSE·푸시 두 곳에 같은 규칙이 갈라져 살게 된다. 판단은 여기 한 곳.

**규칙 넷.**
  ① 사람을 불러야 하는 사건만(question·idle·blocked·service). message 는 화면 갱신 전용이다.
  ② 형이 지금 쓰는 세션만 — 오래 조용한 세션과 숨긴 세션은 부르지 않는다(세션이 34개다).
  ③ 같은 (세션, 종류)는 잠깐 사이 한 번만 — 상태가 떨렸다고 두 번 울리지 않는다.
  ④ 폰이 그 대화를 **보고 있으면** 푸시하지 않는다. 이 판단만은 서버가 못 한다(누가 무엇을
     보는지는 화면만 안다) — 그래서 서비스워커가 깬 뒤에 마지막으로 거른다.
"""
from __future__ import annotations

import json
import os
import threading
import time
from typing import Any

from marina_state import MARINA_HOME

ALERTS_FILE = MARINA_HOME / "notify-alerts.json"
ENGAGED_WINDOW_S = 12 * 3600     # 이보다 오래 조용한 세션은 "지금 쓰는 것"이 아니다
DEDUPE_S = 60.0                  # 같은 (세션, 종류) 재알림 금지 구간
ALERT_KEEP_S = 300.0             # 서비스워커가 깨서 가져갈 때까지 보관하는 시간
ALERT_MAX = 20
_LOCK = threading.Lock()
_last_fired: dict[str, float] = {}
# 중복 억제는 **재시작을 넘겨야** 한다. 메모리에만 두면 데몬이 새로 뜰 때마다 초기화되어
# 같은 알림이 다시 간다 — 배포·재시작이 잦은 만큼 형 폰엔 같은 말이 반복해서 뜬다.
FIRED_FILE_NAME = "notify-fired.json"


def _fired_file() -> Path:
    return ALERTS_FILE.parent / FIRED_FILE_NAME


def _load_fired() -> dict[str, float]:
    if _last_fired:
        return _last_fired
    try:
        raw = json.loads(_fired_file().read_text(encoding="utf-8"))
        if isinstance(raw, dict):
            _last_fired.update({str(k): float(v) for k, v in raw.items()
                                if isinstance(v, (int, float))})
    except Exception:
        pass
    return _last_fired


def _save_fired(fired: dict[str, float], now: float) -> None:
    # 오래된 것은 버린다 — 중복 억제 구간을 넘긴 기록은 판정에 쓸모가 없다.
    산것 = {k: v for k, v in fired.items() if now - float(v) < DEDUPE_S * 20}
    fired.clear()
    fired.update(산것)
    try:
        path = _fired_file()
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(산것), encoding="utf-8")
        os.replace(tmp, path)
    except OSError:
        pass

_TITLES = {
    "question": "물어볼 게 있어요",
    "idle": "작업이 끝났어요",
    "blocked": "막혔어요 — 확인이 필요해요",
}


def alert_text(event: dict[str, Any]) -> tuple[str, str]:
    """알림에 띄울 제목과 본문. 대화 내용은 싣지 않는다 — 잠금화면에 남고, 어차피 열면 보인다."""
    kind = str(event.get("kind") or "")
    if kind == "service":
        name = str(event.get("service") or "서비스")
        where = str(event.get("alias") or "")
        ready = event.get("event") == "ready"
        return (f"{name} {'기동 완료' if ready else '기동 실패'}", where or "마리나")
    title = _TITLES.get(kind, "마리나")
    return (title, str(event.get("title") or event.get("sid") or "세션"))


def should_notify(event: dict[str, Any], *, engaged: bool, hidden: bool,
                  now: float, last_fired: dict[str, float] | None = None) -> bool:
    """이 사건으로 폰을 울릴까. **순수 판정** — 파일도 네트워크도 안 본다(그래서 테스트된다)."""
    kind = str(event.get("kind") or "")
    if kind not in ("question", "idle", "blocked", "service"):
        return False
    if hidden:
        return False
    if kind != "service" and not engaged:
        return False          # 서비스는 세션과 무관하게 형이 띄운 것이므로 항상 알린다
    fired = _load_fired() if last_fired is None else last_fired
    key = f"{event.get('session') or event.get('root')}\n{kind}"
    if now - float(fired.get(key) or 0) < DEDUPE_S:
        return False
    fired[key] = now
    if last_fired is None:
        _save_fired(fired, now)
    return True


def is_primary_notifier(port: int) -> bool:
    """지금 이 프로세스가 **폰을 울려도 되는 그 데몬**인가.

    왜 필요한가(형 지적 2026-08-20 "푸시가 스팸일 수 있다고 뜬다"): 마리나 프로세스가 둘 이상
    돌면 각자 감지 루프를 돌려 **같은 사건으로 각각 푸시를 쏜다**. 중복 억제(_last_fired)는
    프로세스 안에만 있어서 서로를 모르고, 두 번째 인스턴스를 다시 띄울 때마다 초기화된다.
    실측 흔적: 같은 세션·같은 종류의 알림이 5초 간격으로, 심지어 같은 초에 두 번.
    그렇게 쌓인 무의미한 알림이 브라우저의 스팸 판정을 부른다.

    판정 기준은 **데몬이 기록해둔 포트**다(dashboard-bind.env). 개발용·프리뷰 인스턴스는 다른
    포트로 뜨므로 여기서 걸린다. 기록이 없거나 깨졌으면 막지 않는다 — 알림이 통째로 죽는 쪽이
    더 나쁘다."""
    path = ALERTS_FILE.parent / "dashboard-bind.env"
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            if key.strip() == "MARINA_CONTROL_PORT":
                return int(value.strip()) == int(port)
    except (OSError, ValueError):
        return True
    return True


def is_engaged(event: dict[str, Any], marks: dict[str, Any], now: float) -> bool:
    """형이 지금 쓰는 세션인가 — 최근에 움직인 세션만 부른다."""
    mark = (marks or {}).get(str(event.get("session") or ""))
    if not isinstance(mark, dict):
        return False
    return now - float(mark.get("ts") or 0) <= ENGAGED_WINDOW_S


def _read_alerts() -> list[dict[str, Any]]:
    try:
        value = json.loads(ALERTS_FILE.read_text(encoding="utf-8"))
    except Exception:
        return []
    return value if isinstance(value, list) else []


def _write_alerts(alerts: list[dict[str, Any]]) -> None:
    ALERTS_FILE.parent.mkdir(parents=True, exist_ok=True)
    temporary = ALERTS_FILE.with_suffix(".tmp")
    temporary.write_text(json.dumps(alerts, ensure_ascii=False), encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, ALERTS_FILE)


def record_alerts(events: list[dict[str, Any]], now: float | None = None) -> list[dict[str, Any]]:
    """푸시로 깨어난 서비스워커가 가져갈 알림을 남긴다(내용 없는 푸시라 여기서 읽어 간다)."""
    current = time.time() if now is None else now
    fresh = []
    for event in events:
        title, body = alert_text(event)
        fresh.append({"kind": event.get("kind"), "title": title, "body": body,
                      "session": event.get("session") or "", "root": event.get("root") or "",
                      "source": event.get("source") or "", "sid": event.get("sid") or "",
                      "ts": current, "tag": f"{event.get('session') or event.get('root')}:{event.get('kind')}"})
    if not fresh:
        return []
    with _LOCK:
        kept = [a for a in _read_alerts() if current - float(a.get("ts") or 0) <= ALERT_KEEP_S]
        _write_alerts((kept + fresh)[-ALERT_MAX:])
    return fresh


def pending_alerts(since: float = 0.0, now: float | None = None) -> list[dict[str, Any]]:
    """서비스워커가 물어볼 때 주는 목록 — since 이후로 쌓인 것만."""
    current = time.time() if now is None else now
    return [a for a in _read_alerts()
            if float(a.get("ts") or 0) > since and current - float(a.get("ts") or 0) <= ALERT_KEEP_S]
