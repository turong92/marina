#!/usr/bin/env bash
# 방 모델 — 상태 접기·완료 판정·조립의 순수 계약.
#
# 스펙 §5: 새 어휘를 만들지 않고 지금 캐논 6개를 5개로 **접기만** 한다. 캐논을 그대로 두면
# 상태 판정이 두 벌로 갈라질 일이 없다(지금 겪는 문제가 바로 그것이다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from marina_rooms import ROOM_STATUS_ORDER, room_status

# 그대로 대응되는 것들
assert room_status("working", False) == "작업중"
assert room_status("idle", False) == "대기"
assert room_status("failed", False) == "문제"
# blocked = 권한·질문 대기 → 사람이 답해야 진행된다
assert room_status("blocked", False) == "응답필요"
# waiting = 프로세스가 살아 입력을 기다림. 멤버 관점에선 blocked 와 요구가 같다(스펙 §5)
assert room_status("waiting", False) == "응답필요"

# **completed 는 두 갈래다**(스펙 §4): 바뀐 파일이 있으면 완료, 없으면 대기.
# completed 만으로 완료를 판정하면 질문만 하고 끝난 턴까지 "일 끝났어요"가 된다.
assert room_status("completed", True) == "완료"
assert room_status("completed", False) == "대기"

# 모르는 값은 대기로 — CLI 가 새 어휘를 내놔도 화면이 깨지지 않아야 한다.
assert room_status("", False) == "대기"
assert room_status("무슨상태", False) == "대기"

# 우선순위: 방 목록에서 놓치면 안 되는 순서(스펙 §2)
assert ROOM_STATUS_ORDER == ("문제", "응답필요", "작업중", "완료", "대기"), ROOM_STATUS_ORDER
print("ok 상태 접기: 6개 → 5개, completed 는 변경 유무로 갈린다")
PY

# 완료 판정의 재료 — "바뀐 파일이 있나". 방 목록 경로에서 git 을 부르는 **유일한** 자리라
# 캐시 뒤에 둔다. 폴마다 워크트리마다 git 을 돌리면 전에 잡은 "초당 git 40회"가 재현된다.
PYTHONPATH="$SCR" python3 - <<'PY'
from pathlib import Path

import marina_rooms as rooms

root = Path("/tmp/wt-a")
_TTL_HALF = rooms._CHANGES_TTL_S / 2
calls = []


def fake_git(args, cwd):
    calls.append(tuple(args))
    if args[0] == "status":
        # **-z(NUL 구분)로 받아야 한다.** 기본 출력은 비ASCII 이름을 `"\355..."` 로
        # 이스케이프해서, 한글 폴더가 중첩 레포여도 경로가 안 맞아 "내 변경"으로 세어진다 —
        # 그 워크트리는 영구히 "완료"로 돌아간다(형은 한글 이름을 쓴다).
        assert "-z" in args, f"인용된 출력을 읽고 있다: {args}"
        return fake_git.status
    if args[0] == "log":
        return fake_git.log
    return ""


fake_git.status, fake_git.log = "", ""

# ① 아무것도 없으면 False
rooms._changes_cache.clear()
assert rooms.room_has_changes(root, runner=fake_git, now=100.0) is False

# ② 미커밋 변경이 있으면 True
rooms._changes_cache.clear()
fake_git.status = " M plugin/scripts/marina_rooms.py\0?? new.txt\0"
assert rooms.room_has_changes(root, runner=fake_git, now=100.0) is True

# ③ 커밋까지 끝냈어도 True — base 보다 앞선 커밋이 있으면 "볼 만한 결과"가 있다.
rooms._changes_cache.clear()
fake_git.status, fake_git.log = "", "a1b2c3 첫 커밋"
assert rooms.room_has_changes(root, runner=fake_git, now=100.0) is True

# ④ 캐시: 같은 워크트리를 연달아 물어도 git 을 다시 부르지 않는다.
rooms._changes_cache.clear()
calls.clear()
rooms.room_has_changes(root, runner=fake_git, now=100.0)
first = len(calls)
assert first > 0
rooms.room_has_changes(root, runner=fake_git, now=100.0 + _TTL_HALF)
assert len(calls) == first, f"캐시 안인데 git 을 또 불렀다: {calls}"

# ⑤ 수명이 지나면 다시 본다 — 커밋하고 나면 곧 반영돼야 한다.
rooms.room_has_changes(root, runner=fake_git, now=100.0 + rooms._CHANGES_TTL_S + 1)
assert len(calls) > first

# ⑥ git 이 실패해도 예외를 던지지 않는다 — 깨진 워크트리 하나가 방 목록을 통째로 죽이면 안 된다.
def broken(args, cwd):
    raise OSError("git 없음")


