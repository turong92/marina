#!/usr/bin/env bash
# 멤버 계정으로 채팅방을 쓰려면 **두 가지**가 필요하다 — 형: "내 계정 아니고 멤버 계정으로
# 넣어서 쓸건데 그것도 확인해봐".
#
# 권한 규칙(marina_access.can_root): 관리자면 전부 통과. 멤버는
#   ① 그 **프로젝트** 접근 권한이 있고
#   ② 그 **워크트리 자원의 주인**이어야 한다
# 하나만 있으면 방이 목록에서 아예 안 보인다. 자원에 주인이 없으면 can_resource 는 False 다
# (주인 없음 ≠ 모두 허용) — 그래서 새로 만든 채팅방의 기본값은 "멤버에겐 안 보임"이다.
# 이걸 모르면 형은 "배포했는데 폰에 방이 없다"를 또 겪는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
SH="$SCR/marina.sh"
ENTRY="$SCR/marina-entrypoint.sh"   # `marina user ...` 는 여기로 간다
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MARINA_HOME="$TMP/home"
CHAT="$TMP/chat"; mkdir -p "$CHAT"
bash "$SH" project add "$CHAT" --profile chat >/dev/null

PYTHONPATH="$SCR" python3 - "$CHAT" <<'PY'
import sys
from pathlib import Path

import marina_registry as reg
from marina_access import AccessPolicy, canonical_root
from marina_auth import AuthStore, SessionPrincipal
from marina_state import MARINA_HOME

chat = Path(sys.argv[1])
reg._projects_cache.clear()
store = AuthStore(MARINA_HOME / "auth.db")
관리자 = store.add_user("sumin", "수민", role="admin")
팀원 = store.add_user("teammate", "팀원", role="member")   # add_user 는 바로 쓸 수 있는 상태로 만든다
policy = AccessPolicy(store)
사람 = lambda u: SessionPrincipal(user=u, session_id=1, csrf_hash=b"x")

# ① 관리자는 그냥 보인다.
assert policy.can_root(사람(관리자), chat) is True

# ② 멤버는 아무것도 없으면 못 본다 — 여기서 "폰에 방이 없다"가 난다.
assert policy.can_root(사람(팀원), chat) is False, "권한 없는 멤버에게 방이 보인다"

# ③ 프로젝트 접근만 줘도 아직이다(자원 주인이 없다).
store.set_project_access(팀원.id, ["chat"], actor_user_id=관리자.id)
assert policy.can_root(사람(팀원), chat) is False, "프로젝트만으로 열리면 자원 권한이 무의미하다"

# ④ 자원 주인까지 줘야 열린다.
store.assign_resource_owner("worktree", canonical_root(chat), 팀원.id, actor_user_id=관리자.id)
assert policy.can_root(사람(팀원), chat) is True, "둘 다 줬는데도 안 보인다"
print("ok 멤버 권한: 프로젝트 + 자원 주인 둘 다 있어야 방이 보인다")
PY

# ⑤ 그 둘을 주는 **CLI 가 있어야** 한다. 없으면 형이 관리자 API 를 직접 두드려야 한다.
bash "$ENTRY" user grant teammate --project chat --root "$CHAT" >/dev/null
PYTHONPATH="$SCR" python3 - "$CHAT" <<'PY2'
import sys
from pathlib import Path

from marina_access import AccessPolicy, canonical_root
from marina_auth import AuthStore, SessionPrincipal
from marina_state import MARINA_HOME

store = AuthStore(MARINA_HOME / "auth.db")
팀원 = next(u for u in store.list_users() if u.username == "teammate")
policy = AccessPolicy(store)
사람 = SessionPrincipal(user=팀원, session_id=1, csrf_hash=b"x")
assert policy.can_root(사람, Path(sys.argv[1])) is True, "CLI 로 준 권한이 안 먹는다"
print("ok marina user grant 로 한 번에 준다")
PY2

echo "PASS test-member-chat-access"
