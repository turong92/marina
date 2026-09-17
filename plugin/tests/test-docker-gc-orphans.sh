#!/usr/bin/env bash
# 도커 GC ⑤ 사라진 워크트리 잔재 — marina 밖에서 지운 워크트리의 compose 프로젝트 이미지·볼륨·정지 컨테이너.
# 사고(2026-09-14): git·Claude 앱으로 지운 mdc-main 워크트리 이미지 28개(50GB+)가 남았다. 워크트리 GC 는 marina 로 지울 때만 회수한다.
# 가드: 등록 프로젝트 접두사로 시작 · 지금 발견되는 워크트리명과 불일치 · days 초과 · 실행 중 컨테이너 있는 프로젝트는 통째 제외.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import json
from datetime import datetime, timezone
import marina_docker_gc as gc

NOW = datetime(2026, 9, 17, 12, 0, tzinfo=timezone.utc).timestamp()
OLD, RECENT = "2026-09-01T00:00:00Z", "2026-09-16T12:00:00Z"
def dk(iso): return iso.replace("T", " ").replace("Z", " +0000 UTC")
def nd(rows): return "\n".join(json.dumps(r) for r in rows) + ("\n" if rows else "")
LIVE = {"mdc-main-main", "mdc-main-weather-d24c3e", "homeserver-main"}
PREFIXES = ["mdc-main-", "homeserver-"]

class Fake:
    def __init__(self):
        self.calls = []
        # id → (status, image sha, name, compose project, created)
        self.containers = {
            "c1": ("exited", "a" * 64, "/mdc-main-gone1-web-1", "mdc-main-gone1", OLD),        # 고아·정지 → 지움
            "c2": ("running", "b" * 64, "/mdc-main-gone2-web-1", "mdc-main-gone2", OLD),       # 고아지만 실행 중 → 프로젝트 통째 제외
            "c3": ("exited", "c" * 64, "/mdc-main-weather-d24c3e-web-1", "mdc-main-weather-d24c3e", OLD),   # 살아 있는 워크트리
            "c4": ("exited", "d" * 64, "/someoneelse-x-1", "someoneelse-x", OLD),               # marina 가 만든 게 아님
        }
    def __call__(self, args):
        a = list(args); self.calls.append(a); s = " ".join(a)
        if s == "system df -v --format json":
            return json.dumps({"BuildCache": [], "Images": [], "Containers": [],
                               "Volumes": [{"Name": "mdc-main-gone1_data", "Size": "300MB"}, {"Name": "mdc-main-new9_data", "Size": "50MB"},
                                           {"Name": "mdc-main-gone2_data", "Size": "10MB"}, {"Name": "homeserver-main_db", "Size": "1GB"}]})
        if s == "ps -a -q": return "\n".join(self.containers) + "\n"
        if a[:2] == ["inspect", "--format"]:
            return "".join(f"{cid}\t{v[0]}\tsha256:{v[1]}\t{v[2]}\t{v[4]}\t{json.dumps({'com.docker.compose.project': v[3]})}\n"
                           for cid, v in self.containers.items() if cid in a[3:])
        if a[:1] == ["rm"]:
            assert self.containers[a[1]][0] != "running", a
            del self.containers[a[1]]; return a[1] + "\n"
        if s == "image ls --filter label=com.docker.compose.project --format json":
            return nd([{"ID": "aaaaaaaaaaaa", "Repository": "mdc-main-gone1-web", "Tag": "latest", "Size": "3.4GB", "CreatedAt": dk(OLD)},
                       {"ID": "bbbbbbbbbbbb", "Repository": "mdc-main-gone2-web", "Tag": "latest", "Size": "3GB", "CreatedAt": dk(OLD)},
                       {"ID": "cccccccccccc", "Repository": "mdc-main-weather-d24c3e-web", "Tag": "latest", "Size": "3GB", "CreatedAt": dk(OLD)},
                       {"ID": "dddddddddddd", "Repository": "someoneelse-x", "Tag": "latest", "Size": "1GB", "CreatedAt": dk(OLD)},
                       {"ID": "eeeeeeeeeeee", "Repository": "mdc-main-new9-web", "Tag": "latest", "Size": "2GB", "CreatedAt": dk(RECENT)}])
        if a[:3] == ["image", "inspect", "--format"]:
            m = {"aaaaaaaaaaaa": "mdc-main-gone1", "bbbbbbbbbbbb": "mdc-main-gone2", "cccccccccccc": "mdc-main-weather-d24c3e",
                 "dddddddddddd": "someoneelse-x", "eeeeeeeeeeee": "mdc-main-new9"}
            return "".join(f"sha256:{i * 1}{'0' * 52}\t{m[i]}\n" for i in a[4:])
        if a[:2] == ["image", "rm"]: return "Deleted: " + a[2] + "\n"
        if s == "volume ls --filter label=com.docker.compose.project --format json":
            return nd([{"Name": "mdc-main-gone1_data", "Labels": "com.docker.compose.project=mdc-main-gone1,com.docker.compose.volume=data"},
                       {"Name": "mdc-main-new9_data", "Labels": "com.docker.compose.project=mdc-main-new9"},
                       {"Name": "mdc-main-gone2_data", "Labels": "com.docker.compose.project=mdc-main-gone2"},
                       {"Name": "homeserver-main_db", "Labels": "com.docker.compose.project=homeserver-main"}])
        if a[:3] == ["volume", "inspect", "--format"]:
            return (dk(RECENT) if a[4] == "mdc-main-new9_data" else dk(OLD)) + "\n"
        if a[:2] == ["volume", "rm"]: return a[2] + "\n"
        raise AssertionError(f"예상 밖 docker 호출: {a}")

