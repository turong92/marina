#!/usr/bin/env python3
"""`marina docker gc` — 도커 GC 정책·실행 CLI. 엔진은 marina_docker_gc 한 곳(대시보드 API 와 같은 함수).

  marina docker gc                 due 면 실행, 아니면 다음 실행 시각 안내 (enabled=false 면 안내만)
  marina docker gc --now           정책 무관 지금 실행
  marina docker gc --dry-run       지울 것·예상량만 (--now 와 조합 가능)
  marina docker gc status          정책·마지막 실행·도커 디스크
  marina docker gc policy          정책 전체
  marina docker gc policy <key> <value>
  --json 은 어느 형태든 JSON 으로. 종료코드: 실행 오류 1, 사용법·정책 키/값 오류 2."""
from __future__ import annotations

import json
import sys
import time
from datetime import datetime

import marina_docker_gc as gc

USAGE = __doc__.split("\n", 1)[1].strip()


def _when(ts: float | None) -> str:
    if not ts:
        return "—"
    return datetime.fromtimestamp(float(ts)).astimezone().strftime("%Y-%m-%d %H:%M")


def _ago(ts: float | None, now: float) -> str:
    if not ts:
        return "아직 실행 안 됨"
    s = max(0, int(now - float(ts)))
    if s < 3600:
        return f"{s // 60}분 전"
    if s < 86400:
        return f"{s // 3600}시간 전"
    return f"{s // 86400}일 전"


def _print_report(report: dict) -> None:
    verb = "예상 회수" if report["dryRun"] else "회수"
    print(f"{verb} {gc.fmt_mb(report['reclaimedMb'])}")
    for s in report["steps"]:
        if s.get("skipped"):
            print(f"  {s['name']:<12} (정책으로 꺼짐)")
            continue
        mark = "✗ " + str(s["error"]) if s.get("error") else f"{gc.fmt_mb(s['reclaimedMb'])} · {len(s['items'])}개"
        print(f"  {s['name']:<12} {mark}")
        for item in s["items"][:20]:
            print(f"    - {item}")
        if len(s["items"]) > 20:
            print(f"    … +{len(s['items']) - 20}")
    print(f"로그: {gc.LOG_FILE}")


def _print_policy(policy: dict) -> None:
    print("정책 (" + str(gc.POLICY_FILE) + ")")
    for key in gc.DEFAULT_POLICY:
        val = policy[key]
        print(f"  {key:<28} {','.join(val) if isinstance(val, list) else json.dumps(val)}")
    for w in policy.get("warnings") or []:
        print(f"  ! {w}")


def _print_status(st: dict, now: float) -> None:
    state = st["state"]
    disk = st["disk"] or {}
    print(f"도커 디스크  images {gc.fmt_mb(disk.get('imagesMb', 0))} · build cache {gc.fmt_mb(disk.get('buildCacheMb', 0))} · volumes {gc.fmt_mb(disk.get('volumesMb', 0))}")
    if state:
        line = f"마지막 정리  {_ago(state.get('finishedAt'), now)} ({_when(state.get('finishedAt'))}, {state.get('source')}) · 회수 {gc.fmt_mb(state.get('reclaimedMb', 0))}"
        if state.get("error"):
            line += f" · 실패: {state['error']}"
        print(line)
    else:
        print("마지막 정리  아직 실행 안 됨")
    if st["policy"]["enabled"]:
        print(f"다음 자동 실행  {_when(st['nextRunAt']) if st['nextRunAt'] and not st['due'] else '지금(데몬 다음 틱)'}")
    else:
        print("자동 정리  꺼짐 (marina docker gc policy enabled true)")
    _print_policy(st["policy"])


def main(argv: list[str]) -> int:
    if argv[:1] != ["gc"]:
        print(USAGE, file=sys.stderr)
        return 2
    args = argv[1:]
    as_json = "--json" in args
    args = [a for a in args if a != "--json"]
    now = time.time()

    if args[:1] == ["policy"]:
        if len(args) == 1:
            policy = gc.load_policy()
            print(json.dumps(policy, ensure_ascii=False, indent=2)) if as_json else _print_policy(policy)
            return 0
        if len(args) != 3:
            print("usage: marina docker gc policy <key> <value>", file=sys.stderr)
            return 2
        try:
            policy = gc.set_policy(args[1], args[2])
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        print(json.dumps(policy, ensure_ascii=False, indent=2)) if as_json else print(f"{args[1]} = {json.dumps(policy[args[1]], ensure_ascii=False)}")
        return 0

    if args[:1] == ["status"]:
        st = gc.status(now=now)
        print(json.dumps(st, ensure_ascii=False, indent=2)) if as_json else _print_status(st, now)
        return 0

    dry_run, force = "--dry-run" in args, "--now" in args
    unknown = [a for a in args if a not in ("--dry-run", "--now")]
    if unknown:
        print(f"error: 알 수 없는 인자 {unknown}\n{USAGE}", file=sys.stderr)
        return 2
    policy = gc.load_policy()
    if not dry_run and not force:
        state = gc.load_state()
        if not policy["enabled"]:
            msg = "자동 정리가 꺼져 있습니다 — 지금 돌리려면 --now, 켜려면 `marina docker gc policy enabled true`"
            print(json.dumps({"skipped": "disabled", "message": msg}, ensure_ascii=False) if as_json else msg)
            return 0
        if not gc.due(policy, state, now):
            msg = f"아직 주기가 안 됐습니다 — 다음 자동 실행 {_when(gc.next_run_at(policy, state))} (지금 돌리려면 --now)"
            print(json.dumps({"skipped": "not-due", "nextRunAt": gc.next_run_at(policy, state), "message": msg}, ensure_ascii=False) if as_json else msg)
            return 0
    report = gc.collect(policy, source="cli", dry_run=dry_run, now=now)
    print(json.dumps(report, ensure_ascii=False, indent=2)) if as_json else _print_report(report)
    return 1 if report.get("error") else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
