#!/usr/bin/env bash
# 유휴 워크트리 자동 정리(데몬) — 형(2026-09-17): "워크트리 남은 건 까먹을 것 같다, 7일 사용 안 한 거 자동 gc".
# 판정·가드는 대시보드 일괄 정리(gc_plan/gc_remove)와 같고, 자동이라 ① 캐시성 볼륨만 지우고(개발 DB 보존)
# ② 한 번에 5개까지(발견 오류 시 피해 한정) ③ 기록된 데몬만·정책 주기대로 돈다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

PYTHONPATH="$HERE/../scripts" python3 - <<'PY'
import json
from pathlib import Path
import marina_docker_gc as dgc
import marina_worktree_gc as wg
import marina_lifecycle as lc
import marina_cache

NOW = 1_789_700_000.0
assert dgc.load_policy()["worktree_auto_days"] == 7 and wg.GC_DAYS_DEFAULT == 7

def entry(i, idle, eligible=True):
    return {"root": f"/wt/w{i}", "id": f"w{i}", "gcIdleDays": idle, "eligible": eligible}

calls = []
def plan_fn(days, apply, refresh, strict):
    calls.append(("plan", days, apply, refresh, strict))
    return [entry(1, 8), entry(2, 30), entry(3, 9, eligible=False), entry(4, 12), entry(5, 20), entry(6, 40), entry(7, 10)]
def remove_fn(roots, days, volumes, strict):
    calls.append(("remove", [str(r) for r in roots], days, volumes, strict))
    return [{"id": Path(r).name, "root": str(r), "removed": Path(r).name != "w4", "freedMb": 1000,
             "reason": None if Path(r).name != "w4" else "더는 유휴가 아님",
             "backups": [{"repo": "/repo", "branch": "backup/worktree-w6-20260917"}] if Path(r).name == "w6" else [],
             "result": {"reclaim": {"keptVolumes": ["p-w2_mysql"]}} if Path(r).name == "w2" else {}} for r in roots]

# 기록된 데몬이 아니면 안 돈다(격리 프리뷰가 실 워크트리를 지우면 안 됨)
assert wg.auto_tick(3900, now=NOW, primary=False, plan_fn=plan_fn, remove_fn=remove_fn) == "skipped:not-primary" and not calls
# 끄기
dgc.set_policy("worktree_auto_days", 0)
assert wg.auto_tick(3900, now=NOW, primary=True, plan_fn=plan_fn, remove_fn=remove_fn) == "skipped:off" and not calls
dgc.set_policy("worktree_auto_days", 7)

# 첫 실행은 예고만 — 지우지 않고 다음 주기 대상을 기록(켜자마자 지우지 않는다)
r = wg.auto_tick(3900, now=NOW - 25 * 3600, primary=True, plan_fn=plan_fn, remove_fn=remove_fn)
assert r == "armed:5" and [c[0] for c in calls] == ["plan"], (r, calls)
armed = json.loads(wg.AUTO_STATE_FILE.read_text())
assert armed["armedAt"] and [w["id"] for w in armed["wouldRemove"]] == ["w6", "w2", "w5", "w4", "w7"], armed
assert "worktree  armed" in dgc.LOG_FILE.read_text().splitlines()[-1]
calls.clear()

# 다음 주기: 적격만, 오래 쉰 순, 최대 5개, volumes=cache, strict(gitignore 로컬 파일 보호), 7일 기준
r = wg.auto_tick(3900, now=NOW, primary=True, plan_fn=plan_fn, remove_fn=remove_fn)
assert calls[0] == ("plan", 7, False, True, True), calls[0]
kind, roots, days, volumes, strict = calls[1]
assert kind == "remove" and days == 7 and volumes == "cache" and strict is True, calls[1]
assert roots == ["/wt/w6", "/wt/w2", "/wt/w5", "/wt/w4", "/wt/w7"], ("오래 쉰 순·부적격 제외·5개 제한", roots)
assert r == "ran:4", r
st = json.loads(wg.AUTO_STATE_FILE.read_text())
assert st["armedAt"] == armed["armedAt"], "예고 시각은 유지"
assert st["eligible"] == 6 and st["removed"] == 4 and st["deferred"] == 1 and st["freedMb"] == 4000, st
w2 = next(i for i in st["items"] if i["id"] == "w2"); assert w2["keptVolumes"] == ["p-w2_mysql"], w2
w6 = next(i for i in st["items"] if i["id"] == "w6"); assert w6["backups"] == ["/repo:backup/worktree-w6-20260917"], w6
log = dgc.LOG_FILE.read_text().splitlines()[-1]
assert "worktree  removed 4/6 idle>7d" in log and "backups 1" in log and "deferred 1" in log and "SKIPPED w4" in log, log
assert dgc.status(with_disk=False)["worktreeAuto"]["removed"] == 4, "대시보드 상태에 실린다"

# 주기 안이면 다시 안 돈다
calls.clear()
assert wg.auto_tick(3900, now=NOW + 3600, primary=True, plan_fn=plan_fn, remove_fn=remove_fn) == "skipped:not-due" and not calls
assert wg.auto_tick(3900, now=NOW + 25 * 3600, primary=True, plan_fn=plan_fn, remove_fn=remove_fn) == "ran:4"

