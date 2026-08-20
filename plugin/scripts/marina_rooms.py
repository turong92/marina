"""방(Room) — 마리나가 사람에게 보여주는 일감 단위.

방 하나 = 워크트리 하나이고, 그 안의 세션들이 탭이다(스펙 §2). 이 파일은 **화면도 HTTP 도
모른다** — 조립만 한다. 그래야 모바일·웹이 같은 것을 보고, 계산이 두 벌로 갈라지지 않는다.

상태는 **새로 만들지 않는다.** marina_sessions.resolve_session_liveness 가 단일 캐논이고
여기서는 그 6개를 5개로 접기만 한다(스펙 §5).
"""
from __future__ import annotations

import re
import secrets
import subprocess
import threading
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
# 실패는 **더 길게** 쉰다. git 이 5초 타임아웃으로 실패하는 상황(index.lock 장기 점유, 거대
# 레포, 마운트 지연)에서 매번 다시 시도하면 폴마다 5초를 그대로 문다 — 깨진 워크트리 둘이면
# 폰 응답이 10초다. git 을 아끼려고 만든 캐시가 정확히 반대로 작동한다.
_CHANGES_FAIL_TTL_S = 60.0
_CHANGES_CACHE_MAX = 200        # 워크트리 수(지금 28) 보다 넉넉히. 넘으면 만료된 것부터 버린다.
# key → (만료 시각, 판정)
_changes_cache: dict[str, tuple[float, bool]] = {}
# 완료 카드용 요약 — **같은 git 호출의 출력**에서 뽑는다(또 부르면 순수한 낭비다).
_summary_cache: dict[str, tuple[float, dict[str, Any]]] = {}
_SUMMARY_NAMES_MAX = 4      # 카드 한 장에 들어갈 만큼만
# 데몬은 요청마다 스레드다. dict 갱신 자체는 GIL 덕에 깨지지 않지만, 청소 중에 크기가
# 바뀌면 순회가 터진다 — 청소만 잠근다(읽기·쓰기는 잠그지 않는다. 최악이 git 한 번 더다).
_changes_lock = threading.Lock()


def _prune_changes_cache(current: float) -> None:
    """만료된 항목을 버린다. 워크트리는 생겼다 사라지므로, 안 지우면 죽은 경로가 계속 쌓인다."""
    with _changes_lock:
        if len(_changes_cache) <= _CHANGES_CACHE_MAX:
            return
        for key in [k for k, (expires, _) in list(_changes_cache.items()) if current >= expires]:
            _changes_cache.pop(key, None)
            _summary_cache.pop(key, None)      # 요약도 같이 — 지운 방 것이 데몬 끝까지 남았다
        # 요약만 남는 경우도 턴다(판정은 실패 캐시로 갈리고 요약은 안 갈릴 수 있다).
        for key in [k for k, (expires, _) in list(_summary_cache.items()) if current >= expires]:
            _summary_cache.pop(key, None)


class GitFailed(Exception):
    """git 이 답을 못 줬다 — '변경 없음'과 **구별**해야 한다.

    예전엔 stdout 만 보고 rc 를 무시했다. index.lock 점유·dubious ownership·손상된 .git 이
    전부 빈 stdout 을 내므로 "다 해놨는데 대기로 나오고" 그 오답이 20초 동안 캐시됐다."""


def _git(args: list[str], cwd: Path) -> str:
    out = subprocess.run(["git", "-C", str(cwd), *args],
                         capture_output=True, text=True, timeout=5)
    if out.returncode != 0:
        raise GitFailed(f"rc={out.returncode} {(out.stderr or '').strip()[:120]}")
    return out.stdout


# 마리나가 워크트리 안에 자기 것을 쓰는 자리(별칭·메모 — marina_paths 의 .workspace/marina).
# 이걸 형 작업물로 세면, 마리나가 파일 하나 건드린 것만으로 방이 "완료"가 된다(실측).
_MARINA_OWN = (".workspace/", ".workspace")


