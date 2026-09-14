#!/usr/bin/env bash
# 도커 GC 판정·실행 — 가짜 docker run 으로 네 단계의 포함/제외 경계, dry-run 무삭제, 실행 명령 순서(-f 없음),
# 단계 실패 후 계속, 회수량 파싱, 로그·상태 파일을 검증한다. 실 도커는 건드리지 않는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import json, os
from datetime import datetime, timezone
import marina_docker_gc as gc

NOW = datetime(2026, 9, 14, 12, 0, tzinfo=timezone.utc).timestamp()
OLD, RECENT, ANCIENT = "2026-09-01T00:00:00Z", "2026-09-13T06:00:00Z", "2026-08-01T00:00:00Z"
def dk(iso):   # docker CLI 목록 포맷("2026-09-14 11:36:49 +0900 KST" 꼴)
    return iso.replace("T", " ").replace("Z", " +0000 UTC")
def nd(rows): return "\n".join(json.dumps(r) for r in rows) + ("\n" if rows else "")
SHA = lambda h: "sha256:" + h * 5 + h[:4]        # 12hex → 64hex 흉내

DF = {"BuildCache": [
        {"ID": "bcA", "InUse": "false", "LastUsedAt": dk(OLD), "CreatedAt": dk(ANCIENT), "Size": "2GB"},
        {"ID": "bcB", "InUse": "true", "LastUsedAt": dk(ANCIENT), "CreatedAt": dk(ANCIENT), "Size": "1GB"},
        {"ID": "bcC", "InUse": "false", "LastUsedAt": dk(RECENT), "CreatedAt": dk(ANCIENT), "Size": "500MB"},
        {"ID": "bcD", "InUse": "false", "CreatedAt": dk(ANCIENT), "Size": "300MB"}],
      "Volumes": [
        {"Name": "a" * 64, "Size": "100MB"}, {"Name": "proj_data", "Size": "50MB"}, {"Name": "b" * 64, "Size": "20MB"}],
      "Images": [], "Containers": []}

class FakeDocker:
    def __init__(self, fail_builder=False):
        self.calls, self.fail_builder = [], fail_builder
        self.containers = {   # id → (status, image sha, name, labels, created)
            "c1": ("running", SHA("bbbbbbbbbbbb"), "/keep", {}, OLD),
            "c2": ("exited", SHA("111111111111"), "/marina-weave-e2e-redis-123", {}, OLD),
            "c3": ("running", SHA("222222222222"), "/marina-x-e2e-y", {"marina.e2e": "1"}, ANCIENT),
            "c4": ("exited", SHA("cccccccccccc"), "/mdce2e9-featbr-web-1", {"marina.e2e": "1"}, RECENT),
            "c5": ("exited", SHA("dddddddddddd"), "/old-e2e-thing", {"marina.e2e": "1"}, OLD),
        }
    def __call__(self, args):
        a = list(args); self.calls.append(a); s = " ".join(a)
        if s == "system df -v --format json": return json.dumps(DF)
        if s == "builder prune -f --filter until=168h":
            if self.fail_builder: raise RuntimeError("Cannot connect to the Docker daemon")
            return "Deleted build cache objects:\nbcA\n\nTotal reclaimed space: 2.5GB\n"
        if s == "images -f dangling=true --format json":
            return nd([{"ID": "aaaaaaaaaaaa", "Repository": "<none>", "Tag": "<none>", "Size": "400MB", "CreatedAt": dk(OLD)},
                       {"ID": "bbbbbbbbbbbb", "Repository": "<none>", "Tag": "<none>", "Size": "600MB", "CreatedAt": dk(OLD)}])
        if s == "image prune -f": return "Total reclaimed space: 400MB\n"
        if s == "volume ls -f dangling=true --format json":
            return nd([{"Name": "a" * 64, "Driver": "local"}, {"Name": "proj_data", "Driver": "local"}])
        if s == "volume prune -f": raise AssertionError("volume prune 은 유예를 못 가리므로 쓰면 안 된다")
        if a[:2] == ["volume", "rm"]:
            assert len(a) == 3 and a[2] == "a" * 64, a; return a[2] + "\n"
        if s == "ps -a -q": return "\n".join(self.containers) + "\n"
        if a[:1] == ["inspect"] and a[1] == "--format":
            return "".join(f"{cid}\t{v[0]}\t{v[1]}\t{v[2]}\t{v[4]}\t{json.dumps(v[3])}\n" for cid, v in self.containers.items() if cid in a[3:])
        if a[:1] == ["rm"]:
            assert len(a) == 2 and a[1] in self.containers, a
            assert self.containers[a[1]][0] != "running", f"실행 중 컨테이너 삭제 시도: {a}"
            del self.containers[a[1]]; return a[1] + "\n"
        if s == "images --format json":
            return nd([{"ID": "cccccccccccc", "Repository": "mdce2e9-featbr-web", "Tag": "latest", "Size": "200MB", "CreatedAt": dk(OLD)},
                       {"ID": "dddddddddddd", "Repository": "proj-9-weaveapp", "Tag": "latest", "Size": "300MB", "CreatedAt": dk(OLD)},
                       {"ID": "eeeeeeeeeeee", "Repository": "young-e2e", "Tag": "latest", "Size": "50MB", "CreatedAt": dk(RECENT)},
                       {"ID": "ffffffffffff", "Repository": "marina-foo-e2e-bar", "Tag": "latest", "Size": "700MB", "CreatedAt": dk(ANCIENT)},
                       {"ID": "999999999999", "Repository": "redis", "Tag": "7-alpine", "Size": "40MB", "CreatedAt": dk(ANCIENT)}])
        if s == "images --filter label=marina.e2e=1 -q": return "cccccccccccc\ndddddddddddd\neeeeeeeeeeee\n"
        if a[:2] == ["image", "rm"]:
            assert len(a) == 3, a; return "Deleted: " + a[2] + "\n"
        if s == "network ls --format json":
            return nd([{"ID": "n1", "Name": "mdce2e9-featbr_default", "Labels": "com.docker.compose.project=x,marina.e2e=1", "CreatedAt": dk(OLD)},
                       {"ID": "n2", "Name": "marina-a-e2e-b_default", "Labels": "", "CreatedAt": dk(ANCIENT)},
                       {"ID": "n3", "Name": "bridge", "Labels": "", "CreatedAt": dk(ANCIENT)}])
        if a[:3] == ["network", "inspect", "--format"]:
            return "".join(f"{n}\t{'1' if n == 'n1' else '0'}\n" for n in a[4:])
        if a[:2] == ["network", "rm"]:
            assert len(a) == 3, a; return a[2] + "\n"
        raise AssertionError(f"예상 밖 docker 호출: {a}")