rooms._changes_cache.clear()
assert rooms.room_has_changes(root, runner=broken, now=200.0) is False
# 실패도 **더 긴 수명으로** 캐시한다. 안 하면 5초 타임아웃을 폴마다 다시 문다 — 깨진 워크트리
# 둘이면 폰 응답이 10초다(git 아끼려고 만든 캐시가 정반대로 작동).
assert str(root) in rooms._changes_cache
calls.clear()
rooms.room_has_changes(root, runner=broken, now=200.0 + _TTL_HALF)
assert not calls, "실패 직후에 또 git 을 불렀다"
rooms.room_has_changes(root, runner=fake_git, now=200.0 + rooms._CHANGES_FAIL_TTL_S + 1)
assert calls, "실패 수명이 지났는데 영영 다시 안 본다"
assert rooms._CHANGES_FAIL_TTL_S > rooms._CHANGES_TTL_S, "실패를 더 오래 쉬어야 비용이 준다"

# ⑦-a untracked 는 **세되 중첩 git 레포만 뺀다.** 둘 중 하나로 치우치면 각각 이렇게 틀린다:
#   전부 세면  → 서브레포를 품은 레포가 영구 dirty(실측 28개 중 17개) → 늘 "완료"
#   전부 빼면(-uno) → 새 파일만 만들고 끝낸 턴이 사라진다. 이 Room API 의 계획 문서가 그랬다.
import subprocess
import tempfile

with tempfile.TemporaryDirectory() as tmp:
    wt = Path(tmp)
    (wt / "sub").mkdir()
    (wt / "sub" / ".git").mkdir()          # 중첩 레포 — 남의 것이다
    assert rooms._has_own_changes("?? sub/\0", wt) is False
    # 진짜 새 파일은 남는다 — 문서 하나 새로 쓴 세션도 결과가 있는 것이다.
    assert rooms._has_own_changes("?? docs/plan.md\0", wt) is True
    # 평범한 새 폴더(레포 아님)도 결과다.
    (wt / "plain").mkdir()
    assert rooms._has_own_changes("?? plain/\0", wt) is True
    # 추적 중인 파일 수정·리네임·충돌은 당연히 결과다.
    assert rooms._has_own_changes(" M app.py\0?? sub/\0", wt) is True
    assert rooms._has_own_changes("R  new.py\0old.py\0", wt) is True
    assert rooms._has_own_changes("UU merge.py\0", wt) is True
    assert rooms._has_own_changes("", wt) is False

    # **한글 이름 중첩 레포** — 여기가 실제로 깨졌던 자리다. git 은 기본 설정에서 비ASCII 를
    # `"\355\225\234..."` 로 이스케이프해 내보내, 경로가 안 맞아 "내 변경"으로 세어졌다.
    # 형은 한글 이름을 쓴다 — 그런 폴더 하나면 그 워크트리가 영구히 "완료"로 돌아간다.
    (wt / "한글레포").mkdir()
    (wt / "한글레포" / ".git").mkdir()
    (wt / "한글레포" / "안의파일.txt").write_text("x", encoding="utf-8")   # 빈 폴더는 git 이 안 센다
    subprocess.run(["git", "-C", str(wt), "init", "-q"], check=True)
    real = subprocess.run(["git", "-C", str(wt), "status", "--porcelain", "-z"],
                          capture_output=True, text=True, check=True).stdout
    assert "한글레포/" in real, f"전제 확인 실패(-z 인데 인용됐다): {real!r}"
    assert rooms._has_own_changes(real, wt) is False, \
        f"한글 이름 중첩 레포를 내 변경으로 셌다 — S1 오탐이 그대로 돌아온다: {real!r}"

    # 권한이 막힌 폴더에서도 안 터진다 — py3.9 의 Path.exists() 는 EACCES 를 던진다.
    막힌곳 = wt / "막힘"
    막힌곳.mkdir()
    막힌곳.chmod(0o000)
    try:
        assert rooms._has_own_changes("?? 막힘/\0", wt) is True   # 판단 포기 = 내 변경으로 센다
    finally:
        막힌곳.chmod(0o755)

# ⑦ git 이 rc≠0 이면 **'변경 없음'과 구별**해야 한다 — 빈 stdout 을 정답으로 믿으면
# "다 해놨는데 대기로 나온다"가 되고 그 오답이 캐시된다.
import subprocess as sp

real = sp.run(["git", "-C", "/tmp", "status", "--porcelain", "-uno"],
              capture_output=True, text=True)
assert real.returncode != 0 and not real.stdout, real   # 전제 확인: 실패인데 stdout 은 빈다
try:
    rooms._git(["status", "--porcelain", "-uno"], Path("/tmp"))
    raise SystemExit("FAIL: git 실패를 성공으로 읽었다")
except rooms.GitFailed:
    pass

