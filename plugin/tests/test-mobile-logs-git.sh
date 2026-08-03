#!/usr/bin/env bash
# 모바일 로그·깃 **읽기 전용** 표면. 모바일엔 둘 다 없어서 밖에서 "빌드 깨졌나"를 확인할 방법이
# 없었다. 서버 로직은 웹과 같은 함수를 그대로 쓴다(신규 0) — 여기서는 라우트가 붙었는지, 권한을
# 검사하는지, 그리고 **쓰기 계열이 새어 나가지 않았는지**를 잠근다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import re

import marina_handler as mh

src = open(mh.__file__, encoding="utf-8").read()

READ = ["/mobile/api/logs/chunk", "/mobile/api/logs/matches", "/mobile/api/git-graph",
        "/mobile/api/git-wip-stat", "/mobile/api/git-diff", "/mobile/api/git-commit-info"]
for path in READ:
    assert f'"{path}"' in src, f"라우트 없음: {path}"

# 쓰기 계열은 모바일 프리픽스에 없다. 읽기 전용이 이 표면의 계약이다.
WRITE = ["git-commit", "git-push", "git-merge", "git-rebase", "git-stash", "git-fetch",
         "git-pull", "logs/download", "logs"]
for op in WRITE:
    assert f'"/mobile/api/{op}"' not in src, f"쓰기/스트림 라우트가 모바일에 새어 나갔다: {op}"

# 각 읽기 라우트 블록이 인증과 root 접근을 검사한다
for path in READ:
    idx = src.index(f'"{path}"')
    block = src[idx: idx + 2000]
    assert "_agent_api_ok" in block, f"{path} 가 인증을 검사하지 않는다"
    assert "_require_root_access" in block, f"{path} 가 root 접근을 검사하지 않는다"

# git-diff 인자 조합은 웹/모바일이 한 헬퍼를 공유해야 한다 — 복붙하면 한쪽만 고쳐진다
assert "_git_diff_payload" in src, "git-diff 인자 조합이 공유 헬퍼로 모이지 않았다"
assert src.count("_git_diff_payload(") >= 3, "웹·모바일 양쪽이 같은 헬퍼를 쓰지 않는다"

print("PASS 라우트: 읽기 6종 + 인증/권한 검사 + 쓰기 부재 + git-diff 공유 헬퍼")
PY

# ---------- 실서버: 권한·페이로드 ----------
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
CTRL="$SCR/marina-control.py"
P="$(mktemp -d)"
trap 'kill %1 2>/dev/null || true; rm -rf "$P"' EXIT

git -C "$P" init -q
git -C "$P" config user.email t@t.test
git -C "$P" config user.name t
echo one > "$P/a.txt"
git -C "$P" add a.txt
git -C "$P" commit -qm "첫 커밋"
echo two >> "$P/a.txt"

python3 -c "
import json, os, pathlib
home = pathlib.Path(os.environ['MARINA_HOME']); home.mkdir(parents=True, exist_ok=True)
(home / 'projects.json').write_text(json.dumps({'projects': [{'id': 'p', 'root': '$P'}]}), encoding='utf-8')
"

MARINA_MOBILE_TOKEN=secret MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 \
  MARINA_HOME="$MARINA_HOME" python3 "$CTRL" > /dev/null 2>&1 &

b="http://127.0.0.1:$PORT"
ready=0
for _ in $(seq 1 100); do
  curl -sf -H 'X-Marina-Mobile-Token: secret' "$b/mobile/api/state" >/dev/null 2>&1 && { ready=1; break; }
  sleep 0.1
done
[[ "$ready" == "1" ]] || { echo "FAIL: test server did not become ready"; exit 1; }

# 토큰 없이는 403
for path in "git-wip-stat" "git-graph" "logs/chunk"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: devbox.example.test' "$b/mobile/api/$path?root=$P")"
  [[ "$code" == "403" ]] || { echo "FAIL: /mobile/api/$path without token should be 403, got $code"; exit 1; }
done

# 토큰이 있으면 실제 깃 상태를 준다
wip="$(curl -sf -H 'X-Marina-Mobile-Token: secret' "$b/mobile/api/git-wip-stat?root=$P")"
python3 - "$wip" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert "error" not in d, d
blob = json.dumps(d, ensure_ascii=False)
assert "a.txt" in blob, f"WIP 에 변경 파일이 없다: {blob[:300]}"
print("ok mobile git-wip-stat")
PY

graph="$(curl -sf -H 'X-Marina-Mobile-Token: secret' "$b/mobile/api/git-graph?root=$P")"
python3 - "$graph" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert "error" not in d, d
assert "첫 커밋" in json.dumps(d, ensure_ascii=False), "커밋 목록이 비었다"
print("ok mobile git-graph")
PY

diff="$(curl -sf -H 'X-Marina-Mobile-Token: secret' "$b/mobile/api/git-diff?root=$P&file=a.txt")"
python3 - "$diff" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert "error" not in d, d
assert "two" in json.dumps(d, ensure_ascii=False), "파일 diff 가 비었다"
print("ok mobile git-diff")
PY

# 등록되지 않은 root 는 거부 — 임의 경로를 읽는 통로가 되면 안 된다
code="$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Marina-Mobile-Token: secret' "$b/mobile/api/git-wip-stat?root=/etc")"
[[ "$code" != "200" ]] || { echo "FAIL: 등록 안 된 root 를 읽어줬다"; exit 1; }

echo "PASS test-mobile-logs-git"
