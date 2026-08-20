#!/usr/bin/env bash
# 방·대화 지우기 — **지우기 전에 잃을 게 없는 상태로 만든다**(스펙 §7).
#
# 형 결정: "1. 따로 빼 2. 지웠다고 해 그냥". 미커밋 변경이 있으면 막는 게 아니라 wip 브랜치로
# 먼저 보관하고 지운다. 막는 설계는 사람의 주의력에 기대는 것이라, 형이 안 보면 그 방은
# 영영 안 치워진다.
#
# 근거(스펙에서 확인): remove_worktree 의 브랜치 정리는 delete_merged_branch 라 **머지 안 된
# 브랜치는 안 지운다**. 즉 커밋만 해두면 폴더가 사라져도 작업은 브랜치에 남는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 진짜 git 저장소로 확인한다 — 보관이 됐는지는 git 이 답해야 한다.
git init -q "$TMP/repo" && cd "$TMP/repo"
git config user.email t@t && git config user.name t
echo base > base.txt && git add -A && git commit -qm base
echo 작업중 > wip.txt && mkdir -p plain && echo 새것 > plain/new.txt   # 미커밋 + untracked
# **중첩 git 레포**를 만든다 — mdc-main 계열이 정확히 이 구조다(ai-api·avatar·be-api·web-app-monorepo).
# 부모에서 `git add -A` 는 중첩 레포의 **gitlink 한 줄만** 담는다(실증) — 그 안의 미커밋 작업은
# 어디에도 안 담기고, 삭제 때 `worktree remove --force` 로 통째로 사라진다.
git init -q sub && git -C sub config user.email t@t && git -C sub config user.name t
echo v1 > sub/api.py && git -C sub add -A && git -C sub commit -qm subinit
echo "중요한 서브레포 작업" > sub/api.py && echo 새것 > sub/newthing.py

PYTHONPATH="$SCR" python3 - "$TMP/repo" <<'PY'
import subprocess
import sys
from pathlib import Path

from marina_lifecycle import stash_before_delete

repo = Path(sys.argv[1])


def git(*args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True).stdout.strip()


원래브랜치 = git("branch", "--show-current")
결과 = stash_before_delete(repo, "결제 정리")

# ① 보관 브랜치가 생겼고, 이름에 **방 이름과 날짜**가 있다 — 목록만 봐도 뭘 건질지 안다.
보관 = 결과["branch"]
assert 보관.startswith("wip/"), 보관
assert "결제" in 보관 or "wip/" in 보관, 보관
assert 보관 in git("branch", "--list", 보관), git("branch")

# ② **untracked 까지** 담겼다 — 새로 만든 파일이 제일 잃기 쉽다.
담긴것 = git("show", "--name-only", "--format=", 보관)
assert "wip.txt" in 담긴것 and "plain/new.txt" in 담긴것, 담긴것

# ②-b **중첩 레포 안의 작업도 지켜져야 한다.** 부모의 add -A 는 gitlink 한 줄만 담는다(실증) —
# 그 안의 미커밋은 어디에도 안 담기고 삭제 때 --force 로 사라진다. mdc-main 은 중첩 레포가 4개다.
서브 = 결과.get("subrepos") or {}
assert "sub" in 서브, f"중첩 레포를 보관 안 했다: {결과}"
서브담긴것 = subprocess.run(["git", "-C", str(repo / "sub"), "show", "--name-only", "--format=",
                            서브["sub"]], capture_output=True, text=True).stdout
assert "api.py" in 서브담긴것 and "newthing.py" in 서브담긴것, 서브담긴것

# ③ 원래 브랜치로 돌아와 있다 — 보관하느라 남의 자리를 옮겨두면 안 된다.
assert git("branch", "--show-current") == 원래브랜치, git("branch", "--show-current")

# ④ 보관 브랜치는 **머지되지 않은 상태**라 삭제 정리에서 살아남는다(스펙의 근거).
머지됨 = git("branch", "--merged", "HEAD")
assert 보관 not in 머지됨, f"보관 브랜치가 머지된 것으로 잡힌다 — 같이 지워진다: {머지됨}"

# ⑤ 지울 게 없으면 아무것도 안 만든다 — 빈 보관 브랜치가 쌓이면 목록만 더러워진다.
# (중첩 레포까지 깨끗이 만들어야 한다 — 거기에 남아 있으면 보관할 게 있는 게 맞다.)
for 곳 in (repo, repo / "sub"):
    subprocess.run(["git", "-C", str(곳), "checkout", "-q", "--", "."], check=False)
    subprocess.run(["git", "-C", str(곳), "clean", "-qfd"], check=False)
