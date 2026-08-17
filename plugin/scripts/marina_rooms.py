"""방(Room) — 마리나가 사람에게 보여주는 일감 단위.

방 하나 = 워크트리 하나이고, 그 안의 세션들이 탭이다(스펙 §2). 이 파일은 **화면도 HTTP 도
모른다** — 조립만 한다. 그래야 모바일·웹이 같은 것을 보고, 계산이 두 벌로 갈라지지 않는다.

상태는 **새로 만들지 않는다.** marina_sessions.resolve_session_liveness 가 단일 캐논이고
여기서는 그 6개를 5개로 접기만 한다(스펙 §5).
"""
from __future__ import annotations

import subprocess
import time
from pathlib import Path
from typing import Any, Callable

# 심각한 것부터. 방 안 탭들의 상태를 하나로 접을 때, 사람 조치가 필요한 것이 위로 올라와야
# 방 목록에서 놓치지 않는다(스펙 §2).
ROOM_STATUS_ORDER = ("문제", "응답필요", "작업중", "완료", "대기")

_STATUS_MAP = {
    "working": "작업중",
    "idle": "대기",
    "failed": "문제",
    "blocked": "응답필요",
    # waiting 은 캐논상 blocked 보다 순하지만(턴을 끝내고 프롬프트 대기), 사람에게 요구하는
    # 행동은 같다 — 뭔가 쳐야 움직인다. 구분은 색으로만 한다(스펙 §5).
    "waiting": "응답필요",
}


def room_status(status: str, has_changes: bool) -> str:
    """캐논 상태 하나를 방 상태로 접는다.

    completed 만 두 갈래다: 바뀐 파일이 있으면 완료, 없으면 대기(스펙 §4). completed 를
    그대로 완료로 보면 질문만 하고 끝난 턴·"못 합니다"로 끝난 턴까지 "일 끝났어요"가 되어
    카드 자체를 안 믿게 된다.

    모르는 값은 대기다 — CLI 가 새 어휘를 내놔도 화면이 깨지지 않아야 한다."""
    text = str(status or "")
    if text == "completed":
        return "완료" if has_changes else "대기"
    return _STATUS_MAP.get(text, "대기")