# 예외는 밖으로 안 새고 로그에 남는다
def boom(*a, **k): raise RuntimeError("discover broke")
assert wg.auto_tick(3900, now=NOW + 60 * 86400, primary=True, plan_fn=boom, remove_fn=remove_fn).startswith("failed:")
assert "worktree  FAILED discover broke" in dgc.LOG_FILE.read_text().splitlines()[-1]

# ── reclaim_worktree_docker(volumes="cache"): 캐시성 볼륨만 지우고 데이터 볼륨은 남긴다 ──
removed_vols, removed_imgs = [], []
lc.compose_build_image_items = lambda root: [{"imageId": "sha256:img1", "sizeMb": 500}]
lc.compose_project_volume_items = lambda root: [{"volume": "p-w_node_modules", "sizeMb": 300}, {"volume": "p-w_mysql", "sizeMb": 200}]
lc.docker_image_rm = lambda i: removed_imgs.append(i) or True
lc.docker_volume_rm = lambda n: removed_vols.append(n) or True
marina_cache.cache_items_by_category = lambda root: {"node_modules": [{"type": "volume", "volume": "p-w_node_modules"}], "gradle": [{"type": "path", "path": "/x"}]}
out = lc.reclaim_worktree_docker(Path("/wt/w"), volumes="cache")
assert removed_imgs == ["sha256:img1"] and removed_vols == ["p-w_node_modules"], (removed_imgs, removed_vols)
assert out["keptVolumes"] == ["p-w_mysql"] and out["freedMb"] == 800, out
removed_vols.clear()
out = lc.reclaim_worktree_docker(Path("/wt/w"))          # 사람이 고를 때(기본 all) — 기존 동작 그대로
assert removed_vols == ["p-w_node_modules", "p-w_mysql"] and "keptVolumes" not in out, (removed_vols, out)
# 캐시 목록 조회가 실패하면 볼륨을 하나도 안 지운다(모르면 보존)
removed_vols.clear()
def cache_boom(root): raise RuntimeError("compose unreadable")
marina_cache.cache_items_by_category = cache_boom
out = lc.reclaim_worktree_docker(Path("/wt/w"), volumes="cache")
assert removed_vols == [] and out["keptVolumes"] == ["p-w_mysql", "p-w_node_modules"] and any("cache volumes" in e for e in out["errors"]), out
print("ok")
PY

# ── (d) 다시 못 만드는 gitignore 파일 판정 — 실제 git ──
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
SRC="$T/src"; mkdir -p "$SRC" && cd "$SRC" && git init -q && printf 'tasks/\nnode_modules/\n.env.local\n*.log\n.DS_Store\nnotes.txt\n' > .gitignore && git add .gitignore && git -c user.email=t@t -c user.name=t commit -qm init
echo same > "$SRC/.env.local"                                   # 원본에도 있는 파일(links copy 흉내)
git -C "$SRC" worktree add -q "$SRC/.claude/worktrees/wt" -b wt
WT="$SRC/.claude/worktrees/wt"
mkdir -p "$WT/node_modules/x" "$WT/tasks/job" "$WT/sub"; echo js > "$WT/node_modules/x/i.js"; echo run > "$WT/a.log"; echo . > "$WT/.DS_Store"
echo same > "$WT/.env.local"                                    # 원본과 같음 → 다시 만들 수 있음
ln -s /etc/hosts "$WT/notes.txt"                                # 심링크 → 제외
( cd "$WT/sub" && git init -q && printf 'secret.json\n' > .gitignore && git add .gitignore && git -c user.email=t@t -c user.name=t commit -qm s )
cd "$T"
PYTHONPATH="$HERE/../scripts" python3 - "$WT" <<'PY'
import sys
from pathlib import Path
import marina_worktree_gc as wg
wt = Path(sys.argv[1])
assert wg.unrecoverable_ignored(wt) == [], ("재생성 가능한 것만 있으면 빈 목록", wg.unrecoverable_ignored(wt))
(wt / "tasks/job/research.md").write_text("과업 노트")        # 실측 사례: gitignore 된 tasks/ 노트
(wt / "sub/secret.json").write_text("{}")                      # 중첩 레포 안 gitignore 파일
(wt / ".env.local").write_text("changed locally")              # 원본과 달라짐
lost = wg.unrecoverable_ignored(wt)
assert "tasks/" in lost and "sub/secret.json" in lost and ".env.local" in lost, lost
assert not any(x.startswith(("node_modules", "a.log", ".DS_Store", "notes.txt")) for x in lost), lost
g = wg.guard_report(wt, apply=False, strict=True)
assert not g["eligible"] and any("gitignore 된 로컬 파일" in r for r in g["reasons"]), g
g2 = wg.guard_report(wt, apply=False, strict=False)
assert g2.get("ignoredLocal") and not any("gitignore" in r for r in g2["reasons"]), ("사람이 고를 땐 경고로만", g2)
print("ok ignored")
PY
echo "PASS test-worktree-gc-auto"