빈것 = stash_before_delete(repo, "빈 방")
assert 빈것["branch"] == "" and not 빈것["subrepos"], 빈것
assert 빈것["saved"] is False, 빈것
# ⑥ **하나가 실패하면 전부 되돌린다.** 앞서 보관한 레포는 커밋+체크아웃 백으로 워킹트리가
# 깨끗해지는데 삭제는 거부되어, 형 눈엔 그 폴더의 작업만 증발한 것으로 보인다(실측 지적).
# 두 번째 레포에 index.lock 을 걸어 실패를 만든다 — 그 워크트리에서 CLI 가 git 을 돌리면
# 실제로 나는 상황이다.
sub2 = repo / "sub2"
subprocess.run(["git", "init", "-q", str(sub2)], check=True)
for k, v in (("user.email", "t@t"), ("user.name", "t")):
    subprocess.run(["git", "-C", str(sub2), "config", k, v], check=True)
(sub2 / "b.py").write_text("v1", encoding="utf-8")
subprocess.run(["git", "-C", str(sub2), "add", "-A"], check=True)
subprocess.run(["git", "-C", str(sub2), "commit", "-qm", "init"], check=True)

(repo / "sub" / "api.py").write_text("서브1 작업", encoding="utf-8")
(sub2 / "b.py").write_text("서브2 작업", encoding="utf-8")
(repo / "wip.txt").write_text("루트 작업", encoding="utf-8")
(sub2 / ".git" / "index.lock").write_text("", encoding="utf-8")   # 두 번째를 막는다

def wip목록(곳):
    out = subprocess.run(["git", "-C", str(곳), "branch", "--list", "wip/*"],
                         capture_output=True, text=True).stdout
    return sorted(line.strip("* ").strip() for line in out.splitlines() if line.strip())


앞서있던것 = wip목록(repo / "sub")     # ②에서 정상 보관한 것 — 이건 남아 있는 게 맞다
try:
    stash_before_delete(repo, "부분 실패")
    raise SystemExit("FAIL: 실패했어야 한다")
except ValueError:
    pass
finally:
    (sub2 / ".git" / "index.lock").unlink(missing_ok=True)

# 앞서 보관한 서브레포의 작업이 **워킹트리에 그대로** 있어야 한다.
남은것 = subprocess.run(["git", "-C", str(repo / "sub"), "status", "--porcelain"],
                        capture_output=True, text=True).stdout
assert "api.py" in 남은것, f"앞 서브레포 작업이 워킹트리에서 사라졌다: {남은것!r}"
assert (repo / "sub" / "api.py").read_text() == "서브1 작업", (repo / "sub" / "api.py").read_text()
새로생긴것 = [이름 for 이름 in wip목록(repo / "sub") if 이름 not in 앞서있던것]
assert not 새로생긴것, f"되돌렸는데 이번 보관 브랜치가 남았다: {새로생긴것}"

# ⑦ **까다로운 파일 이름도 담긴다.** 경로를 인자로 주면 `:` 로 시작하는 이름이
# pathspec magic 으로 읽혀 통째로 실패한다(실측) — 그러면 보관이 안 되고 삭제도 막힌다.
import shutil

tricky = repo.parent / "tricky"
shutil.rmtree(tricky, ignore_errors=True)
subprocess.run(["git", "init", "-q", str(tricky)], check=True)
for k, v in (("user.email", "t@t"), ("user.name", "t")):
    subprocess.run(["git", "-C", str(tricky), "config", k, v], check=True)
(tricky / "base").write_text("b", encoding="utf-8")
subprocess.run(["git", "-C", str(tricky), "add", "-A"], check=True)
subprocess.run(["git", "-C", str(tricky), "commit", "-qm", "b"], check=True)
for 이름 in (":colon.txt", "-leading.txt", "한글 파일.txt", "space name.txt"):
    (tricky / 이름).write_text("x", encoding="utf-8")

까다 = stash_before_delete(tricky, "까다로운 이름")
담김 = subprocess.run(["git", "-C", str(tricky), "show", "--name-only", "--format=", 까다["branch"]],
                      capture_output=True, text=True).stdout
for 이름 in (":colon.txt", "-leading.txt", "space name.txt"):
    assert 이름 in 담김, f"{이름} 이 안 담겼다: {담김}"
assert "355\\225\\234" in 담김 or "한글" in 담김, 담김   # git 이 인용해서 내보낸다

print("ok 보관: wip·untracked·제자리 복귀·머지 안 됨·빈 방·부분 실패 롤백·까다로운 이름")
PY

# ⑥ 모바일 표면 — 방 삭제와 대화 삭제가 붙어 있고 가드를 탄다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY2'
import sys
from pathlib import Path

src = (Path(sys.argv[1]) / "marina_handler.py").read_text(encoding="utf-8")
for path in ('"/mobile/api/remove-room"', '"/mobile/api/forget-chat"'):
    assert path in src, f"{path} 가 라우팅에 없다"
