#!/usr/bin/env bash
# ref 고정 체크아웃 — 실제 git 저장소를 임시로 만들어 확인한다 (도커 불필요).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../scripts"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 테스트용 git 저장소: 커밋 2개 + 태그
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q .
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
echo one > "$REPO/f.txt"; git -C "$REPO" add .; git -C "$REPO" commit -qm one
git -C "$REPO" tag v1
echo two > "$REPO/f.txt"; git -C "$REPO" add .; git -C "$REPO" commit -qm two

python3 - "$SCRIPTS" "$REPO" <<'PY'
import sys, pathlib, shutil
sys.path.insert(0, sys.argv[1])
import marina_live as L

repo = sys.argv[2]

# 1) v1 로 고정하면 그 시점 내용이 나온다
src = L.sync_src(repo, "p", "v1")
assert src == L.live_src("p"), src
assert (src / "f.txt").read_text().strip() == "one", (src / "f.txt").read_text()

# 2) 멱등 — 같은 ref 로 다시 불러도 성공한다
src = L.sync_src(repo, "p", "v1")
assert (src / "f.txt").read_text().strip() == "one"

# 3) ref 를 바꾸면 내용이 따라온다
src = L.sync_src(repo, "p", "HEAD")
assert (src / "f.txt").read_text().strip() == "two"

# 4) 사람이 고친 것은 다음 기동에 사라진다 (하드 리셋) — 운영 코드를 손으로 고치는 길을
#    열어 두지 않는다. 막지는 못하므로 조용히 남지 않게 한다.
(src / "f.txt").write_text("hand-edited\n")
(src / "junk.txt").write_text("x\n")
src = L.sync_src(repo, "p", "HEAD")
assert (src / "f.txt").read_text().strip() == "two", "손으로 고친 것이 남았다"
assert not (src / "junk.txt").exists(), "untracked 쓰레기가 남았다"

# 5) 없는 ref 는 에러를 내고 **기존 체크아웃을 지우지 않는다** — force-push 로 ref 가
#    사라졌을 때 돌고 있는 서비스의 소스를 날리면 안 된다.
try:
    L.sync_src(repo, "p", "no-such-ref")
    raise AssertionError("없는 ref 인데 통과했다")
except L.LiveConfigError as e:
    assert "no-such-ref" in str(e), e
assert (L.live_src("p") / "f.txt").read_text().strip() == "two", "실패가 기존 체크아웃을 망쳤다"

# 6) git 레포가 아닌 경로는 거부한다
try:
    L.sync_src(str(pathlib.Path(sys.argv[2]).parent / "nope"), "q", "HEAD")
    raise AssertionError("없는 레포인데 통과했다")
except L.LiveConfigError:
    pass

# 7) src 를 손으로 지워 레포에 stale worktree 등록만 남아도 되살아난다
shutil.rmtree(L.live_src("p"))
src = L.sync_src(repo, "p", "v1")
assert (src / "f.txt").read_text().strip() == "one", "stale 등록 때문에 되살리지 못했다"

# 8) 잠금 — 같은 프로젝트를 두 번 동시에 잡을 수 없다
with L.src_lock("p"):
    try:
        with L.src_lock("p"):
            raise AssertionError("두 번째 잠금이 통과했다")
    except L.LiveConfigError as e:
        assert "이미" in str(e), e
# 잠금은 풀린다 (finally)
with L.src_lock("p"):
    pass
print("ok")
PY
echo "PASS test-live-checkout"
