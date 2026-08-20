#!/usr/bin/env bash
# 새 일감 — 폰에서 **프로젝트만 고르면** 마리나가 이름을 짓는다(스펙 §3).
#
# 지금은 ＋WT 가 브랜치명을 직접 치라고 묻는다. 비개발자용 화면에서 "브랜치"라는 말도,
# 규칙(영문/숫자/-)도 형이 알 이유가 없다. 스펙: "브랜치명은 마리나가 첫 메시지에서 짓는다.
# 선택지를 프로젝트 하나로 줄이는 게 안전장치다."
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import re

from marina_rooms import branch_from_text

# 서버가 받아주는 모양이어야 한다(marina_handler 의 검사와 같은 규칙).
허용 = re.compile(r"[A-Za-z0-9._/-]+")


def 확인(값):
    assert 허용.fullmatch(값), f"서버가 거부할 이름: {값!r}"
    assert ".." not in 값 and " " not in 값, 값
    assert 3 <= len(값) <= 60, (len(값), 값)
    return 값

# ① 영어는 그대로 눕힌다.
이름 = 확인(branch_from_text("Fix the payment refund bug"))
assert 이름.startswith("fix-the-payment-refund"), 이름

# ② 한글로 시켜도 **쓸 수 있는 이름**이 나온다. 브랜치명은 디렉터리 이름이자 게이트웨이
# 도메인 라벨(gwDomainLabel)이라 한글이 들어가면 DNS 쪽이 깨진다 — 그래서 ASCII 로만 짓고,
# 형에게 보이는 이름은 별칭으로 따로 붙인다(그 배선은 아래 ⑦에서 확인).
한글 = 확인(branch_from_text("결제 환불 정합성 고쳐줘"))
assert 한글.startswith("work-"), 한글

# ③ 같은 말로 시작해도 **서로 다른 워크트리**가 된다. 같은 이름이면 두 번째 생성이 실패한다.
하나 = branch_from_text("결제 고쳐줘")
둘 = branch_from_text("결제 고쳐줘")
assert 하나 != 둘, (하나, 둘)

# ④ 위험한 글자는 다 걸러진다 — 경로 탈출·명령 삽입이 이름으로 들어오면 안 된다.
험한것 = 확인(branch_from_text("../../etc/passwd; rm -rf / `whoami` $(id)"))
assert "etc/passwd" not in 험한것 and ";" not in 험한것 and "`" not in 험한것, 험한것

# ⑤ 아무 말이 없어도 이름은 나온다(빈 이름은 서버가 거부한다).
확인(branch_from_text(""))
확인(branch_from_text("   \n  "))
확인(branch_from_text("!!!"))

# ⑥ 길게 써도 잘린다 — 브랜치명이 디렉터리 이름이 된다.
확인(branch_from_text("아주 " * 200))
print("ok 이름 짓기: 서버 규칙 통과·한글 보존·중복 회피·위험 글자 제거")
PY

# ⑦ 화면: 프로젝트만 고르면 되고, 브랜치명을 묻지 않는다.
PYTHONPATH="$SCR" python3 - <<'PY2'
from marina_mobile import render_mobile_html

html = render_mobile_html()
블록 = html[html.find("// NEW_TASK_START"):html.find("// NEW_TASK_END")]
assert 블록, "NEW_TASK 블록이 없다"
# 주석에서 브랜치를 설명하는 건 괜찮다 — **형에게 묻는 말**에 나오면 안 된다.
묻는말 = [줄 for 줄 in 블록.splitlines() if "prompt(" in 줄]
assert 묻는말, 블록[:300]
assert not any("브랜치" in 줄 for 줄 in 묻는말), f"비개발자에게 브랜치를 묻는다: {묻는말}"
# 첫 메시지를 받아 그걸로 이름을 짓고, 만든 뒤 바로 대화를 시작한다.
assert "무슨 일" in 블록, 블록[:300]
# 브랜치는 ASCII 로 짓되, **형이 쓴 말은 방 이름(별칭)으로 남긴다** — 안 그러면 목록에
# work-4f2a1 같은 게 뜬다.
assert "/mobile/api/rename" in 블록, f"형이 쓴 말이 방 이름으로 안 남는다: {블록[:400]}"
assert "/mobile/api/worktree-create" in 블록 and "/mobile/api/launch" in 블록, 블록[:400]
print("ok 새 일감: 프로젝트만 고르고 첫 메시지로 시작한다")
PY2

# 8) 서버가 task 를 받아 이름을 짓는다 — 모바일은 브랜치명을 안 보낸다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'PY3'
import sys
from pathlib import Path

src = (Path(sys.argv[1]) / "marina_handler.py").read_text(encoding="utf-8")
블록 = src[src.find("    def _worktree_create"):][:2600]
assert "branch_from_text" in 블록, f"서버가 첫 메시지로 이름을 안 짓는다: {블록[:400]}"
# 웹은 예전처럼 branch 를 직접 보낸다 — 그 길을 막으면 대시보드가 깨진다.
assert 'body.get("branch"' in 블록, 블록[:400]
import marina_handler
print("ok 서버가 첫 메시지로 이름을 짓는다")
PY3

echo "PASS test-new-task"
