#!/usr/bin/env bash
# 새 메시지 점의 기준 = 마지막 assistant 메시지 시각(msgTs). 파일 수정 시각은 marina 재시작으로 대화 프로세스가
# 끝날 때도 바뀌어(종료 기록이 덧붙음) 아무 말 없이 점이 켜졌다(2026-09-28 실측: 17:06 말, 파일은 17:08).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import json, tempfile
from datetime import datetime, timezone
from pathlib import Path
import marina_sessions as ms
with tempfile.TemporaryDirectory() as d:
    p = Path(d) / "t.jsonl"
    rows = [
        {"type": "user", "timestamp": "2026-09-28T08:00:00.000Z", "message": {"content": "해줘"}},
        {"type": "assistant", "timestamp": "2026-09-28T08:06:05.000Z", "message": {"content": [{"type": "text", "text": "다 했어요"}]}},
        {"type": "system", "timestamp": "2026-09-28T08:08:30.000Z", "subtype": "exit"},   # 종료 때 덧붙는 기록
    ]
    p.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")
    preview, at = ms._jsonl_last_assistant(p)
    assert preview == "다 했어요", preview
    want = datetime(2026, 9, 28, 8, 6, 5, tzinfo=timezone.utc).timestamp()
    assert abs(at - want) < 1, (at, want)
    assert ms._jsonl_last_assistant_preview(p) == "다 했어요", "옛 호출부가 깨졌다"
    empty = Path(d) / "e.jsonl"; empty.write_text("", encoding="utf-8")
    assert ms._jsonl_last_assistant(empty) == ("", 0.0)
print("PASS test-last-message-ts")
PY
