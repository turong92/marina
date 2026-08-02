#!/usr/bin/env python3
"""AskUserQuestion 라이브 캡처 훅.

Claude Code 는 pending AskUserQuestion 을 답하기 전엔 트랜스크립트에 안 쓴다(실측). 하지만
**PreToolUse 훅**은 질문이 뜨는 순간 tool_input(questions+options) 를 구조화된 채로 준다(실측 확인).
이 훅이 그 질문을 세션별 상태파일에 기록해 두면, 모바일(트랜스크립트 폴링 기반)이 pending 창 동안에도
질문 카드를 그릴 수 있다. PostToolUse(답변 완료) 때 파일을 지운다.

fail-open: 어떤 예외든 exit 0(에이전트 흐름 방해 금지).
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any

MAX_INPUT = 256 * 1024
_SID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{2,80}")


def _questions_dir() -> Path:
    home = Path(os.environ.get("MARINA_HOME") or (Path.home() / ".marina"))
    return home / "agent-questions"


def _state_file(sid: str) -> Path:
    return _questions_dir() / f"claude-{sid}.json"


def _text_of(value: Any) -> str:
    if isinstance(value, str):
        return value.strip()
    return ""


def _normalize_questions(raw: Any) -> list | None:
    """Best-effort coercion of ``tool_input.questions`` into a non-empty list.

    질문 형식이 이상해도(리스트가 아니거나, 항목에 header/options 가 없어도) 모바일이 최소한
    질문 원문 텍스트라도 보여줄 수 있게 정규화한다. 정말 아무것도 없을 때만 None(=skip).
    """
    if raw is None:
        return None
    items = raw if isinstance(raw, list) else [raw]
    normalized: list = []
    for item in items:
        if isinstance(item, dict):
            if not item:
                continue  # 완전히 빈 dict — 뽑아낼 게 없다
            question_text = _text_of(item.get("question"))
            if not question_text:
                for key in ("text", "prompt", "header", "label", "title"):
                    fallback = _text_of(item.get(key))
                    if fallback:
                        item = dict(item)
                        item["question"] = fallback
                        break
            normalized.append(item)
        elif isinstance(item, str):
            text = item.strip()
            if text:
                normalized.append({"question": text})
        elif item is not None:
            try:
                text = json.dumps(item, ensure_ascii=False)
            except Exception:
                text = str(item)
            text = (text or "").strip()
            if text and text not in ("null", "{}", "[]", '""'):
                normalized.append({"question": text})
    return normalized or None


def main() -> int:
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(raw) > MAX_INPUT:
            return 0
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            return 0
        event = str(payload.get("hook_event_name") or "")
        # PreToolUse/PostToolUse 는 AskUserQuestion 에만 걸리지만, 정리 이벤트(UserPromptSubmit/Stop)는
        # 도구와 무관하게 온다 — tool_name 검사를 여기서 하면 정리가 통째로 막힌다.
        if event in ("PreToolUse", "PostToolUse") and str(payload.get("tool_name") or "") != "AskUserQuestion":
            return 0
        sid = str(payload.get("session_id") or "").strip()
        if not _SID_RE.fullmatch(sid):
            return 0
        target = _state_file(sid)
        if event == "PreToolUse":
            tool_input = payload.get("tool_input")
            if not isinstance(tool_input, dict):
                tool_input = {}
            questions = _normalize_questions(tool_input.get("questions"))
            if not questions:
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
        elif event in ("PostToolUse", "UserPromptSubmit", "Stop"):
            # PostToolUse = 정상 답변. 나머지 둘은 **중단/거절** 경로다 — 형이 Esc 로 질문을 끄거나
            # 그냥 글로 답해버리면 PostToolUse 가 영영 안 와서, 죽은 질문 카드가 모바일에 15분(만료
            # 상한)이나 남고 거기 탭해봐야 아무 일도 안 일어났다. 실제로 형이 겪은 "안 가는데"의
            # 한 갈래. 새 프롬프트나 턴 종료는 그 질문이 끝났다는 확정 신호라 여기서 지운다.
            try:
                target.unlink()
            except FileNotFoundError:
                pass
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