def own_changed_paths(status_text: str, root: Path) -> list[str]:
    """`git status --porcelain -z` 에서 **이 워크트리의** 변경 경로만 골라낸다.

    중첩 레포는 뺀다 — 완료 판정(_has_own_changes)과 **같은 규칙**을 써야 한다. 규칙이
    갈라지면 "완료라는데 바뀐 파일이 없다"가 나온다."""
    out: list[str] = []
    records = [item for item in str(status_text or "").split("\0") if item.strip()]
    index = 0
    while index < len(records):
        record = records[index]
        index += 1
        # 리네임/복사는 레코드가 **둘**이다: `R  <새경로>\0<옛경로>\0`. 옛 경로에는 XY 접두사가
        # 없는데도 앞 3글자를 자르면 이름이 뭉개지고(ab.py → "py") 개수도 하나 부푼다.
        if record[:1] in ("R", "C"):
            index += 1          # 옛 경로는 건너뛴다 — 한 번의 변경이다
        path = record[3:] if len(record) > 3 else ""
        if path in _MARINA_OWN or path.startswith(".workspace/"):
            continue        # 마리나가 쓴 것 — 형이 한 일이 아니다
        if record.startswith("?? "):
            if path.endswith("/") and _is_nested_repo(root / path):
                continue
        if path:
            out.append(path)
    return out


def _has_own_changes(status_text: str, root: Path) -> bool:
    """`git status --porcelain` 결과에 **이 워크트리의** 변경이 있나.

    중첩 git 레포(`?? sub/` 이면서 sub/.git 이 있는 것)는 뺀다. git 은 중첩 레포 안으로
    안 내려가므로 그 안에서 무슨 일이 있어도 여기엔 디렉터리 한 줄로만 나온다 — 즉 이 한 줄은
    "남의 레포가 거기 있다"는 사실일 뿐, 이 방이 뭘 했다는 증거가 아니다."""
    # **-z 출력**을 읽는다(NUL 구분). 기본 출력은 core.quotePath 때문에 비ASCII 이름을
    # `"\355\225\234..."` 로 이스케이프해 버려, 한글 폴더가 중첩 레포여도 경로가 안 맞아
    # "내 변경"으로 세어진다 — 형은 한글 이름을 쓴다. -z 는 인용 자체를 하지 않는다.
    # own_changed_paths 와 **같은 규칙**을 쓴다(중첩 레포·마리나 자기 폴더 제외).
    # 규칙이 갈라지면 "완료라는데 바뀐 파일이 없다"가 나온다 — 실제로 그렇게 어긋났다.
    return bool(own_changed_paths(status_text, root))


def _is_nested_repo(path: Path) -> bool:
    """이 디렉터리가 자기 git 레포인가. 권한이 막혀 있으면 판단을 포기한다 —
    py3.9 의 Path.exists() 는 EACCES 를 삼키지 않고 던진다(그대로 두면 방 전체가 실패 캐시로 떨어진다)."""
    try:
        return (path / ".git").exists()
    except OSError:
        return False


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
    if cached is not None and current < cached[0]:
        return cached[1]
    run = runner or _git
    try:
        # untracked 를 **세되, 중첩 git 레포는 뺀다.**
        # 그냥 세면: 서브레포를 품은 레포에서 `?? ai-api/` 가 영구히 잡혀 그 방들이 무슨 일을
        #   하든 항상 "완료"였다(실측 2026-08-17: 워크트리 28개 중 17개).
        # 아예 빼면(-uno): 새 파일만 만들고 끝난 턴이 통째로 사라진다 — 계획 문서 하나, 새
        #   테스트 파일, 새 모듈이 그렇다. 이 Room API 의 계획 문서가 정확히 그 경우였다.
        # 버려야 할 건 "untracked 전부"가 아니라 "남의 레포"다. 중첩 레포는 자기 워크트리에서
        # 따로 관리되지 이 방의 작업물이 아니다.
        status_text = run(["status", "--porcelain", "-z"], root)
        경로들 = own_changed_paths(status_text, root)
        _summary_cache[key] = (current + _CHANGES_TTL_S, {
            "files": len(경로들),
            # 폰에서 전체 경로는 못 읽는다 — 파일명만 몇 개.
            "names": [part.rstrip("/").split("/")[-1] for part in 경로들[:_SUMMARY_NAMES_MAX]],
        })
        dirty = bool(경로들)
        # 미커밋이 이미 있으면 커밋 쪽은 볼 필요가 없다 — git 한 번을 아낀다.
        # 커밋 수까지 센다(상한을 둔다 — 카드에 쓸 숫자지 목록이 아니다). 미커밋이 있으면
        # 굳이 안 센다: 그때는 파일 개수로 말하고, git 한 번을 아낀다.
        커밋들 = "" if dirty else run(["log", "--oneline", "-20", "HEAD", "--not", "--remotes"], root)
        commits = len([line for line in 커밋들.splitlines() if line.strip()])
        _summary_cache[key] = (current + _CHANGES_TTL_S,
                               {**_summary_cache[key][1], "commits": commits})
        ahead = dirty or commits > 0
    except Exception:
        # 실패도 캐시한다(더 긴 수명으로). 안 하면 지속적 실패에서 폴마다 타임아웃을 다시 문다.
        # 값은 False — "결과가 있다"고 잘못 말하느니 "아직 아니다" 쪽으로 틀린다.
        _changes_cache[key] = (current + _CHANGES_FAIL_TTL_S, False)
        _prune_changes_cache(current)
        return False
    result = bool(dirty or ahead)
    _changes_cache[key] = (current + _CHANGES_TTL_S, result)
    _prune_changes_cache(current)
    return result