def mutating(calls):
    return [c for c in calls if c[:1] in (["rm"], ["prune"]) or c[:2] in (["image", "rm"], ["network", "rm"], ["volume", "rm"], ["builder", "prune"], ["image", "prune"], ["volume", "prune"])]

# ── 시간 파싱 ──
assert gc.parse_docker_time("2026-09-14 11:36:49 +0900 KST") == datetime(2026, 9, 14, 2, 36, 49, tzinfo=timezone.utc).timestamp()
assert gc.parse_docker_time("2026-07-30 10:12:52.788215376 +0000 UTC") == datetime(2026, 7, 30, 10, 12, 52, tzinfo=timezone.utc).timestamp()
assert gc.parse_docker_time("2026-09-14T02:36:49.729117876Z") == datetime(2026, 9, 14, 2, 36, 49, tzinfo=timezone.utc).timestamp()
assert gc.parse_docker_time("garbage") is None
assert gc.parse_reclaimed_mb("x\nTotal reclaimed space: 2.5GB\n") == 2560 and gc.parse_reclaimed_mb("nothing") is None
assert gc.fmt_mb(2560) == "2.5GB" and gc.fmt_mb(512) == "512MB" and gc.fmt_mb(0) == "0B"

# ── dry-run(plan): 판정만, 삭제 0회 ──
policy = gc.load_policy()
fake = FakeDocker()
rep = gc.plan(policy, now=NOW, run=fake)
assert rep["dryRun"] is True and mutating(fake.calls) == [], mutating(fake.calls)
steps = {s["name"]: s for s in rep["steps"]}
assert list(steps) == ["build-cache", "dangling", "volumes", "e2e"], list(steps)
assert steps["build-cache"]["reclaimedMb"] == 2048 + 300, steps["build-cache"]        # InUse·최근 제외, LastUsedAt 없으면 CreatedAt
assert steps["dangling"]["reclaimedMb"] == 400 and len(steps["dangling"]["items"]) == 1, steps["dangling"]   # 컨테이너가 쓰는 bbbb 제외
assert steps["volumes"]["reclaimedMb"] == 0 and steps["volumes"]["items"] == [] and steps["volumes"]["waiting"] == 1, steps["volumes"]   # 처음 본 익명 볼륨은 유예(3일) 대기
seen = json.loads(gc.VOLUMES_SEEN_FILE.read_text())
assert set(seen) == {"a" * 64} and seen["a" * 64] == NOW, seen                                             # 명명 볼륨(proj_data)은 기록조차 안 함
e2e = steps["e2e"]
assert e2e["counts"] == {"containers": 2, "images": 2, "networks": 1}, e2e["counts"]
items = "\n".join(e2e["items"])
assert "marina-weave-e2e-redis-123" in items and "old-e2e-thing" in items, items           # 이름 글롭 + 라벨
assert "marina-x-e2e-y" not in items, items                                                  # 실행 중
assert "mdce2e9-featbr-web-1" not in items and "mdce2e9-featbr-web:latest" not in items, items   # 어린 컨테이너 + 그 이미지
assert "proj-9-weaveapp" in items and "marina-foo-e2e-bar" in items, items                 # 지워질 컨테이너가 쓰던 이미지는 회수, 글롭 이미지
assert "young-e2e" not in items and "redis:7-alpine" not in items, items
assert "marina-a-e2e-b_default" in items and "mdce2e9-featbr_default" not in items, items   # 사용 중 네트워크 제외
assert e2e["reclaimedMb"] == 300 + 700, e2e
assert rep["reclaimedMb"] == 2348 + 400 + 0 + 1000, rep["reclaimedMb"]
assert not gc.STATE_FILE.exists()                                                           # dry-run 은 상태 안 씀
assert "would reclaim" in gc.LOG_FILE.read_text() and "cli/dry" in gc.LOG_FILE.read_text(), gc.LOG_FILE.read_text()

