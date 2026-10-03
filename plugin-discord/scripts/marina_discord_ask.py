"""마리나 Discord 봇 3: 질문 버튼(AskUserQuestion).

Claude 가 선택지 질문을 하면 PreToolUse 훅이 채널에 질문 메시지를 올린다 — 단일선택은 버튼, 다중선택은 드롭다운,
[✏️ 기타] 는 입력 팝업(봇이 띄움). 질문마다 답이 모이면 세션 tmux 의 셀렉터를 키로 구동한다.
키 계약은 마리나 모바일에서 실측한 것과 같다(marina_mobile._drive_selector 주석 참고).
앱·터미널에서 먼저 답하면 PostToolUse 훅이 메시지를 '답함'으로 정리한다.
"""
from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import marina_session as ms

STATE = "question.json"


def _opts(q: dict[str, Any]) -> list[dict[str, Any]]:
    o = q.get("options") if isinstance(q, dict) else None
    return [x if isinstance(x, dict) else {"label": str(x)} for x in o] if isinstance(o, list) else []


def keys_for(questions: list[dict[str, Any]], answers: list[Any]) -> list[Any]:
    """셀렉터 구동 키. 커서는 첫 옵션에서 시작. 'WAIT' = 다음 질문을 다시 그릴 때까지 기다림.
    단일: ↓N Enter · 다중: 항목마다 ↓ 후 Enter(토글), → 로 Submit 창, Enter · 기타: 옵션 다음 줄로 ↓ 후 타이핑
    (다중이면 Tab → Submit, Enter 확인) Enter · 여러 질문이면 끝에 Submit 화면 Enter."""
    keys: list[Any] = []
    for i, picks in enumerate(answers):
        if i:
            keys.append("WAIT")
        q = questions[i] if i < len(questions) else {}
        multi = bool(q.get("multiSelect")) if isinstance(q, dict) else False
        n = len(_opts(q))
        if isinstance(picks, dict):
            text = " ".join(str(picks.get("text") or "").split())[:2000]     # 줄바꿈은 중간 제출 — 공백으로(리뷰 I5)
            keys += ["Down"] * n + [("-l", "--", text)]
            keys += (["Tab", "Enter"] if multi else []) + ["Enter"]
        elif not multi:
            keys += ["Down"] * (picks[0] if picks else 0) + ["Enter"]
        else:
            cur = 0
            for t in picks:
                keys += ["Down"] * max(0, t - cur) + ["Enter"]
                cur = max(cur, t)
            keys += ["Right", "Enter"]
    if len(answers) > 1:
        keys += ["WAIT", "Enter"]
    return keys


def _answer_label(q: dict[str, Any], a: Any) -> str:
    if isinstance(a, dict):
        return "✏️ " + str(a.get("text") or "")
    opts = _opts(q)
    return ", ".join(str(opts[i].get("label") or f"{i + 1}") for i in a if i < len(opts))


def render(ch: str, st: dict[str, Any], done: str = "") -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for i, q in enumerate(st["questions"]):
        a = st["answers"][i]
        head = f"**❓ {q.get('header') or f'질문 {i + 1}'}** — {q.get('question') or ''}"
        if a is not None or done:
            out.append(ms_text((head + (f"\n→ {_answer_label(q, a)}" if a is not None else ""))[:900]))
            continue
        out.append(ms_text((head + "".join(f"\n-# {k + 1}. {o.get('label')} — {o.get('description')}"
                                           for k, o in enumerate(_opts(q)) if o.get("description")))[:900]))   # 메시지 글 합계 4000(리뷰 M2)
        opts = _opts(q)
        if q.get("multiSelect"):
            out.append({"type": 1, "components": [{"type": 3, "custom_id": f"mqm:{ch}:{i}", "min_values": 1,
                                                   "max_values": len(opts), "placeholder": "골라(여러 개 가능)",
                                                   "options": [{"label": str(o.get("label") or k + 1)[:100], "value": str(k)}
                                                               for k, o in enumerate(opts)][:25]}]})
            out.append({"type": 1, "components": [_other(ch, i)]})
        else:
            out.append({"type": 1, "components": [{"type": 2, "style": 1, "label": f"{k + 1}. {o.get('label')}"[:80],
                                                   "custom_id": f"mq:{ch}:{i}:{k}"} for k, o in enumerate(opts)][:4]
                        + [_other(ch, i)]})
    if done:
        out.append(ms_text(f"-# {done}"))
    return out