# 말 거는 군더더기 — 목록에서 이 단어들은 방을 구별해주지 않는다. 형이 말하듯 시키기 때문에
# ("야 너 …", "야 지금 …") 첫 두어 단어가 거의 항상 같다.
# 조사가 붙은 형태도 같이 넣는다 — "너는 …", "지금은 …" 이 실제로 자주 나온다(실측).
_FILLER = ("야", "너", "너는", "우리", "우리는", "지금", "지금은", "좀", "이제", "그리고")


def short_name(name: str, limit: int = 22) -> str:
    """목록 한 줄에 들어갈 이름.

    별칭을 안 붙인 방은 **형이 처음 친 말**이 통째로 이름이다(실측 2026-08-18). 그대로 쓰면
    목록이 문장으로 가득 차 무엇이 무엇인지 안 보인다. 첫 줄만 남기고, 말 거는 군더더기를
    떼고, 길면 단어 경계에서 자른다.

    자르는 것뿐이라 원본은 그대로 남는다 — 방을 열면 원래 이름을 본다. 앞이 아니라 뒤를
    자르는 이유: 같은 말로 시작하는 방이 많아서, 앞을 살려야 서로 구별된다."""
    lines = str(name or "").strip().splitlines()
    line = lines[0].strip() if lines else ""
    if not line:
        return ""
    words = line.split()
    # 전부 군더더기면 그대로 둔다 — 다 떼면 이름이 아예 사라진다.
    if any(word not in _FILLER for word in words):
        while words and words[0] in _FILLER:
            words.pop(0)
    line = " ".join(words)
    if len(line) <= limit:
        return line
    # **URL·파일경로는 앞이 거의 같다.** 앞 22자만 남기면 같은 저장소의 이슈와 PR 이,
    # 같은 폴더의 두 파일이 똑같은 이름이 된다(실 데이터에 이미 그런 방이 있다).
    # 이런 이름에서 구별 정보는 마지막 조각이다.
    한덩어리 = " " not in line
    if 한덩어리 and "/" in line:
        머리, _, 꼬리 = line.partition("://")
        조각 = [part for part in (꼬리 or 머리).split("/") if part]
        # **끝 두 조각**을 쓴다. 경로·URL 에서 사람이 알아보는 건 파일명과 그 부모(또는
        # issues/1234 같은 마지막 쌍)이지 맨 앞의 호스트·홈 디렉터리가 아니다.
        # 앞이 다 같아도(둘 다 /Users/…) 뒤가 다르면 구별되고, 뒤까지 같으면 그건 ✎ 로 푼다.
        꼬리조각 = 조각[-2:] if len(조각) > 1 else 조각
        if 꼬리조각:
            줄임 = ("…/" if len(조각) > len(꼬리조각) else "") + "/".join(꼬리조각)
            # 잘렸으면 **잘렸다고 표시한다.** 표시 없이 자르면(브랜치명처럼 앞이 같고 뒤가 긴
            # 경우) 잘린 줄도 모른 채 서로 같은 이름이 된다.
            return 줄임 if len(줄임) <= limit + 8 else 줄임[:limit + 7] + "…"
    cut = line[:limit]
    if " " in cut[1:]:
        cut = cut[:cut.rindex(" ")]
    # 문장은 **깨끗하게** 자른다. 끝 단어를 붙여 구별하는 방법도 해봤는데, 실제 프롬프트의
    # 마지막 낱말이 대개 의미 없는 조각이라("…서비스가… Or", "…시니어… 디렉터리:") 모든 긴
    # 이름이 지저분해졌다. 앞이 같은 문장 둘이 실제로 부딪히는 경우는 지금 데이터에 없고,
    # 부딪히면 부제의 프로젝트 이름과 ✎ 이름 바꾸기로 푼다 — 흔한 경우를 망치지 않는 쪽이다.
    return cut.rstrip() + "…"


