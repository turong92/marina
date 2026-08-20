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
print("ok 보관: wip 브랜치·untracked 포함·제자리 복귀·머지 안 됨·빈 방은 건너뜀")
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
assert "되살렸어요" in 대화지우기, 대화지우기[:400]
# 지운 것과 숨긴 것은 다르게 말한다 — 되살리는 버튼이 다르다.
assert "지움" in 탭 and "숨김 해제" in 탭, 탭[:400]
print("ok 화면: 방·대화 지우기가 있고 한 번 묻는다")
PY4

echo "PASS test-room-delete"