방 = src[src.find('if parsed.path == "/mobile/api/remove-room"'):][:500]
assert "safe_root" in 방 and "_require_root_access" in 방, 방
import marina_handler
print("ok 삭제 표면이 붙어 있고 가드를 탄다")
PY2

# ⑦ 대화 삭제는 **묘비를 남긴다** — 마리나는 파일 스캔으로 세션을 찾으므로, 잊는 걸로는
# 다음 폴에 되살아난다(스펙 §7 의 함정).
PYTHONPATH="$SCR" python3 - <<'PY3'
import marina_mobile as mm

out = mm.mobile_forget_chat({"source": "claude", "sid": "gone-1"})
assert out["ok"] is True, out
assert "claude:gone-1" in mm.forgotten_chats(), mm.forgotten_chats()
# 되돌릴 수 있어야 한다 — 실수로 지웠을 때 원본은 남아 있으니 되살릴 길이 있어야 한다.
mm.mobile_forget_chat({"source": "claude", "sid": "gone-1", "forget": False})
assert "claude:gone-1" not in mm.forgotten_chats()
print("ok 대화 삭제: 묘비를 남기고 되돌릴 수 있다")
PY3

# 8) 화면: 방 지우기·대화 지우기가 실제로 있고, **한 번 묻는다**(되돌릴 수 없다).
PYTHONPATH="$SCR" python3 - <<'PY4'
from marina_mobile import render_mobile_html

html = render_mobile_html()
탭 = html[html.find("// ROOM_TABS_START"):html.find("// ROOM_TABS_END")]
assert "data-room-delete" in 탭 and "data-forget" in 탭, 탭[:400]

방지우기 = html[html.find("async function deleteRoom"):html.find("async function forgetChat")]
assert "confirm(" in 방지우기, f"되돌릴 수 없는데 안 묻는다: {방지우기[:300]}"
assert "/mobile/api/remove-room" in 방지우기, 방지우기[:300]
# 보관 얘기는 형에게 안 한다(형 결정) — 멤버에겐 물음표만 남는다.
assert "보관" not in 방지우기 and "wip" not in 방지우기, 방지우기[:400]
assert "지웠어요" in 방지우기, 방지우기[:300]

대화지우기 = html[html.find("async function forgetChat"):][:1100]
assert "confirm(" in 대화지우기 and "/mobile/api/forget-chat" in 대화지우기, 대화지우기[:300]
# **되살릴 길이 폰에 있어야 한다.** API 만 있고 버튼이 없으면 실수를 되돌릴 방법이 없다
# (~/.marina/forgotten-chats.json 손편집은 비개발자 경로가 아니다).
assert "data-restore" in 탭, f"지운 대화를 되살릴 버튼이 없다: {탭[:400]}"
# 템플릿에 글자가 있는지만 보면 **죽은 코드를 잠근다** — 실제로 그랬다. 서버가 지운 탭에
# deleted 를 안 붙여서 그 분기가 영영 안 잡혔고, 화면엔 "오래됨"과 "지우기"만 떴다.
import inspect

import marina_mobile as mm

조립 = inspect.getsource(mm.mobile_state)
assert 'tab["deleted"] = key in gone' in 조립, f"서버가 지운 탭에 표시를 안 붙인다: {조립[-1500:]}"
assert "되살렸어요" in 대화지우기, 대화지우기[:400]
# 지운 것과 숨긴 것은 다르게 말한다 — 되살리는 버튼이 다르다.
assert "지움" in 탭 and "숨김 해제" in 탭, 탭[:400]
# 지운 대화는 **방 상태·지문·시각에서 빠진다.** 안 그러면 지워놓고도 방이 "문제"로 뜨고,
# 접기 지문이 그 대화 것으로 바뀌어 접어둔 방이 다시 펴진다(실측으로 그랬다).
from marina_rooms import finalize_room

방 = {"tabs": [
    {"source": "c", "sid": "살아있음", "status": "대기", "ts": 100},
    {"source": "c", "sid": "지움", "status": "문제", "ts": 999,
     "deleted": True, "hidden": False, "stale": False},
]}
finalize_room(방)
assert 방["status"] == "대기", f"지운 대화가 방 상태를 지배한다: {방['status']}"
assert "지움" not in 방["mark"], f"지운 대화가 접기 지문에 낀다: {방['mark']}"
assert 방["lastAt"] == 100, f"지운 대화 시각이 목록 정렬을 올린다: {방['lastAt']}"
print("ok 화면: 방·대화 지우기가 있고 한 번 묻는다 · 지운 대화는 상태에서 빠진다")
PY4

echo "PASS test-room-delete"