def change_summary(root: Path, *, runner: Callable[[list[str], Path], str] = None,
                   now: float = None) -> dict[str, Any]:
    """완료 카드에 쓸 요약 — 몇 개가 바뀌었고 이름이 무엇인가.

    **git 을 새로 부르지 않는다.** 완료 판정이 이미 status 를 부르므로 그 출력에서 같이
    뽑아 캐시에 담아둔다. 캐시가 비어 있으면 그때만 판정을 한 번 돌린다."""
    key = str(root)
    current = time.time() if now is None else now
    cached = _summary_cache.get(key)
    if cached is None or current >= cached[0]:
        room_has_changes(root, runner=runner, now=now)
        cached = _summary_cache.get(key)
        # git 이 계속 실패하면 판정만 갱신되고 요약은 낡은 채 남는다(실패 캐시가 더 길다).
        # 낡은 숫자를 "지금 이만큼 바뀌었다"로 내놓느니 모른다고 하는 게 낫다.
        if cached is not None and current >= cached[0]:
            return {"files": 0, "names": [], "commits": 0}
    return dict(cached[1]) if cached else {"files": 0, "names": [], "commits": 0}


def branch_from_text(text: str, *, salt: str = "") -> str:
    """첫 메시지에서 브랜치 이름을 짓는다(스펙 §3 "브랜치명은 마리나가 첫 메시지에서 짓는다").

    비개발자 화면에서 "브랜치"라는 말도, 그 이름 규칙(영문/숫자/-)도 형이 알 이유가 없다.
    그래서 형은 무슨 일을 할지만 쓰고, 이름은 여기서 만든다.

    **브랜치 이름은 ASCII 로만 짓는다.** 한글로 시킨 일이라도 그렇다 — 이 이름이 디렉터리
    이름이 되고 게이트웨이 도메인 라벨로도 쓰여서(gwDomainLabel), 한글이 들어가면 DNS 쪽이
    깨진다. 대신 **형에게 보이는 이름은 별칭으로 따로 붙인다**(방 이름 바꾸기와 같은 자리) —
    그래서 목록엔 "결제 환불 정합성"이 뜨고 폴더는 안전한 이름을 쓴다.

    같은 말로 시작해도 **서로 다른 워크트리**여야 한다 — 안 그러면 두 번째 생성이 실패한다.
    짧은 시각 기반 꼬리를 붙인다."""
    # 영어는 눕힌다 — 브랜치명 관례이고, 대소문자만 다른 이름이 섞이면 파일시스템에서 부딪힌다.
    raw = " ".join(str(text or "").split())[:60].lower()
    # 서버가 받는 문자 집합(marina_handler 의 검사)과 **같은 규칙**으로 턴다.
    # 경로 탈출(..)·명령 삽입(`;`, 백틱)은 여기서 통째로 사라진다.
    safe = re.sub(r"[^0-9a-z]+", "-", raw).strip("-")
    safe = re.sub(r"-{2,}", "-", safe)[:40].strip("-")
    # 시각만 쓰면 같은 밀리초에 두 번 부를 때 겹친다(실측). 무작위를 섞어 확실히 가른다 —
    # 겹치면 두 번째 워크트리 생성이 그냥 실패한다.
    꼬리 = salt or f"{int(time.time()) % 0xFFFF:04x}{secrets.token_hex(2)}"
    return f"{safe}-{꼬리}" if safe else f"work-{꼬리}"


