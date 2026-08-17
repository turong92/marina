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


# 방 목록 경로에서 git 을 부르는 **유일한** 자리다. 그래서 캐시 뒤에 둔다 — 방 목록은 폴마다
# 도는데 워크트리마다 git 을 돌리면 전에 잡은 "초당 git 40회"가 그대로 재현된다(스펙 미해결 3번).
_CHANGES_TTL_S = 20.0
_changes_cache: dict[str, tuple[float, bool]] = {}


def _git(args: list[str], cwd: Path) -> str:
    out = subprocess.run(["git", "-C", str(cwd), *args],
                         capture_output=True, text=True, timeout=5)
    return out.stdout


def room_has_changes(root: Path, *, runner: Callable[[list[str], Path], str] = None,
                     now: float = None) -> bool:
    """이 워크트리에 **볼 만한 결과**가 있나 — 완료 판정의 재료(스펙 §4).

    미커밋 변경과 "아직 어느 리모트에도 없는 커밋"을 **둘 다** 본다. 커밋까지 끝낸 경우를
    빼먹으면 "다 해놓고 커밋했더니 완료가 아니라고 나오는" 일이 생긴다.

    앞선 커밋 판정에 @{upstream} 을 쓰지 않는 이유: 마리나 워크트리의 브랜치는 대개 푸시된
    적 없는 로컬 브랜치라 upstream 자체가 없다. `HEAD --not --remotes` 는 추적 설정 없이도
    "아직 올라가지 않은 내 커밋"을 그대로 집는다. 리모트가 아예 없는 저장소에서는 전 이력이
    잡히지만, 그 경우 "결과가 있다"는 판정이 크게 틀리지도 않는다.

    실패하면 False 다 — git 이 없거나 깨진 워크트리 하나 때문에 방 목록 전체가 죽으면 안 된다."""
    key = str(root)
    current = time.time() if now is None else now
    cached = _changes_cache.get(key)
    if cached is not None and current - cached[0] < _CHANGES_TTL_S:
        return cached[1]
    run = runner or _git
    try:
        dirty = bool(run(["status", "--porcelain"], root).strip())
        # 미커밋이 이미 있으면 커밋 쪽은 볼 필요가 없다 — git 한 번을 아낀다.
        ahead = dirty or bool(run(["log", "--oneline", "-1", "HEAD", "--not", "--remotes"],
                                  root).strip())
    except Exception:
        return False        # 캐시에 넣지 않는다 — 다음 기회에 다시 본다
    result = bool(dirty or ahead)
    _changes_cache[key] = (current, result)
    return result
