#!/usr/bin/env bash
# 대시보드 유휴 정리 API — GET /api/worktree-gc(계획, 쓰기 0) · POST /api/worktree-gc(선택 삭제) ·
# /api/worktrees 카드에 유휴 배지 필드(gcIdle/gcIdleDays). 핸들러를 프로세스 안에서 띄우고
# docker·정지는 가짜로, git 은 진짜로 확인한다(백업 브랜치가 실제로 남는지).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

OLD="$(date -v-30d '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d '30 days ago' '+%Y-%m-%dT%H:%M:%S')"
export GIT_AUTHOR_DATE="$OLD" GIT_COMMITTER_DATE="$OLD"
gi() { mkdir -p "$1"; git -C "$1" init -q -b main; git -C "$1" config user.email t@t.invalid; git -C "$1" config user.name T; echo ok>"$1/r"; git -C "$1" add r; git -C "$1" commit -qm i; }
SRC="$TMP/proj"; gi "$SRC"
git init -q --bare "$TMP/remote-sub.git"
gi "$SRC/sub"; git -C "$SRC/sub" remote add origin "$TMP/remote-sub.git"; git -C "$SRC/sub" push -q -u origin main
mkdir -p "$SRC/.claude/worktrees"
mkwt() {
  git -C "$SRC" worktree add -q --detach "$SRC/.claude/worktrees/$1" HEAD
  git -C "$SRC/sub" worktree add -q -b "codex/$1" "$SRC/.claude/worktrees/$1/sub" main
}
mkwt wt-idle; mkwt wt-untracked; mkwt wt-active
echo unpushed > "$SRC/.claude/worktrees/wt-idle/sub/u.txt"; git -C "$SRC/.claude/worktrees/wt-idle/sub" add u.txt; git -C "$SRC/.claude/worktrees/wt-idle/sub" commit -qm unpushed
echo notes > "$SRC/.claude/worktrees/wt-untracked/notes.txt"
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
echo now > "$SRC/.claude/worktrees/wt-active/n.txt"; git -C "$SRC/.claude/worktrees/wt-active" add n.txt; git -C "$SRC/.claude/worktrees/wt-active" commit -qm recent
find "$SRC/.claude/worktrees" -path '*/wt-active' -prune -o -print0 | xargs -0 touch -t "$(date -v-30d '+%Y%m%d%H%M' 2>/dev/null || date -d '30 days ago' '+%Y%m%d%H%M')"

cat > "$MARINA_HOME/projects.json" <<JSON
{"projects":[{"id":"proj","root":"$SRC","subrepos":["sub"],"worktreeGlobs":[".claude/worktrees/*"],"kind":"compose","composeFile":"docker-compose.yml"}]}
JSON
mkdir -p "$MARINA_HOME/proj"; printf 'services:\n  web:\n    build: .\n' > "$MARINA_HOME/proj/docker-compose.yml"

PYTHONPATH="$SCR" python3 - "$SRC" <<'PY'
import http.client
import json
import os
import subprocess
import sys
import threading
import urllib.parse
from http.server import ThreadingHTTPServer
from pathlib import Path

src = Path(sys.argv[1])
os.environ["MARINA_CONTROL_HOST"] = "127.0.0.1"
import marina_cache
import marina_handler
import marina_lifecycle
import marina_sessions

# du·docker·정지는 가짜 — 이 테스트는 API 표면과 git 결과만 본다
marina_sessions._du_info = lambda root, is_main, refresh: (100, {}, 300, {})
_real = subprocess.check_output
def fake_check_output(args, **kw):
    text = " ".join(str(a) for a in args)
    if not args or (str(args[0]) != "docker" and not str(args[0]).endswith("/docker")):
        return _real(args, **kw)
    if "images --format json web" in text:
        return json.dumps([{"Service": "web", "ID": "sha256:img", "Repository": "proj-web", "Tag": "latest", "Size": "300MB"}])
    if "volume ls -q" in text:
        return ""
    raise AssertionError(f"unexpected docker command: {text}")
marina_cache.subprocess.check_output = fake_check_output
removed_images = []
marina_lifecycle.docker_image_rm = lambda image_id: removed_images.append(image_id) or True
marina_lifecycle.stop_all = lambda root: {"stoppedAll": True}
marina_lifecycle.cleanup_session = lambda root: {"removed": ""}
marina_lifecycle.bootout_session_dashboard = lambda sid: None

server = ThreadingHTTPServer(("127.0.0.1", 0), marina_handler.Handler)
marina_sessions.PORT = server.server_address[1]
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]