def fold_status(tab_statuses: list[str]) -> str:
    """탭들의 상태를 방 상태 하나로. 사람 조치가 필요한 것이 위로 올라온다(스펙 §2).

    방 목록에서 놓치면 안 되는 순서라, '가장 최근'이 아니라 '가장 급한' 것을 고른다."""
    for candidate in ROOM_STATUS_ORDER:
        if candidate in tab_statuses:
            return candidate
    return "대기"


def attention_mark(status: str, tabs: list[dict[str, Any]]) -> str:
    """이 방이 **무엇으로** 형을 부르고 있나 — 접어둔 방을 다시 펼지 판단하는 지문.

    상태 문자열만 비교하면 "같은 상태의 새 사건"을 못 본다. 질문 뜬 방을 '나중에' 하고
    접었는데 에이전트가 더 급한 걸 물으면, 상태는 여전히 응답필요라 영영 안 펴진다 —
    접기의 취지가 정확히 반대로 작동한다.

    그래서 부르는 **내용**을 적는다: 질문은 그 표식(질문마다 다르다), 실패는 어느 세션이
    실패했는지. 완료는 한 번뿐인 사건이라 고정값이다 — 완료인 채로 치운 방이 파일 시각이
    갱신됐다고 다시 들이밀리면 안 되기 때문이다."""
    if status == "응답필요":
        # 질문 표식이 없는 경우도 있다(waiting — 프롬프트 앞에서 기다리는 중, blocked — 권한
        # 대기). 그때는 세션과 **마지막 활동 시각**으로 구별한다. sid 만 쓰면 그 세션이 살아
        # 있는 한 지문이 영영 고정이라, 새 턴이 몇 번을 돌아도 접힌 방이 안 펴진다.
        return "q:" + ",".join(sorted(
            f"{tab.get('sid') or ''}={tab.get('question') or int(float(tab.get('ts') or 0))}"
            for tab in tabs if str(tab.get("status") or "") == "응답필요"))
    if status == "문제":
        # 시각을 함께 넣는다 — sid 만 쓰면 **같은 세션이 다시 실패해도** 지문이 그대로라
        # 접어둔 방이 안 펴진다(응답필요 갈래와 같은 이유, 같은 처방).
        return "f:" + ",".join(sorted(
            f"{tab.get('sid') or ''}={int(float(tab.get('ts') or 0))}"
            for tab in tabs if str(tab.get("status") or "") == "문제"))
    if status == "완료":
        return "done"
    return ""


def finalize_room(room: dict[str, Any]) -> dict[str, Any]:
    """방의 상태·지문·시각을 **탭에서 다시 계산한다.** 이 세 값을 정하는 유일한 자리다.

    왜 함수로 뺐나: 탭을 건드리는 곳이 여럿이다(방 조립, 권한 필터, 전체보기의 숨김 탭
    덧붙이기). 각자 필요한 값만 다시 재던 동안 같은 실수가 네 번 반복됐다 — 상태는 고쳤는데
    지문은 안 고치고, 지문은 맞는데 시각이 옛것이고, 필터가 탭은 걸렀는데 지문엔 못 보는
    세션의 sid 가 남는 식이다. 탭을 바꿨으면 이 함수를 부른다. 그러면 셋이 같이 움직인다.

    **hidden 탭은 세지 않는다.** 숨김의 뜻이 "나를 부르지 마라"이므로, 보이기만 하고 상태에는
    영향을 주지 않는다 — 그래야 보는 화면(전체보기/일반)에 따라 방 상태가 달라지지 않는다."""
    # 안 세는 탭이 두 종류다. **뜻이 달라서 따로 둔다** — hidden 은 형이 직접 숨긴 것이고
    # (해제할 수 있다), stale 은 기준 방 밖(오래된 대화)이라 볼 수만 있는 것이다. 하나로
    # 뭉치면 숨긴 적 없는 대화에 "숨김" 배지가 붙고 해제를 눌러도 안 없어진다.
    counted = [tab for tab in room.get("tabs", [])
               if not tab.get("hidden") and not tab.get("stale")]
    room["status"] = fold_status([str(tab.get("status") or "") for tab in counted])
    room["mark"] = attention_mark(room["status"], counted)
    room["lastAt"] = max((float(tab.get("ts") or 0) for tab in counted), default=0)
    return room