def orphans_only(policy):
    return {**policy, "build_cache_keep_days": 0, "dangling_images": False, "anonymous_volumes": False, "stale_test_artifacts_days": 0}

policy = orphans_only(gc.load_policy())
assert gc.load_policy()["orphan_worktree_days"] == 7
gc._live_compose_projects = lambda: (set(LIVE), list(PREFIXES))

# dry-run: 판정만
fake = Fake()
rep = gc.plan(policy, now=NOW, run=fake)
st = {s["name"]: s for s in rep["steps"]}["orphans"]
items = "\n".join(st["items"])
assert "mdc-main-gone1-web-1" in items and "mdc-main-gone1-web:latest" in items, items
assert "volume" not in items, ("명명 볼륨은 어떤 경우에도 안 지운다 — 이름 바꾼 워크트리를 고아로 오판할 수 있다", items)
assert "gone2" not in items, ("실행 중 컨테이너가 있는 프로젝트는 통째 제외", items)
assert "weather" not in items and "someoneelse" not in items and "homeserver-main_db" not in items, items
assert "new9" not in items, ("days 안 지난 이미지·볼륨 제외", items)
assert st["counts"] == {"projects": 1, "containers": 1, "images": 1}, st["counts"]
assert st["reclaimedMb"] == gc._size_mb("3.4GB"), st["reclaimedMb"]
assert not [c for c in fake.calls if c[:1] == ["rm"] or c[:2] in (["image", "rm"], ["volume", "rm"])], "dry-run 은 안 지운다"

# 실행: -f 없이, 컨테이너 → 이미지 → 볼륨 순
fake = Fake()
rep = gc.collect(policy, source="cli", now=NOW, run=fake)
muts = [c for c in fake.calls if c[:1] == ["rm"] or c[:2] in (["image", "rm"], ["volume", "rm"])]
assert muts == [["rm", "c1"], ["image", "rm", "aaaaaaaaaaaa"]], muts
assert not [c for c in fake.calls if c[:1] == ["volume"]], ("볼륨 명령 자체를 안 낸다", fake.calls)
want = f"orphans {gc.fmt_mb(gc._size_mb('3.4GB'))}(1 projects: 1 containers, 1 images)"
assert want in gc.LOG_FILE.read_text().splitlines()[-1], gc.LOG_FILE.read_text().splitlines()[-1]

# 등록 프로젝트를 못 읽으면 아무것도 안 한다
gc._live_compose_projects = lambda: None
fake = Fake()
rep = gc.plan(policy, now=NOW, run=fake)
st = {s["name"]: s for s in rep["steps"]}["orphans"]
assert st["skipped"] and fake.calls == [], (st, fake.calls)

# 끄기
gc._live_compose_projects = lambda: (set(LIVE), list(PREFIXES))
fake = Fake()
rep = gc.plan({**policy, "orphan_worktree_days": 0}, now=NOW, run=fake)
assert {s["name"]: s for s in rep["steps"]}["orphans"]["skipped"] and fake.calls == []

print("ok")
PY

# ── 실제 레지스트리 이음매(스텁 없이): main·워크트리 둘 다 live, 루트 없는 등록 프로젝트는 접두사에서 빠짐 ──
TMPR="$(mktemp -d)"; trap 'rm -rf "$TMPR"' EXIT
R="$TMPR/demo"; mkdir -p "$R" && git -C "$R" init -q && git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$R" worktree add -q "$R/.claude/worktrees/session1" -b s1
python3 - "$MARINA_HOME/projects.json" "$R" "$TMPR/gone" <<'PY'
import json, sys
path, root, gone = sys.argv[1:]
json.dump({"projects": [
    {"id": "demo", "root": root, "worktreeGlobs": [".claude/worktrees/*"], "kind": "compose"},
    {"id": "gone-proj", "root": gone, "worktreeGlobs": [".claude/worktrees/*"], "kind": "compose"},
]}, open(path, "w"))
PY
PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import marina_docker_gc as gc
live, prefixes = gc._live_compose_projects()
assert "demo-main" in live and "demo-session1" in live, live
assert prefixes == ["demo-"], ("루트 없는 등록 프로젝트(gone-proj)는 접두사에서 빠져야 한다 — 전부 고아로 오판 방지", prefixes)
assert gc._compose_project_prefix("My Proj!") == "my-proj-", gc._compose_project_prefix("My Proj!")
print("ok registry")
PY
echo "PASS test-docker-gc-orphans"