# ⑦ 캐시가 무한히 크지 않는다 — 워크트리는 생겼다 사라지므로 죽은 경로가 계속 쌓인다.
# **만료된 것은 크기와 무관하게 턴다.** 예전엔 상한(200) 안쪽에서만 청소해서, 워크트리
# 28개인 실사용에서는 청소가 한 번도 안 돌았다(실측).
rooms._changes_cache.clear()
rooms._summary_cache.clear()
for i in range(28):
    rooms.room_has_changes(Path(f"/tmp/wt-{i}"), runner=fake_git, now=1000.0)
# 아직 다 살아 있는 항목은 안 버린다(버리면 방금 잰 것을 또 재게 된다).
assert len(rooms._changes_cache) == 28, len(rooms._changes_cache)
rooms.room_has_changes(Path("/tmp/새것"), runner=fake_git,
                       now=1000.0 + rooms._CHANGES_TTL_S + 1)
assert len(rooms._changes_cache) == 1, f"만료된 것을 안 버렸다: {len(rooms._changes_cache)}"
# 요약 캐시도 같이 — 지운 방 요약이 데몬이 죽을 때까지 남으면 안 된다.
assert len(rooms._summary_cache) <= 1, f"요약 캐시가 안 치워진다: {len(rooms._summary_cache)}"
print("ok 변경 판정: 미커밋·앞선 커밋·캐시·실패 내성")
PY

# 방 조립 — 워크트리 하나 + 그 안의 세션들이 탭(스펙 §2).
PYTHONPATH="$SCR" python3 - <<'PY'
from pathlib import Path

from marina_rooms import build_room, fold_status, room_status

labels = {"id": "wt-1", "alias": "결제정리", "projectLabel": "mdc-main",
          "sessionTitle": "결제 플로우 정리", "projectId": "p1", "source": "registry"}


def no_questions(source, sid):
    return None


# ① 탭이 하나면 그 상태가 방 상태다.
room = build_room(Path("/wt"), labels, [
    {"source": "claude", "sid": "s1", "title": "결제 플로우 정리", "status": "working", "ts": 100},
], has_changes=False, questions=no_questions)
assert room["status"] == "작업중", room
assert len(room["tabs"]) == 1 and room["tabs"][0]["primary"] is True
assert room["lastAt"] == 100, room
assert room["canShip"] is False, "배포는 아직 자리만 잡아둔다(스펙 확장 지점)"

# ② 이름은 **하나**다 — 배경의 "이름이 세 번 반복된다"가 여기서 다시 나오면 안 된다.
assert room["name"] == "결제정리", room["name"]
assert "wt-1" not in room["name"] and "mdc-main" not in room["name"], room["name"]

# ③ 탭이 여럿이면 **사람 조치가 필요한 것**이 방 상태로 올라온다(스펙 §2 우선순위).
room = build_room(Path("/wt"), labels, [
    {"source": "claude", "sid": "s1", "title": "A", "status": "idle", "ts": 100},
    {"source": "codex", "sid": "s2", "title": "B", "status": "blocked", "ts": 50},
], has_changes=False, questions=no_questions)
assert room["status"] == "응답필요", room["status"]
assert len(room["tabs"]) == 2

# ④ primary = 마지막 활동이 가장 최근인 탭. 방을 열면 그게 먼저 열린다(스펙 §2).
assert room["tabs"][0]["sid"] == "s1" and room["tabs"][0]["primary"] is True
assert room["tabs"][1]["primary"] is False

# ⑤ 답을 기다리는 질문이 있으면 그 탭은 응답필요다 — 실행 중이 아니라 형 차례다.
def asking(source, sid):
    return {"token": "q1"} if sid == "s1" else None


room = build_room(Path("/wt"), labels, [
    {"source": "claude", "sid": "s1", "title": "A", "status": "working", "ts": 100},
], has_changes=False, questions=asking)
assert room["tabs"][0]["status"] == "응답필요", room["tabs"]
assert room["status"] == "응답필요"

# ⑥ 세션이 하나도 없는 워크트리도 방이다(아직 아무도 말 안 건 일감).
room = build_room(Path("/wt"), labels, [], has_changes=False, questions=no_questions)
assert room["tabs"] == [] and room["status"] == "대기", room

# ⑦ 완료는 변경 유무로 갈린다(스펙 §4) — 조립 단계에서도 그대로.
done = [{"source": "claude", "sid": "s1", "title": "A", "status": "completed", "ts": 10}]
assert build_room(Path("/wt"), labels, done, has_changes=True, questions=no_questions)["status"] == "완료"
assert build_room(Path("/wt"), labels, done, has_changes=False, questions=no_questions)["status"] == "대기"