def ms_text(content: str) -> dict[str, Any]:
    return {"type": 10, "content": content[:3900]}


def _other(ch: str, i: int) -> dict[str, Any]:
    return {"type": 2, "style": 2, "label": "✏️ 기타 입력…", "custom_id": f"mqo:{ch}:{i}"}


def _dc() -> ms.Discord:
    return ms.Discord(ms.read_token(ms.load_config()))


def _load(sd: Path) -> dict[str, Any] | None:
    try:
        st = json.loads((sd / STATE).read_text(encoding="utf-8"))
        return st if isinstance(st, dict) and isinstance(st.get("questions"), list) else None
    except (OSError, ValueError):
        return None


def _done_after(sd: Path, t: float) -> bool:
    try:
        return float((sd / "question-done-at").read_text()) >= t
    except (OSError, ValueError):
        return False


def post_question(sdir: str, ch: str, tool_input: dict[str, Any], started: float | None = None) -> None:
    sd = Path(sdir)
    started = time.time() if started is None else started
    qs = [q for q in (tool_input.get("questions") or []) if isinstance(q, dict)][:5]
    if not qs:
        return
    st = {"questions": qs, "answers": [None] * len(qs), "msg": ""}
    dc = _dc()
    r = dc._req("POST", f"/channels/{ch}/messages", {"flags": 1 << 15, "components": render(ch, st),
                                                      "allowed_mentions": {"parse": []}})
    st["msg"] = str(r.get("id") or "")
    if _done_after(sd, started):      # 올리는 사이 앱·터미널에서 이미 답했다 — 남기지 않는다(리뷰 I2)
        try:
            dc._req("PATCH", f"/channels/{ch}/messages/{st['msg']}", {"components": render(ch, st, "답함")})
        except ms.SessionError:
            pass
        return
    ms._write_json(sd / STATE, st)
    ms.dashboard_signal()


def _spawn_drive(tmux: str, channel: str) -> None:
    subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "drive", tmux, channel],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def answer(channel: str, user: str, qi: int, picks: list[int] | None = None, text: str | None = None,
           message: str = "") -> str:
    import marina_discord_bot as mb
    rec = next((s for s in ms.load_sessions() if str(s.get("channelId")) == str(channel)), None)
    if not rec:
        return "모르는 채널이야"
    dc = _dc()
    if not mb._allowed(rec, channel, user, dc):
        return "답할 권한이 없어"
    sd = Path(str(rec.get("stateDir") or "/nonexistent"))
    lockf = ms._wait_lock(sd / "question.lock", timeout=5.0)
    try:
        st = _load(sd)
        if not st:
            return "지금 답할 질문이 없어"
        if message and str(st.get("msg")) != str(message):
            return "지난 질문이야 — 지금 질문 메시지에서 골라 줘"          # 리뷰 C1
        if all(x is not None for x in st["answers"]):
            return "이미 다 답했어"                                        # 리뷰 I1
        if not 0 <= qi < len(st["questions"]):
            return "없는 질문이야"
        q = st["questions"][qi]
        if text is not None:
            text = text.strip()[:2000]
            if not text:
                return "글을 써 줘"
            a: Any = {"text": text}
        else:
            n = len(_opts(q))
            picks = sorted(set(int(p) for p in (picks or [])))
            if not picks or any(p < 0 or p >= n for p in picks) or (len(picks) > 1 and not q.get("multiSelect")):
                return "고를 수 없는 선택지야"
            a = picks
        st["answers"][qi] = a
        complete = all(x is not None for x in st["answers"])
        ms._write_json(sd / STATE, st)
        try:
            dc._req("PATCH", f"/channels/{channel}/messages/{st['msg']}",
                    {"components": render(channel, st, "입력하는 중…" if complete else "")})
        except ms.SessionError:
            pass
    finally:
        if lockf:
            lockf.close()
    if complete:
        _spawn_drive(str(rec.get("tmux") or ""), str(channel))
        return "다 골랐어 — 세션에 입력할게"
    return "골랐어"


def _screen(tmux: str) -> str:
    return ms._tmux("capture-pane", "-p", "-t", tmux).stdout or ""


def _selector_visible(screen: str) -> bool:
    return "Enter to select" in screen or any(l.lstrip().startswith("❯ 1.") for l in screen.splitlines())


