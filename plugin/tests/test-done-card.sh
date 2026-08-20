#!/usr/bin/env bash
# 완료 카드 — 일이 끝나면 **뭐가 바뀌었는지** 말하고 화면을 열 수 있게 한다(스펙 §3·§4).
#
# 지금은 방이 "끝났어요"라고만 한다. 형 입장에선 뭘 했는지, 볼 게 있는지 알 수 없어서
# 결국 대화를 처음부터 읽어야 한다.
#
# 비용 규칙: 요약은 **이미 도는 git 호출**에서 뽑는다. 완료 판정이 status --porcelain 을
# 한 번 부르는데, 그 출력에 파일 목록이 이미 들어 있다 — 또 부르면 순수한 낭비다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
from pathlib import Path

import marina_rooms as rooms

wt = Path("/tmp/wt-done")
calls = []


def fake_git(args, cwd):
    calls.append(args[0])
    if args[0] == "status":
        return " M web/app.py\0?? docs/새문서.md\0 M web/style.css\0"
    return ""


rooms._changes_cache.clear()
요약 = rooms.change_summary(wt, runner=fake_git, now=100.0)

# ① 몇 개가 바뀌었는지 + 이름 몇 개. 경로 전체는 폰에서 못 읽는다 — 파일명만.
assert 요약["files"] == 3, 요약
assert "app.py" in 요약["names"] and "새문서.md" in 요약["names"], 요약
assert all("/" not in name for name in 요약["names"]), 요약   # 경로가 아니라 이름

# ② 목록이 길어도 몇 개만 — 카드 한 장이다.
많음 = rooms.change_summary(wt, runner=lambda a, c: "".join(f" M f{i}.py\0" for i in range(30)),
                            now=200.0)
assert 많음["files"] == 30 and len(많음["names"]) <= 4, 많음

# ③ **git 을 또 부르지 않는다.** 완료 판정이 방금 부른 결과를 그대로 쓴다.
rooms._changes_cache.clear()
calls.clear()
rooms.room_has_changes(wt, runner=fake_git, now=300.0)
쓴횟수 = len(calls)
rooms.change_summary(wt, runner=fake_git, now=300.0)
assert len(calls) == 쓴횟수, f"요약 때문에 git 을 또 불렀다: {calls}"

# ④ 중첩 레포는 여기서도 뺀다 — 완료 판정과 규칙이 갈라지면 안 된다.
import tempfile
with tempfile.TemporaryDirectory() as tmp:
    sub = Path(tmp) / "sub"
    (sub / ".git").mkdir(parents=True)
    rooms._changes_cache.clear()
    only = rooms.change_summary(Path(tmp), runner=lambda a, c: "?? sub/\0 M real.py\0", now=400.0)
    assert only["files"] == 1 and only["names"] == ["real.py"], only
# ⑤ **마리나 자기 폴더는 형 작업물이 아니다.** .workspace 에 별칭·메모를 쓰는데(marina_paths),
# 그걸 세면 마리나가 파일 하나 건드린 것만으로 방이 "완료"가 된다 — 실측으로 그렇게 됐다.
rooms._changes_cache.clear()
자기폴더 = rooms.change_summary(wt, runner=lambda a, c: "?? .workspace/\0 M real.py\0", now=500.0)
assert 자기폴더["files"] == 1 and 자기폴더["names"] == ["real.py"], 자기폴더
rooms._changes_cache.clear()
assert rooms.room_has_changes(wt, runner=lambda a, c: "?? .workspace/\0" if a[0] == "status" else "",
                              now=510.0) is False, "마리나 자기 폴더만으로 완료가 됐다"

# ⑥ 커밋까지 끝낸 방도 **뭘 했는지** 말한다. 파일 0개라고 카드가 사라지면, 목록엔 "끝났어요"
# 인데 대화엔 아무것도 없는 어긋남이 생긴다(실측: 완료 방 3개 중 2개가 그랬다).
rooms._changes_cache.clear()
커밋만 = rooms.change_summary(wt, now=600.0, runner=lambda a, c:
                              "" if a[0] == "status" else "a1 첫 커밋\nb2 두번째\n")
assert 커밋만["files"] == 0 and 커밋만["commits"] == 2, 커밋만
print("ok 완료 요약: 개수·이름·추가 git 없음·중첩 레포·마리나 폴더 제외·커밋 수")
PY

# ⑤ 완료된 방에만 실린다 — 아직 도는 방에 "끝났어요 카드"가 뜨면 못 믿는다.
PYTHONPATH="$SCR" python3 - "$HERE" <<'PY2'
import sys
from pathlib import Path

import marina_mobile as mm

root = Path(sys.argv[1]).resolve()
mm.discover_all_roots = lambda refresh=False: [root]
mm.worktree_labels = lambda value: {"id": "wt", "alias": "방", "projectLabel": "p"}
mm.term_list = lambda: {"sessions": []}
mm._live_agent_cwds = lambda refresh=False: set()
mm.mobile_pending_question = lambda source, sid: None
mm.mobile_hidden = lambda: []
mm.room_has_changes = lambda root_arg, **kw: True
mm.change_summary = lambda root_arg, **kw: {"files": 2, "names": ["a.py", "b.py"]}

mm.agents_payload = lambda r, refresh=False, include_all=False, limit=None: [
    {"source": "claude", "sid": "s1", "title": "A", "status": "completed", "ts": 10}]
방 = mm.mobile_state()["rooms"][0]
assert 방["status"] == "완료", 방["status"]
assert 방["done"]["files"] == 2, 방

mm.agents_payload = lambda r, refresh=False, include_all=False, limit=None: [
    {"source": "claude", "sid": "s1", "title": "A", "status": "working", "ts": 10}]
도는방 = mm.mobile_state()["rooms"][0]
assert not 도는방.get("done"), f"아직 도는데 완료 카드가 붙었다: {도는방.get('done')}"
print("ok 완료 카드는 끝난 방에만 붙는다")
PY2

# ⑥ 화면에 카드가 그려진다 — 데이터만 보내고 안 그리면 형은 못 본다.
PYTHONPATH="$SCR" python3 - <<'PY3'
from marina_mobile import render_mobile_html

html = render_mobile_html()
블록 = html[html.find("// DONE_CARD_START"):html.find("// DONE_CARD_END")]
assert 블록, "DONE_CARD 블록이 없다"
assert "끝났어요" in 블록 and "개" in 블록, 블록[:300]
# 커밋만 있는 방(파일 0개)도 카드가 뜬다 — 안 뜨면 목록의 "끝났어요"와 어긋난다.
assert "커밋" in 블록, 블록[:400]
assert "data-open-preview" in 블록, "화면 보기 버튼이 없다"
# **보이는지**까지 본다. 예전에 생각중 표시가 그리드에 잘려 "렌더는 되는데 안 보이는" 사고를
# 냈고, 완료 카드도 같은 자리에서 실측 offsetHeight 0 이었다.
assert "#doneSlot { position: absolute" in html, "완료 카드가 그리드에 잘린다"
assert "hasDone" in html, "카드가 대화 마지막 줄을 가린다"
print("ok 완료 카드가 화면에 있다")
PY3

echo "PASS test-done-card"