def build_room(root: Path, labels: dict[str, Any], agents: list[dict[str, Any]], *,
               has_changes: bool, questions: Callable[[str, str], Any]) -> dict[str, Any]:
    """방 하나를 조립한다 — 워크트리 1개 + 그 안의 세션들(탭).

    이름은 **하나**다. 배경에 적힌 "이름이 세 번 반복된다"가 여기서 다시 나오지 않도록,
    별칭 → 세션 제목 → 워크트리 id 순으로 **한 줄만** 고른다. 슬러그는 상세에서만 쓴다.

    questions 는 "이 세션이 답을 기다리는 질문이 있나"를 돌려주는 함수다. 있으면 그 탭은
    실행 중이 아니라 **형 차례**이므로 응답필요로 본다."""
    tabs: list[dict[str, Any]] = []
    # 마지막 활동이 최근인 것부터 — 맨 앞이 방을 열었을 때 먼저 열리는 탭이다.
    for agent in sorted(agents, key=lambda item: float(item.get("ts") or 0), reverse=True):
        source, sid = str(agent.get("source") or ""), str(agent.get("sid") or "")
        pending = questions(source, sid) or {}
        canon = "blocked" if pending else str(agent.get("status") or "idle")
        tabs.append({
            "source": source,
            "sid": sid,
            "title": str(agent.get("title") or sid or source),
            "status": room_status(canon, has_changes),
            # 탭의 마지막 활동 시각. 화면 정렬에도 쓰지만, 권한 필터가 탭을 걸러낸 뒤 방의
            # lastAt 을 다시 계산하려면 탭이 자기 시각을 들고 있어야 한다.
            "ts": float(agent.get("ts") or 0),
            # 왜 막혔는지 — 로그인이 풀린 대화가 어느 것인지 화면이 알아야 한다.
            # 없으면 "가장 최근 클로드 대화"에 /login 을 쳐서, 작업 중인 대화에 그 글자가
            # 프롬프트로 제출된다.
            "reason": str(agent.get("statusReason") or ""),
            "canon": str(agent.get("status") or ""),
            # 지금 기다리는 질문의 표식. **질문마다 다르다** — 접어둔 방에 새 질문이 왔는지를
            # 상태 문자열("응답필요")로는 알 수 없어서, 이 값으로 구별한다.
            "question": str(pending.get("token") or "") if pending else "",
            "primary": not tabs,
        })
    # 이름: 별칭 → **첫 탭의 제목** → 워크트리 id.
    # labels["sessionTitle"] 을 쓰지 않는 이유: 세션이 없으면 그 값이 HEAD 커밋 제목으로
    # 떨어진다(worktree_labels 의 repo_head_subject 폴백). 그러면 방금 만든 빈 워크트리가
    # 남의 커밋 작업을 하던 방처럼 보인다 — 세션 카드에서 이미 한 번 잡았던 그 오해다.
    name = (str(labels.get("alias") or "").strip()
            or (str(tabs[0]["title"]).strip() if tabs else "")
            or str(labels.get("id") or "").strip())
    # 상태·지문·시각은 finalize_room 이 정한다 — 여기서 따로 계산하면 그게 두 벌째가 된다.
    return finalize_room({
        "id": str(labels.get("id") or ""),
        "name": name,
        # 목록은 한 줄이고 폰은 좁다 — 줄인 이름은 여기서 만든다. 원본은 name 에 그대로 있고
        # 방을 열면 그걸 보여준다.
        "shortName": short_name(name),
        "project": str(labels.get("projectLabel") or ""),
        "projectId": str(labels.get("projectId") or ""),
        "root": str(root),
        "tabs": tabs,
        # 배포는 지금 만들지 않는다 — 자리만 잡아둔다(스펙 확장 지점).
        "canShip": False,
    })
