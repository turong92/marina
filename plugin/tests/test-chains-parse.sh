#!/usr/bin/env bash
# 결과는 역할 방 **자기 트랜스크립트**의 SendMessage 입력에서 읽는다(스펙 5.3). 흐름 줄은 오프셋으로 끼운다(7.1).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import json, subprocess, tempfile
from pathlib import Path
import marina_chains as C

SOCK = "uds:/tmp/cc-socks/3741.sock"
def send(to, msg): return {"type": "assistant", "message": {"role": "assistant", "content": [
    {"type": "tool_use", "id": "t", "name": "SendMessage", "input": {"to": to, "message": msg}}]}}
body = "### [CRITICAL] 트랜잭션 밖\n`a.kt:41`\n### [WARNING] 경계값\n**[보류]** 공용 모듈로 빼자\n[보류] 이름 바꾸자"
rows = [(0, send("uds:/tmp/other.sock", "남에게")), (10, {"type": "user"}), (20, send(SOCK, "첫 초안")), (30, send(SOCK, body))]
r = C.parse_role_result(rows, SOCK)
assert r["findings"] == 2 and r["noneLeft"] is False, r
assert r["held"] == ["[보류] 공용 모듈로 빼자", "[보류] 이름 바꾸자"], r["held"]      # 마지막 메시지만 · 굵게 표시 정리
clean = C.parse_role_result([(0, send(SOCK, "앞 지적 반영 확인.\n\n새 지적 없음\n"))], SOCK)
assert clean["noneLeft"] is True and clean["findings"] == 0, clean
plain = C.parse_role_result([(0, send(SOCK, "문단 하나\n\n문단 둘"))], SOCK)
assert plain["findings"] == 2 and plain["noneLeft"] is False, plain                     # 머리 줄 없으면 문단 수
assert C.parse_role_result([(0, send("uds:/x", "남"))], SOCK) is None
assert C.parse_role_result([], SOCK) is None

p = Path(tempfile.mkdtemp()) / "t.jsonl"
lines = [json.dumps(send(SOCK, "old")), json.dumps(send(SOCK, "new"))]
p.write_text(lines[0] + "\n" + lines[1] + "\n")
cut = len(lines[0]) + 1
got = C.read_rows(p, cut)
assert [o for o, _ in got] == [cut] and C.parse_role_result(got, SOCK)["text"] == "new", got

# 턴 끝: 알림층 kind 가 아니라 status 전이
last = {}
work = {"session": "k", "kind": "status", "status": "working"}
C.remember_status(work, last)
assert C.turn_ended({"session": "k", "kind": "status", "status": "waiting"}, last) is True
assert C.turn_ended({"session": "k", "kind": "idle", "status": "idle"}, {}) is True
assert C.turn_ended({"session": "new", "kind": "status", "status": "waiting"}, last) is False   # 직전 모름
assert C.turn_ended({"session": "k", "kind": "message"}, last) is False

# 저장소 HEAD: 루트 + .git 있는 서브레포
root = Path(tempfile.mkdtemp())
subprocess.run(["git", "init", "-q", str(root)], check=True)
subprocess.run(["git", "-C", str(root), "-c", "user.email=a@b", "-c", "user.name=a", "commit", "-q", "--allow-empty", "-m", "x"], check=True)
heads = C.repo_heads(root)
assert list(heads.values())[0] == subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(), heads

# 흐름 항목 병합
chain = {"id": "c-20260910-183210-reviewer-916b67c1", "role": "reviewer", "round": 2, "maxRounds": 2, "unlimited": False,
         "state": "done", "held": ["[보류] X"], "endedReason": "clean", "endedAnchor": 250, "roleRoom": {"model": "claude-sonnet-5"},
         "rounds": [{"n": 1, "sentAnchor": 120, "findings": 2}, {"n": 2, "sentAnchor": 210, "findings": 0}]}
items = C.chain_items(chain)
assert [i["event"] for i in items] == ["request", "request", "end"] and items[-1]["applied"] == 1, items
tl = [{"id": "claude:message:100:0", "kind": "message"}, {"id": "claude:activity:toolu_1", "kind": "activity"},
      {"id": "claude:peer:200:a", "kind": "message"}, {"id": "claude:message:300:0", "kind": "message"}]
merged = C.merge_chain_items(tl, [chain], is_latest_page=True)
ids = [i["id"] for i in merged]
assert ids == ["claude:message:100:0", "claude:activity:toolu_1", "chain:c-20260910-183210-reviewer-916b67c1:r1",
               "claude:peer:200:a", "chain:c-20260910-183210-reviewer-916b67c1:r2",
               "chain:c-20260910-183210-reviewer-916b67c1:end", "claude:message:300:0"], ids
older = [{"id": "claude:message:500:0", "kind": "message"}]            # 이 페이지보다 앞선 사건은 넣지 않는다
assert C.merge_chain_items(older, [chain], is_latest_page=False) == older
tail = C.merge_chain_items([{"id": "claude:message:10:0", "kind": "message"}], [chain], is_latest_page=True)
assert [i["event"] for i in tail if i["kind"] == "chain"] == ["request", "request", "end"]      # 최신 페이지면 끝에 붙인다
print("PASS: 결과 파서·HEAD·턴 끝·흐름 병합")
PY