def call(method, path, body=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    headers = {"Host": f"127.0.0.1:{port}", "Origin": f"http://127.0.0.1:{port}", "Content-Type": "application/json"}
    conn.request(method, path, json.dumps(body) if body is not None else None, headers=headers)
    res = conn.getresponse(); payload = json.loads(res.read()); conn.close()
    return res.status, payload

fails = []
def check(cond, msg):
    if not cond:
        fails.append(msg)
W = lambda n: str(src / ".claude/worktrees" / n)

# ① 카드 payload — 유휴 워크트리에만 gcIdle, main 엔 없음
status, payload = call("GET", "/api/worktrees?refresh=1")
check(status == 200, f"/api/worktrees {status}")
cards = {c["id"]: c for c in payload["worktrees"]}
check(cards["wt-idle"].get("gcIdle") is True and cards["wt-idle"]["gcIdleDays"] > 14, f"wt-idle 카드에 유휴 필드 없음: {cards['wt-idle'].get('gcIdle')}")
check(cards["wt-active"].get("gcIdle") is False, f"wt-active 가 유휴로 표시됨: {cards['wt-active'].get('gcIdle')}")
check("gcIdle" not in cards["main"], "main 카드에 gc 필드가 붙었다")

# ② 계획(GET) — 쓰기 0, 부적격 사유 포함
status, plan = call("GET", "/api/worktree-gc?days=14&refresh=1")
check(status == 200 and plan["days"] == 14, f"plan {status} {plan.get('days')}")
items = {i["id"]: i for i in plan["items"]}
check(set(items) == {"wt-idle", "wt-untracked"}, f"계획 목록: {sorted(items)}")
check(items["wt-idle"]["eligible"] and items["wt-idle"]["backups"] and not items["wt-idle"]["backups"][0]["created"], f"wt-idle 계획: {items['wt-idle']}")
check(not items["wt-untracked"]["eligible"] and any("notes.txt" in r for r in items["wt-untracked"]["reasons"]), f"wt-untracked 사유: {items['wt-untracked']}")
check(not subprocess.run(["git", "-C", str(src / "sub"), "branch", "--list", "backup/*"], capture_output=True, text=True).stdout.strip(), "GET 계획이 브랜치를 만들었다")
status, plan90 = call("GET", "/api/worktree-gc?days=90")
check(status == 200 and plan90["items"] == [], f"days=90 이면 비어야: {plan90}")

# ③ 잘못된 요청
status, err = call("POST", "/api/worktree-gc", {"roots": []})
check(status == 400, f"빈 roots 는 400 이어야: {status}")
status, err = call("POST", "/api/worktree-gc", {"roots": ["/nope"]})
check(status == 400, f"미등록 root 는 400 이어야: {status}")

# ④ 선택 삭제(POST) — 적격은 가드 적용 후 삭제+이미지 회수, 부적격·활성은 건너뜀(사유), 나머지는 계속
sub_head = subprocess.run(["git", "-C", W("wt-idle") + "/sub", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
status, res = call("POST", "/api/worktree-gc", {"roots": [W("wt-untracked"), W("wt-idle"), W("wt-active")], "days": 14})
check(status == 200, f"POST {status} {res}")
by = {r["id"]: r for r in res["results"]}
check(by["wt-idle"]["removed"] is True, f"wt-idle 삭제 실패: {by['wt-idle']}")
check(by["wt-idle"]["freedMb"] == 300 + 100, f"회수 용량(이미지 300 + 디스크 100): {by['wt-idle']}")
check(removed_images == ["sha256:img"], f"이미지 회수 안 됨: {removed_images}")
check(not Path(W("wt-idle")).exists(), "wt-idle 폴더가 남았다")
check(by["wt-untracked"]["removed"] is False and "untracked" in by["wt-untracked"]["reason"], f"부적격이 지워졌다: {by['wt-untracked']}")
check(Path(W("wt-untracked")).exists(), "wt-untracked 폴더가 지워졌다")
check(by["wt-active"]["removed"] is False and "유휴가 아님" in by["wt-active"]["reason"], f"활성이 지워졌다: {by['wt-active']}")
check(res["freedMb"] == 400, f"합계: {res['freedMb']}")
backup = subprocess.run(["git", "-C", str(src / "sub"), "rev-parse", "backup/worktree-wt-idle-" + __import__("time").strftime("%Y%m%d")],
                        capture_output=True, text=True).stdout.strip()
check(backup == sub_head, f"삭제 전 서브레포 미푸시 커밋이 메인 클론 backup 브랜치에 보존되지 않았다: {backup!r} vs {sub_head!r}")
# 미머지 codex/<id> 브랜치는 -d 가 거부해 남는다(기존 규칙)
branches = subprocess.run(["git", "-C", str(src / "sub"), "branch", "--list", "codex/wt-idle"], capture_output=True, text=True).stdout
check("codex/wt-idle" in branches, "미머지 서브레포 브랜치가 사라졌다")

# ⑤ 삭제 후 카드 목록에서 빠진다
status, payload = call("GET", "/api/worktrees?refresh=1")
check("wt-idle" not in {c["id"] for c in payload["worktrees"]}, "삭제된 워크트리가 목록에 남았다")

server.shutdown()
if fails:
    print("FAIL test-worktree-gc-api"); [print("  -", f) for f in fails]; sys.exit(1)
print("PASS test-worktree-gc-api")
PY