# ── 유예 지남: 처음 본 시각이 grace 보다 오래면 대상, 목록에서 빠진(다시 붙은) 볼륨은 기록 삭제 ──
gc.VOLUMES_SEEN_FILE.write_text(json.dumps({"a" * 64: NOW - 4 * 86400, "f" * 64: NOW - 30 * 86400}))
fake = FakeDocker()
rep = gc.plan(policy, now=NOW, run=fake)
steps = {s["name"]: s for s in rep["steps"]}
assert steps["volumes"]["reclaimedMb"] == 100 and len(steps["volumes"]["items"]) == 1 and steps["volumes"]["waiting"] == 0, steps["volumes"]
assert set(json.loads(gc.VOLUMES_SEEN_FILE.read_text())) == {"a" * 64}, "더는 dangling 아닌 볼륨 기록은 지운다"
assert mutating(fake.calls) == [], mutating(fake.calls)
fake = FakeDocker()
rep = gc.plan({**policy, "anonymous_volume_grace_days": 0}, now=NOW + 1, run=fake)          # 유예 0 = 즉시
assert {s["name"]: s for s in rep["steps"]}["volumes"]["reclaimedMb"] == 100

# ── 단계 끄기 ──
fake = FakeDocker()
rep = gc.plan({**policy, "build_cache_keep_days": 0, "dangling_images": False, "anonymous_volumes": False, "stale_test_artifacts_days": 0}, now=NOW, run=fake)
assert all(s["skipped"] for s in rep["steps"]) and rep["reclaimedMb"] == 0, rep
assert fake.calls == [], fake.calls                                                         # 전부 꺼지면 도커도 안 부른다

# ── 실행(collect): 명령 순서, -f 없음, 회수량 파싱, 상태·로그 ──
fake = FakeDocker()
rep = gc.collect(policy, source="auto", now=NOW, run=fake)
assert rep["dryRun"] is False and rep["error"] is None, rep
got = mutating(fake.calls)
assert got == [["builder", "prune", "-f", "--filter", "until=168h"], ["image", "prune", "-f"], ["volume", "rm", "a" * 64],
               ["rm", "c2"], ["rm", "c5"], ["image", "rm", "dddddddddddd"], ["image", "rm", "ffffffffffff"], ["network", "rm", "n2"]], got
assert all("-f" not in c for c in got if c[0] in ("rm",) or c[:2] in (["image", "rm"], ["network", "rm"])), got
steps = {s["name"]: s for s in rep["steps"]}
assert steps["build-cache"]["reclaimedMb"] == 2560 and steps["dangling"]["reclaimedMb"] == 400 and steps["volumes"]["reclaimedMb"] == 100, steps
assert rep["reclaimedMb"] == 2560 + 400 + 100 + 1000, rep["reclaimedMb"]
state = json.loads(gc.STATE_FILE.read_text())
assert state["finishedAt"] >= NOW and state["reclaimedMb"] == rep["reclaimedMb"] and state["source"] == "auto" and state["error"] is None, state
log = gc.LOG_FILE.read_text().splitlines()
assert log[-1].split()[1] == "auto" and "reclaimed 4.0GB" in log[-1] and "e2e" in log[-1], log[-1]
assert gc.due(policy, state, now=NOW + 3600) is False and gc.due(policy, state, now=NOW + 25 * 3600) is True
assert json.loads(gc.VOLUMES_SEEN_FILE.read_text()) == {}, "지운 볼륨은 기록에서도 빠진다"

# ── 단계 실패 → 다음 단계 계속, 오류 기록 ──
fake = FakeDocker(fail_builder=True)
rep = gc.collect(policy, source="dashboard", now=NOW, run=fake)
steps = {s["name"]: s for s in rep["steps"]}
assert "Docker daemon" in steps["build-cache"]["error"], steps["build-cache"]
assert steps["dangling"]["reclaimedMb"] == 400 and steps["e2e"]["counts"]["containers"] == 2, steps
assert rep["error"] and "build-cache" in rep["error"], rep["error"]
assert "FAILED" in gc.LOG_FILE.read_text().splitlines()[-1]
assert json.loads(gc.STATE_FILE.read_text())["error"], "실패도 상태에 남아 다음 주기 판정에 쓰인다"
print("ok")
PY
echo "PASS test-docker-gc-plan"
