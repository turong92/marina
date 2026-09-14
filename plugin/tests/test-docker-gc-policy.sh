#!/usr/bin/env bash
# 도커 GC 정책 파일 — 기본값·머지·틀린 값 폴백·set_policy 타입 변환·원자 쓰기·due 판정.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import json, os, time
from pathlib import Path
import marina_docker_gc as gc

home = Path(os.environ["MARINA_HOME"])
assert gc.POLICY_FILE == home / "docker-gc.json", gc.POLICY_FILE
assert gc.STATE_FILE == home / "docker-gc-state.json"
assert gc.LOG_FILE == home / "docker-gc.log"

# ── 파일 없음 → 기본값 ──
p = gc.load_policy()
assert p["enabled"] is True and p["interval_hours"] == 24 and p["build_cache_keep_days"] == 7, p
assert p["dangling_images"] is True and p["anonymous_volumes"] is True
assert p["stale_test_artifacts_days"] == 3 and p["stale_test_artifact_names"] == ["marina-*-e2e-*"], p
assert p["warnings"] == [], p

# ── 부분 파일 머지 + 틀린 타입은 그 키만 기본값(경고) ──
gc.POLICY_FILE.write_text(json.dumps({"interval_hours": "abc", "build_cache_keep_days": 2,
                                      "dangling_images": "nope", "unknown_key": 1}))
p = gc.load_policy()
assert p["interval_hours"] == 24 and p["build_cache_keep_days"] == 2 and p["dangling_images"] is True, p
assert any("interval_hours" in w for w in p["warnings"]), p["warnings"]
assert any("dangling_images" in w for w in p["warnings"]), p["warnings"]
assert any("unknown_key" in w for w in p["warnings"]), p["warnings"]

# ── 깨진 JSON → 기본값 + 경고 ──
gc.POLICY_FILE.write_text("{not json")
p = gc.load_policy()
assert p["interval_hours"] == 24 and p["warnings"], p

# ── set_policy: 문자열 → 타입 변환, 파일에 반영, 원자 쓰기(임시파일 안 남음) ──
gc.POLICY_FILE.unlink()
p = gc.set_policy("interval_hours", "12");            assert p["interval_hours"] == 12, p
p = gc.set_policy("dangling_images", "false");        assert p["dangling_images"] is False, p
p = gc.set_policy("anonymous_volumes", "on");         assert p["anonymous_volumes"] is True, p
p = gc.set_policy("stale_test_artifact_names", "a*, b*"); assert p["stale_test_artifact_names"] == ["a*", "b*"], p
p = gc.set_policy("stale_test_artifacts_days", 0);    assert p["stale_test_artifacts_days"] == 0, p
on_disk = json.loads(gc.POLICY_FILE.read_text())
assert on_disk["interval_hours"] == 12 and on_disk["dangling_images"] is False and on_disk["stale_test_artifact_names"] == ["a*", "b*"], on_disk
assert "warnings" not in on_disk, on_disk
assert not [f for f in home.iterdir() if f.name.startswith(".docker-gc.json")], list(home.iterdir())
for bad in (("nope", 1), ("interval_hours", "-3"), ("interval_hours", "x"), ("enabled", "maybe"), ("stale_test_artifact_names", "")):
    try:
        gc.set_policy(*bad)
    except ValueError:
        pass
    else:
        raise AssertionError(f"set_policy{bad} 가 ValueError 를 안 냄")
assert json.loads(gc.POLICY_FILE.read_text())["interval_hours"] == 12   # 실패한 쓰기는 파일을 안 건드림

# ── due 판정 ──
now = 1_000_000.0
pol = gc.load_policy()   # interval 12h
assert gc.due(pol, {}, now) is True                                     # 실행 기록 없음 → 지금
assert gc.due(pol, {"finishedAt": now - 11 * 3600}, now) is False        # 아직
assert gc.due(pol, {"finishedAt": now - 13 * 3600}, now) is True
assert gc.due(pol, {"finishedAt": now - 13 * 3600, "error": "x"}, now) is True   # 실패한 실행도 주기 기준
assert gc.due({**pol, "enabled": False}, {}, now) is False
assert gc.next_run_at(pol, {}) is None
assert gc.next_run_at(pol, {"finishedAt": now}) == now + 12 * 3600
assert gc.load_state() == {}
print("ok")
PY
echo "PASS test-docker-gc-policy"