def _question_visible(screen: str, q: dict[str, Any]) -> bool:
    """이 질문의 셀렉터인가 — 문구(앞 20자)까지 맞아야 친다. '❯ 1. Yes' 권한 창 등에 치지 않게(리뷰 C2)."""
    key = " ".join(str(q.get("question") or "").split())[:20]
    flat = " ".join(screen.split())
    return _selector_visible(screen) and bool(key) and key in flat


def _wait_quiet(tmux: str, timeout: float) -> None:
    """다음 화면을 다 그릴 때까지 — 0.4초 동안 안 바뀌면 됐다."""
    end, last, still = time.time() + timeout, _screen(tmux), time.time()
    while time.time() < end:
        time.sleep(0.1)
        cur = _screen(tmux)
        if cur != last:
            last, still = cur, time.time()
        elif time.time() - still >= 0.4:
            return


def drive(tmux: str, channel: str, pause: float = 0.25) -> None:
    """모은 답을 셀렉터에 친다. 질문마다 그 질문 화면인지 확인하고, 아니면(앱에서 이미 답함·권한 창 등) 멈추고 알린다."""
    rec = next((s for s in ms.load_sessions() if str(s.get("channelId")) == str(channel)), None)
    sd = Path(str((rec or {}).get("stateDir") or "/nonexistent"))
    st = _load(sd)
    if not st or any(a is None for a in st["answers"]):
        return
    segs: list[list[Any]] = [[]]
    for k in keys_for(st["questions"], st["answers"]):
        if k == "WAIT":
            segs.append([])
        else:
            segs[-1].append(k)
    for i, seg in enumerate(segs):
        if i:
            _wait_quiet(tmux, 3.0)
        if ms.tmux_alive(tmux):
            ms.tmux_leave_mode(tmux)
        screen = _screen(tmux) if ms.tmux_alive(tmux) else ""
        ok = _question_visible(screen, st["questions"][i]) if i < len(st["questions"]) else _selector_visible(screen)
        if not ok:
            done(sd, channel, "입력 못 했어 — 질문 화면이 안 보여. 터미널·앱에서 답해 줘")
            return
        for k in seg:
            ms._tmux("send-keys", "-t", tmux, *(list(k) if isinstance(k, tuple) else [k]))
            time.sleep(pause)


def done(sd: Path, ch: str, note: str = "답함") -> None:
    """질문이 끝났다(어디서 답했든·취소·포기). 버튼을 없애고 상태를 지운다. 늦게 올라올 질문 메시지도 보고 물러나게 시각을 남긴다."""
    lockf = ms._wait_lock(sd / "question.lock", timeout=5.0) if sd.is_dir() else None
    try:
        if sd.is_dir():
            (sd / "question-done-at").write_text(f"{time.time()}\n")
        st = _load(sd)
        if not st:
            return
        try:
            (sd / STATE).unlink()
        except OSError:
            pass
    finally:
        if lockf:
            lockf.close()
    try:
        _dc()._req("PATCH", f"/channels/{ch}/messages/{st['msg']}", {"components": render(ch, st, note)})
    except ms.SessionError:
        pass
    ms.dashboard_signal()


def main(argv: list[str]) -> int:
    import argparse
    p = argparse.ArgumentParser(prog="marina_discord_ask")
    sub = p.add_subparsers(dest="cmd", required=True)
    po = sub.add_parser("post")
    po.add_argument("sdir"); po.add_argument("channel"); po.add_argument("started", type=float)
    dn = sub.add_parser("done")
    dn.add_argument("sdir"); dn.add_argument("channel")
    an = sub.add_parser("answer")
    an.add_argument("--channel", required=True); an.add_argument("--user", required=True)
    an.add_argument("--q", type=int, required=True)
    an.add_argument("--picks", default=""); an.add_argument("--text", default=None); an.add_argument("--message", default="")
    dr = sub.add_parser("drive")
    dr.add_argument("tmux"); dr.add_argument("channel")
    a = p.parse_args(argv)
    try:
        if a.cmd == "post":
            post_question(a.sdir, a.channel, json.loads(sys.stdin.read() or "{}"), started=a.started)
        elif a.cmd == "done":
            done(Path(a.sdir), a.channel)
        elif a.cmd == "answer":
            picks = [int(x) for x in a.picks.split(",") if x.strip().isdigit()]
            print(answer(a.channel, a.user, a.q, picks=picks or None, text=a.text, message=a.message))
        elif a.cmd == "drive":
            drive(a.tmux, a.channel)
    except ms.SessionError as exc:
        print(str(exc))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
