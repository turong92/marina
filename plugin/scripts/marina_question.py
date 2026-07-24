#!/usr/bin/env python3
"""AskUserQuestion 라이브 캡처 훅.

Claude Code 는 pending AskUserQuestion 을 답하기 전엔 트랜스크립트에 안 쓴다(실측). 하지만
**PreToolUse 훅**은 질문이 뜨는 순간 tool_input(questions+options) 를 구조화된 채로 준다(실측 확인).
이 훅이 그 질문을 세션별 상태파일에 기록해 두면, 모바일(트랜스크립트 폴링 기반)이 pending 창 동안에도
질문 카드를 그릴 수 있다. PostToolUse(답변 완료) 때 파일을 지운다.

fail-open: 어떤 예외든 exit 0(에이전트 흐름 방해 금지).
"""
import json
import os
import re
import sys
import time
from pathlib import Path

MAX_INPUT = 256 * 1024
_SID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{2,80}")


def _questions_dir() -> Path:
    home = Path(os.environ.get("MARINA_HOME") or (Path.home() / ".marina"))
    return home / "agent-questions"


def _state_file(sid: str) -> Path:
    return _questions_dir() / f"claude-{sid}.json"


def main() -> int:
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(raw) > MAX_INPUT:
            return 0
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            return 0
        if str(payload.get("tool_name") or "") != "AskUserQuestion":
            return 0
        sid = str(payload.get("session_id") or "").strip()
        if not _SID_RE.fullmatch(sid):
            return 0
        event = str(payload.get("hook_event_name") or "")
        target = _state_file(sid)
        if event == "PreToolUse":
            tool_input = payload.get("tool_input") or {}
            questions = tool_input.get("questions")
            if not isinstance(questions, list) or not questions:
                return 0
            directory = _questions_dir()
            directory.mkdir(parents=True, exist_ok=True)
            try:
                os.chmod(directory, 0o700)
            except OSError:
                pass
            record = {
                "sid": sid,
                "cwd": str(payload.get("cwd") or ""),
                "toolUseId": str(payload.get("tool_use_id") or ""),
                "questions": questions,
                "ts": time.time(),
            }
            tmp = target.with_suffix(".tmp")
            tmp.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
            os.replace(tmp, target)
            try:
                os.chmod(target, 0o600)
            except OSError:
                pass
        elif event == "PostToolUse":
            try:
                target.unlink()
            except FileNotFoundError:
                pass
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
