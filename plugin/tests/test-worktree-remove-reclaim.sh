#!/usr/bin/env bash
# 워크트리 삭제 시 그 compose 프로젝트의 **이미지·볼륨을 함께 회수**한다.
#
# 실측(2026-09-14): 워크트리 28개 중 22개가 세션·프로세스 0 인데 워크트리당 이미지 3~6GB × 서비스 수가
# 그대로였다 — remove_worktree 가 stop_all(compose down)만 하고 clear_worktree_images 를 부르지 않아서.
# 이 테스트는 (1) 기본 삭제가 이미지+볼륨을 지우고 회수 용량을 결과에 싣는지, (2) 회수가 실패해도
# 워크트리 삭제는 진행되는지(실패는 errors 로 드러남), (3) keep_images=True 면 docker 를 안 건드리는지.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

gi() { mkdir -p "$1"; git -C "$1" init -q -b main; git -C "$1" config user.email t@t.invalid; git -C "$1" config user.name T; echo ok>"$1/r"; git -C "$1" add r; git -C "$1" commit -qm i; }
SRC="$TMP/proj"; gi "$SRC"
mkdir -p "$SRC/.claude/worktrees"
for wt in wt-ok wt-fail wt-keep; do git -C "$SRC" worktree add -q --detach "$SRC/.claude/worktrees/$wt" HEAD; done
mkdir -p "$MARINA_HOME/proj"
cat > "$MARINA_HOME/projects.json" <<JSON
{"projects":[{"id":"proj","root":"$SRC","subrepos":[],"worktreeGlobs":[".claude/worktrees/*"],"kind":"compose","composeFile":"docker-compose.yml"}]}
JSON
cat > "$MARINA_HOME/proj/docker-compose.yml" <<'YAML'
services:
  web:
    build: .
  redis:
    image: redis:7
YAML

PYTHONPATH="$SCR" python3 - "$SRC" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

src = Path(sys.argv[1])
import marina_cache
import marina_lifecycle
from marina_registry import discover_all_roots

discover_all_roots(refresh=True)

# 도커·compose 는 가짜 — 이미지 1개(512MB)·프로젝트 볼륨 2개(120MB+999MB)
calls = {"image_rm": [], "volume_rm": [], "images_q": 0, "volumes_q": 0}
_real_check_output = subprocess.check_output
def fake_check_output(args, **kw):
    text = " ".join(str(a) for a in args)
    if not args or str(args[0]) != "docker" and not str(args[0]).endswith("/docker"):
        return _real_check_output(args, **kw)   # git 등은 진짜로(subprocess 모듈은 전역 하나)
    if "images --format json web" in text:
        calls["images_q"] += 1
        return json.dumps([{"Service": "web", "ID": "sha256:webimg", "Repository": "proj-web", "Tag": "latest", "Size": "512MB"}])
    if "volume ls -q --filter label=com.docker.compose.project=" in text:
        calls["volumes_q"] += 1
        proj = text.rsplit("=", 1)[-1]
        return f"{proj}_pgdata\n{proj}_node_modules\n"
    if "images --format json redis" in text:
        raise AssertionError("image-only 서비스는 조회하지 않는다")
    raise AssertionError(f"unexpected docker command: {text}")
marina_cache.subprocess.check_output = fake_check_output
marina_cache.docker_volume_sizes_mb = lambda names=None: {n: (999 if n.endswith("_pgdata") else 120) for n in (names or [])}
marina_lifecycle.docker_image_rm = lambda image_id: calls["image_rm"].append(image_id) or True
marina_lifecycle.docker_volume_rm = lambda name: calls["volume_rm"].append(name) or True
# 삭제 전 정지·세션 정리·launchd 는 이 테스트의 관심사가 아니다 — 부르긴 하는지만 센다
stopped = []
marina_lifecycle.stop_all = lambda root: stopped.append(str(root)) or {"stoppedAll": True}
marina_lifecycle.cleanup_session = lambda root: {"removed": ""}
marina_lifecycle.bootout_session_dashboard = lambda sid: None

fails = []
def check(cond, msg):
    if not cond:
        fails.append(msg)

# ① 기본 삭제 — 이미지+볼륨 회수, 용량 합산, 워크트리 폴더 제거
wt = src / ".claude/worktrees/wt-ok"
res = marina_lifecycle.remove_worktree(wt)
check(not wt.exists(), "wt-ok 폴더가 남아 있다")
check("removed" in (res.get("root") or {}), f"root 제거 결과 이상: {res.get('root')}")
rc = res.get("reclaim") or {}
check(rc.get("images") == ["sha256:webimg"], f"이미지가 안 지워졌다: {rc}")
check(sorted(rc.get("volumes") or []) == ["proj-wt-ok_node_modules", "proj-wt-ok_pgdata"], f"프로젝트 볼륨이 안 지워졌다: {rc}")
check(rc.get("freedMb") == 512 + 120 + 999, f"회수 용량 합산 오류: {rc}")
check(rc.get("errors") == [], f"에러가 없어야 한다: {rc}")
check(stopped and stopped[-1] == str(wt), "stop_all 이 먼저 불려야 한다(컨테이너가 이미지를 쥔 채면 rm 이 막힌다)")

# ② 회수 실패 — 이미지 rm 이 터져도 워크트리 삭제는 진행, 실패는 errors 에 남고 볼륨은 계속 회수
def boom(image_id):
    raise subprocess.CalledProcessError(1, ["docker", "image", "rm"], output="conflict: image is being used")
marina_lifecycle.docker_image_rm = boom
wt = src / ".claude/worktrees/wt-fail"
res = marina_lifecycle.remove_worktree(wt)
check(not wt.exists(), "회수 실패 때도 wt-fail 은 지워져야 한다")
rc = res.get("reclaim") or {}
check(rc.get("images") == [], f"실패한 이미지가 removed 로 잡혔다: {rc}")
check(len(rc.get("errors") or []) == 1 and "image" in rc["errors"][0], f"이미지 실패가 errors 에 안 남았다: {rc}")
check(rc.get("freedMb") == 120 + 999, f"볼륨만 회수돼야 한다: {rc}")

# ③ keep_images=True — docker 를 아예 안 건드린다
before = (calls["images_q"], calls["volumes_q"], len(calls["volume_rm"]))
wt = src / ".claude/worktrees/wt-keep"
res = marina_lifecycle.remove_worktree(wt, keep_images=True)
check(not wt.exists(), "wt-keep 이 안 지워졌다")
check("reclaim" not in res, f"keep_images 인데 reclaim 이 실렸다: {res.get('reclaim')}")
check((calls["images_q"], calls["volumes_q"], len(calls["volume_rm"])) == before, "keep_images 인데 docker 를 조회/삭제했다")

if fails:
    print("FAIL test-worktree-remove-reclaim"); [print("  -", f) for f in fails]; sys.exit(1)
print("PASS test-worktree-remove-reclaim")
PY