# ⑧ 별칭이 없으면 **첫 탭 제목** → id 순. labels["sessionTitle"] 은 쓰지 않는다 — 세션이
# 없을 때 그 값이 HEAD 커밋 제목으로 떨어져, 빈 워크트리가 남의 커밋 작업을 하던 방처럼 보인다.
noname = build_room(Path("/wt"), {**labels, "alias": ""},
                    [{"source": "claude", "sid": "s1", "title": "대화 제목", "status": "idle", "ts": 1}],
                    has_changes=False, questions=no_questions)
assert noname["name"] == "대화 제목", noname["name"]
empty = build_room(Path("/wt"), {**labels, "alias": ""}, [], has_changes=False, questions=no_questions)
assert empty["name"] == "wt-1", empty["name"]
bare = build_room(Path("/wt"), {"id": "wt-9"}, [], has_changes=False, questions=no_questions)
assert bare["name"] == "wt-9", bare["name"]

# ⑨ **부르는 지문(mark)** — 접어둔 방을 다시 펼지는 이 값으로 판단한다.
# 상태 문자열만 비교하면 "같은 상태의 새 사건"을 못 본다: 질문 뜬 방을 접었는데 더 급한 걸
# 새로 물으면, 상태는 여전히 응답필요라 영영 안 펴진다 — 접기가 형을 가두는 도구가 된다.
질문방 = build_room(Path("/wt"), labels,
                    [{"source": "claude", "sid": "s1", "title": "A", "status": "working", "ts": 5}],
                    has_changes=False, questions=lambda source, sid: {"token": "tok-1"})
다른질문 = build_room(Path("/wt"), labels,
                      [{"source": "claude", "sid": "s1", "title": "A", "status": "working", "ts": 5}],
                      has_changes=False, questions=lambda source, sid: {"token": "tok-2"})
assert 질문방["mark"] and 질문방["mark"] != 다른질문["mark"], (질문방["mark"], 다른질문["mark"])

# 실패는 **어느 세션이** 실패했는지로 구별한다(다른 세션이 새로 실패하면 다시 부른다).
실패1 = build_room(Path("/wt"), labels,
                   [{"source": "claude", "sid": "s1", "title": "A", "status": "failed", "ts": 5}],
                   has_changes=False, questions=no_questions)
실패2 = build_room(Path("/wt"), labels,
                   [{"source": "claude", "sid": "s2", "title": "B", "status": "failed", "ts": 5}],
                   has_changes=False, questions=no_questions)
assert 실패1["mark"] != 실패2["mark"], (실패1["mark"], 실패2["mark"])
# **같은 세션이 다시 실패**해도 구별된다 — sid 만 쓰면 지문이 그대로라 접어둔 방이 안 펴진다.
재실패 = build_room(Path("/wt"), labels,
                    [{"source": "claude", "sid": "s1", "title": "A", "status": "failed", "ts": 900}],
                    has_changes=False, questions=no_questions)
assert 실패1["mark"] != 재실패["mark"], (실패1["mark"], 재실패["mark"])

# stale(기준 방 밖) 탭도 상태 계산에서 빠진다 — hidden 과 뜻은 다르지만 안 세는 건 같다.
섞인방 = build_room(Path("/wt"), labels,
                    [{"source": "claude", "sid": "s1", "title": "A", "status": "idle", "ts": 10}],
                    has_changes=False, questions=no_questions)
섞인방["tabs"].append({"source": "claude", "sid": "옛것", "status": "문제", "ts": 999, "stale": True})
from marina_rooms import finalize_room
finalize_room(섞인방)
assert 섞인방["status"] == "대기" and 섞인방["lastAt"] == 10, 섞인방

# 완료는 한 번뿐인 사건이라 고정값 — 완료인 채로 치운 방이 파일 시각이 갱신됐다고 다시
# 들이밀리면 안 된다(그게 접기를 무의미하게 만든 예전 결함이다).
완료방 = build_room(Path("/wt"), labels, done, has_changes=True, questions=no_questions)
늦은완료 = build_room(Path("/wt"), labels,
                      [{**done[0], "ts": 999_999}], has_changes=True, questions=no_questions)
assert 완료방["mark"] == 늦은완료["mark"] == "done", (완료방["mark"], 늦은완료["mark"])

# 부르지 않는 상태엔 지문이 없다 — 작업중은 시각이 계속 변해도 접힌 채여야 한다.
assert room_status and build_room(Path("/wt"), labels,
    [{"source": "claude", "sid": "s1", "title": "A", "status": "working", "ts": 1}],
    has_changes=False, questions=no_questions)["mark"] == ""

# ⑩ 접기 규칙 자체
assert fold_status(["대기", "작업중"]) == "작업중"
assert fold_status(["작업중", "문제"]) == "문제"
assert fold_status([]) == "대기"
print("ok 방 조립: 이름 하나·탭·우선순위·primary·질문·빈 방")
PY

echo "PASS test-rooms-model"
