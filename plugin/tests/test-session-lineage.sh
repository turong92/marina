#!/usr/bin/env bash
# 같은 대화가 목록에 두 줄로 나오던 것 — resume·압축은 **새 sid 파일**을 만들고 옛 파일은 남는다.
#
# 실측(2026-09-23): 이 레포 트랜스크립트 23개 중 12b83bfb 와 557c0a93 이 첫 사용자 메시지 uuid
# e25b11a5 를 공유했다(= 같은 대화의 압축 전/후). 데스크톱 앱이 같은 대화를 열면 자기 기록으로 또
# 하나를 만든다. 형: "데스크탑앱이랑 경쟁해서 동일 세션이 2개씩 열린다".
# 계약: 혈통(첫 사용자 메시지 uuid)이 같으면 **가장 최근 것 하나만** 남긴다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../scripts"

PYTHONPATH="$SCRIPTS" python3 - <<'PY'
import json, os, tempfile, time, unittest
from pathlib import Path

tmp = tempfile.TemporaryDirectory()
os.environ["CLAUDE_PROJECTS_DIR"] = str(Path(tmp.name, "projects"))
os.environ["CLAUDE_DESKTOP_SESSIONS_DIR"] = str(Path(tmp.name, "desktop"))   # 실 데스크톱 기록 격리
import marina_sessions as ms

ROOT = str(Path(tmp.name, "wt"))
PROJ = Path(os.environ["CLAUDE_PROJECTS_DIR"], "slug")
DESKTOP = Path(os.environ["CLAUDE_DESKTOP_SESSIONS_DIR"])


def desktop_record(current, priors):
    """데스크톱 앱 기록 — 앱은 한 대화가 CLI 세션 파일을 갈아탄 것을 스스로 안다."""
    DESKTOP.mkdir(parents=True, exist_ok=True)
    Path(DESKTOP, f"local_{current}.json").write_text(json.dumps(
        {"cliSessionId": current, "priorCliSessionIds": list(priors),
         "cwd": ROOT, "lastActivityAt": time.time() * 1000}), encoding="utf-8")


def write(sid, first_uuid, title, age_s, lead=0):
    """트랜스크립트 하나. lead = 첫 사용자 줄 앞에 끼는 메타 줄 수(압축된 대화는 이게 길다)."""
    PROJ.mkdir(parents=True, exist_ok=True)
    lines = [json.dumps({"type": "custom-title", "sessionId": sid, "customTitle": title})]
    # 메타 줄에도 cwd 는 실린다(실 트랜스크립트와 같게) — 없으면 파일이 아예 안 잡혀 다른 걸 재게 된다
    lines += [json.dumps({"type": "mode", "sessionId": sid, "mode": "x", "cwd": ROOT}) for _ in range(lead)]
    lines.append(json.dumps({"type": "user", "uuid": first_uuid, "sessionId": sid, "cwd": ROOT,
                             "message": {"role": "user", "content": title}}))
    p = Path(PROJ, f"{sid}.jsonl")
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.utime(p, (time.time() - age_s, time.time() - age_s))
    return p


def rows():
    return ms.claude_agent_sessions(refresh=True, include_all=True).get(ROOT, [])


class LineageTests(unittest.TestCase):
    def setUp(self):
        for p in PROJ.glob("*.jsonl"):
            p.unlink()
        if DESKTOP.is_dir():
            for p in DESKTOP.glob("local_*.json"):
                p.unlink()

    def test_fork_collapses_to_newest(self):
        write("old-sid", "u-1", "메모리 정리하자", age_s=3600)
        write("new-sid", "u-1", "메모리 정리하자", age_s=10)      # 압축 뒤 새 파일(같은 첫 메시지)
        got = rows()
        self.assertEqual([e["cliSessionId"] for e in got], ["new-sid"],
                         "같은 대화가 두 줄로 남았다(또는 옛 줄을 남겼다)")

    def test_desktop_record_decides_which_one_is_current(self):
        """앱 기록이 있으면 그게 정본이다 — 첫 메시지가 달라도 묶이고, **지금 sid** 가 남는다.
        (mtime 이 더 최근인 옛 줄을 남기면, 눌러도 이어지지 않는 과거가 열린다.)"""
        write("old-sid", "u-1", "예전 파일", age_s=1)          # 옛 줄이 더 최근에 쓰였어도
        write("cur-sid", "u-2", "지금 파일", age_s=600)        # 첫 메시지 uuid 도 다르다
        desktop_record("cur-sid", ["old-sid"])
        self.assertEqual([e["cliSessionId"] for e in rows()], ["cur-sid"])

    def test_different_conversations_are_kept(self):
        write("a", "u-1", "결제 고치자", age_s=30)
        write("b", "u-2", "결제 고치자", age_s=20)               # 제목만 같은 **다른** 대화
        self.assertEqual(sorted(e["cliSessionId"] for e in rows()), ["a", "b"],
                         "제목이 같다고 다른 대화를 지웠다")

    def test_lineage_found_past_the_first_lines(self):
        """압축된 대화는 선두 메타가 길다 — 실측 41번째 줄에서야 첫 사용자 줄이 나왔다."""
        write("short", "u-9", "짧은 쪽", age_s=60)
        write("long", "u-9", "압축된 쪽", age_s=5, lead=60)
        self.assertEqual([e["cliSessionId"] for e in rows()], ["long"],
                         "선두 메타가 길면 혈통을 못 읽어 두 줄로 남는다")

    def test_no_user_line_is_not_collapsed(self):
        """아직 말 한마디 없는 세션끼리 묶어 버리면 멀쩡한 대화가 사라진다."""
        p = Path(PROJ, "blank1.jsonl"); PROJ.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps({"type": "mode", "sessionId": "blank1", "cwd": ROOT}) + "\n", encoding="utf-8")
        p2 = Path(PROJ, "blank2.jsonl")
        p2.write_text(json.dumps({"type": "mode", "sessionId": "blank2", "cwd": ROOT}) + "\n", encoding="utf-8")
        self.assertEqual(sorted(e["cliSessionId"] for e in rows()), ["blank1", "blank2"])


unittest.main(verbosity=1)
PY
