#!/usr/bin/env bash
# "끝났어요" 는 **그 대화가 한 일**로만 — 형: "끝났어요 하고 뜨는 거 똑바로 워킹 안 하는 거 같은데".
# 실측(2026-09-28): 진단만 한 대화에 옛 백업 파일(settings.local.json.bak-…)로 "파일 4개", 브랜치에 쌓인
# 커밋 20개가 이번 일처럼 떴다. 워크트리 전체 git status 를 그대로 썼기 때문.
# 잠그는 계약:
#   ① 파일 = 폴더 변경분 ∩ 그 대화가 손댄 경로(새 폴더 `dir/` 는 그 안을 만졌으면 맞다).
#   ② 커밋 = 안 올라간 커밋 중 그 대화 시작 뒤에 생긴 것.
#   ③ 끝난 대화만 본다. 손댄 게 없으면 판정은 False, 카드는 비어 있다.
#   ④ 손댄 경로는 기록에서 뽑고(Write/Edit/셸 쓰기, 건네주기는 제외), 늘어난 부분만 이어 읽는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import json, tempfile
from pathlib import Path
import marina_rooms as mr
import marina_sessions as ms

root = Path("/r/wt")
요약 = {"paths": ["src/a.py", "newdir/", "settings.local.json.bak-1"], "commitTimes": [300, 200, 100]}
손댐 = {("claude", "s1"): (frozenset({"src/a.py", "newdir/x.md"}), 150.0),
        ("claude", "s2"): (frozenset(), 250.0)}
touched = lambda r, source, sid: 손댐[(source, sid)]
agents = [{"source": "claude", "sid": "s1", "status": "completed"},
          {"source": "claude", "sid": "s2", "status": "completed"},
          {"source": "claude", "sid": "s3", "status": "working"}]
changed, done = mr.room_own_changes(root, agents, touched=touched, summary=요약)
# ①
assert done["paths"] == ["src/a.py", "newdir/"], done
assert done["files"] == 2 and "settings.local.json.bak-1" not in done["names"], done
# ②
assert done["commits"] == 2, "대화 시작(150) 뒤 커밋은 200·300 두 개"
assert changed("claude", "s2") is True, "s2 는 파일은 없어도 시작(250) 뒤 커밋 300 이 있다"
# ③
assert changed("claude", "s1") is True
assert changed("claude", "s3") is False, "도는 대화로 판정했다"
changed, done = mr.room_own_changes(root, [{"source": "claude", "sid": "s2", "status": "completed"}],
                                    touched=lambda r, s, i: (frozenset(), 400.0), summary=요약)
assert changed("claude", "s2") is False and done["files"] == 0 and done["commits"] == 0, done
changed, done = mr.room_own_changes(root, [{"source": "claude", "sid": "s1", "status": "idle"}],
                                    touched=touched, summary=요약)
assert changed("claude", "s1") is False and done["files"] == 0
# 표본(200)이 아니라 매칭 목록으로 가른다 — 201번째 뒤를 고친 대화가 "0개"가 되면 안 된다(리뷰 지적).
많음 = [f"f{i}.py" for i in range(300)]
changed, done = mr.room_own_changes(root, [{"source": "claude", "sid": "s1", "status": "completed"}],
                                    touched=lambda r, s, i: (frozenset({"f250.py"}), 0.0),
                                    summary={"paths": 많음[:200], "matchPaths": 많음, "commitTimes": []})
assert done["files"] == 1 and changed("claude", "s1"), done
print("ok ①②③ 그 대화 몫만 센다")

# ④ 실제 기록 파일로.
with tempfile.TemporaryDirectory() as d:
    wt = Path(d).resolve() / "wt"
    (wt / "src").mkdir(parents=True)
    ms._TEMP_ROOTS = ()   # 픽스처가 임시 폴더라 제외 규칙을 끈다
    tp = Path(d) / "t.jsonl"
    ms.agent_transcript_path = lambda r, source, sid: tp
    def line(obj): return json.dumps(obj, ensure_ascii=False) + "\n"
    def tool(name, inp): return line({"type": "assistant", "timestamp": "2026-09-28T08:00:05.000Z",
                                      "message": {"content": [{"type": "tool_use", "name": name, "input": inp}]}})
    tp.write_text(line({"type": "user", "timestamp": "2026-09-28T08:00:00.000Z", "message": {"content": "해줘"}})
                  + tool("Write", {"file_path": str(wt / "src/a.py"), "content": "x"})
                  + tool("SendUserFile", {"files": [str(wt / "보낸.pdf")]}), encoding="utf-8")
    paths, start = ms.session_touched_paths(wt, "claude", "s1")
    assert paths == frozenset({"src/a.py"}), paths
    assert abs(start - 1790582400.0) < 1, start
    # 이어 쓰기 — 늘어난 부분만 읽어도 합쳐진다. 반쯤 쓴 줄은 다음에 읽는다.
    with tp.open("a", encoding="utf-8") as h:
        h.write(tool("Edit", {"file_path": str(wt / "src/b.py"), "old_string": "a", "new_string": "b"}))
        h.write('{"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Write", "input": {"file_path": "')
    paths, _ = ms.session_touched_paths(wt, "claude", "s1")
    assert paths == frozenset({"src/a.py", "src/b.py"}), paths
    with tp.open("a", encoding="utf-8") as h:
        h.write(str(wt / "src/c.py") + '", "content": "x"}}]}}\n')
    paths, _ = ms.session_touched_paths(wt, "claude", "s1")
    assert paths == frozenset({"src/a.py", "src/b.py", "src/c.py"}), "반쯤 쓴 줄을 버렸다"
    # 서브에이전트가 고친 것도 그 세션 몫이다 — 계획을 맡겨 돌리는 세션은 수정이 전부 거기 있다.
    sub = tp.parent / "s1" / "subagents"
    sub.mkdir(parents=True)
    (sub / "agent-a1.jsonl").write_text(tool("Edit", {"file_path": str(wt / "src/sub.py"), "old_string": "a", "new_string": "b"}),
                                        encoding="utf-8")
    paths, _ = ms.session_touched_paths(wt, "claude", "s1")
    assert "src/sub.py" in paths, paths
print("ok ④ 기록에서 손댄 경로를 이어 읽는다")
PY
echo "PASS test-room-own-changes"
