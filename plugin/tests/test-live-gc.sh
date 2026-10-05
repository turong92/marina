#!/usr/bin/env bash
# 도커 GC 가 live(상시 운영) 산출물을 건드리지 않는다.
#
# 왜 필요한가(실측): ⑤ 고아 단계는 "등록 프로젝트 접두사로 시작하는데 지금 발견되는 어느
# 워크트리와도 안 맞는" compose 프로젝트를 고아로 본다. live 는 **워크트리가 없는 것이
# 정상**이므로 `<id>-live` 가 그 조건에 정확히 들어맞는다. 실행 중이면 busy 로 살지만,
# 정지한 live(재부팅 실패·일시 중단)는 컨테이너와 **이미지**가 회수된다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import json
from datetime import datetime, timezone
import marina_docker_gc as gc

assert gc.LIVE_LABEL == "marina.live", gc.LIVE_LABEL

NOW = datetime(2026, 10, 6, 12, 0, tzinfo=timezone.utc).timestamp()
OLD = "2026-09-01T00:00:00Z"
def dk(iso): return iso.replace("T", " ").replace("Z", " +0000 UTC")
def nd(rows): return "\n".join(json.dumps(r) for r in rows) + ("\n" if rows else "")

# ① live 세션 이름은 발견된 워크트리 목록에 **항상** 들어간다 — live 는 워크트리가 없다
names = gc._live_session_project_names([{"id": "ovation"}, {"id": "mdc-main"}])
assert "ovation-live" in names and "mdc-main-live" in names, names

LIVE_WT = {"ovation-main"}            # 발견되는 워크트리 — live 는 여기 없다(정상)
PREFIXES = ["ovation-"]

class Fake:
    def __init__(self):
        self.removed = []
        # id → (status, image sha, name, labels, created)
        self.containers = {
            "l1": ("exited", "a" * 64, "/ovation-live-server-1", 
                   {"com.docker.compose.project": "ovation-live", "marina.live": "1", "marina.project": "ovation"}, OLD),
            "g1": ("exited", "b" * 64, "/ovation-gone-web-1",
                   {"com.docker.compose.project": "ovation-gone"}, OLD),
            # 레지스트리에서 프로젝트를 지웠지만 live 가 아직 돌던 경우 — 라벨만이 신호다
            "l2": ("exited", "c" * 64, "/unregistered-live-web-1",
                   {"com.docker.compose.project": "unregistered-live", "marina.live": "1"}, OLD),
        }
    def __call__(self, args):
        a = list(args); s = " ".join(a)
        if s == "system df -v --format json":
            return json.dumps({"BuildCache": [], "Images": [], "Containers": [], "Volumes": []})
        if s == "ps -a -q": return "\n".join(self.containers) + "\n"
        if a[:2] == ["inspect", "--format"]:
            return "".join(f"{cid}\t{v[0]}\tsha256:{v[1]}\t{v[2]}\t{v[4]}\t{json.dumps(v[3])}\n"
                           for cid, v in self.containers.items() if cid in a[3:])
        if a[:1] == ["rm"]:
            self.removed.append(a[1]); del self.containers[a[1]]; return a[1] + "\n"
        if s == "image ls --filter label=com.docker.compose.project --format json":
            return nd([{"ID": "aaaaaaaaaaaa", "Repository": "ovation-live-server", "Tag": "latest", "Size": "2GB", "CreatedAt": dk(OLD)},
                       {"ID": "bbbbbbbbbbbb", "Repository": "ovation-gone-web", "Tag": "latest", "Size": "1GB", "CreatedAt": dk(OLD)}])
        if a[:3] == ["image", "inspect", "--format"]:
            m = {"aaaaaaaaaaaa": "ovation-live", "bbbbbbbbbbbb": "ovation-gone"}
            return "".join(f"sha256:{i}{'0' * 52}\t{m[i]}\n" for i in a[4:])
        if a[:2] == ["image", "rm"]:
            self.removed.append(a[2]); return "Deleted: " + a[2] + "\n"
        raise AssertionError(f"예상 밖 docker 호출: {a}")

policy = {**gc.load_policy(), "build_cache_keep_days": 0, "dangling_images": False,
          "anonymous_volumes": False, "stale_test_artifacts_days": 0}
gc._live_compose_projects = lambda: (set(LIVE_WT), list(PREFIXES))

fake = Fake()
steps = gc.collect(policy, now=NOW, run=fake, dry_run=False)["steps"]
orph = next(s for s in steps if s["name"] == "orphans")
items = " ".join(orph["items"])

# ② live 컨테이너·이미지는 회수 대상이 아니다
assert "ovation-live" not in items, items
assert not any("ovation-live" in str(r) or r == "l1" for r in fake.removed), fake.removed
assert "l1" in fake.containers, "live 컨테이너가 지워졌다"

# ③ 라벨만 있고 레지스트리에 없는 live 도 지키다 — 프로젝트를 지웠다고 운영 중인 것을 날리지 않는다
assert "l2" in fake.containers, "라벨 붙은 live 컨테이너가 지워졌다"

# ④ 진짜 고아는 그대로 회수한다 (면제가 단계를 무력화하지 않았다)
assert "ovation-gone" in items, items
assert "g1" in fake.removed, fake.removed
print("ok")
PY

echo "--- e2e 단계도 live 를 건드리지 않는다"
PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import json
from datetime import datetime, timezone
import marina_docker_gc as gc
gc._live_compose_projects = lambda: None
NOW = datetime(2026, 10, 6, 12, 0, tzinfo=timezone.utc).timestamp()
OLD = "2026-09-01T00:00:00Z"
def dk(iso): return iso.replace("T", " ").replace("Z", " +0000 UTC")
def nd(rows): return "\n".join(json.dumps(r) for r in rows) + ("\n" if rows else "")

class Fake:
    def __init__(self):
        self.removed = []
        # live 라벨과 e2e 라벨이 **동시에** 붙은 경우 — 운영이 이긴다
        self.containers = {"x1": ("exited", "a" * 64, "/ovation-live-server-1",
                                  {"marina.e2e": "1", "marina.live": "1"}, OLD)}
    def __call__(self, args):
        a = list(args); s = " ".join(a)
        if s == "system df -v --format json":
            return json.dumps({"BuildCache": [], "Images": [], "Containers": [], "Volumes": []})
        if s == "ps -a -q": return "\n".join(self.containers) + "\n"
        if a[:2] == ["inspect", "--format"]:
            return "".join(f"{cid}\t{v[0]}\tsha256:{v[1]}\t{v[2]}\t{v[4]}\t{json.dumps(v[3])}\n"
                           for cid, v in self.containers.items() if cid in a[3:])
        if a[:1] == ["rm"]:
            self.removed.append(a[1]); del self.containers[a[1]]; return a[1] + "\n"
        if s == "images --filter label=marina.e2e=1 -q": return ""
        if s == "images --format json": return nd([])
        if s == "network ls --format json": return nd([])
        raise AssertionError(f"예상 밖 docker 호출: {a}")

policy = {**gc.load_policy(), "build_cache_keep_days": 0, "dangling_images": False,
          "anonymous_volumes": False, "orphan_worktree_days": 0}
fake = Fake()
steps = gc.collect(policy, now=NOW, run=fake, dry_run=False)["steps"]
e2e = next(s for s in steps if s["name"] == "e2e")
assert not e2e["items"], e2e["items"]
assert "x1" in fake.containers, "live 라벨이 붙었는데 e2e 단계가 지웠다"
print("ok")
PY
echo "PASS test-live-gc"
