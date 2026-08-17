#!/usr/bin/env bash
# 모바일 응답의 **모든 목록**이 권한 필터를 탄다.
#
# 왜 이 테스트가 있나: 방(rooms)을 응답에 더하면서 _filter_mobile 을 같이 안 고쳤다. 화면엔
# 안 보였지만 응답 JSON 에는 남의 워크트리 경로·별칭·세션 제목이 통째로 실려 나갔다.
# 그래서 "rooms 를 걸렀나"가 아니라 **root 를 가진 목록 키가 하나라도 안 걸러지면 실패**로
# 잠근다 — 다음에 키를 더할 때도 같은 실수를 잡는다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import marina_handler as mh

MINE, THEIRS = "/wt/mine", "/wt/theirs"


class 정책:
    def can_root(self, principal, root):
        return str(root) == MINE

    def inherit_from_root(self, kind, key, root):
        pass

    def can_resource(self, principal, kind, key):
        return "숨김세션" not in str(key)


class 사용자:
    role = "member"


class 주체:
    user = 사용자()


class 가짜핸들러:
    auth_principal = 주체()

    def _policy(self):
        return 정책()

    def _term_allowed(self, item):
        return str(item.get("root") or "") == MINE

    _filter_mobile = mh.Handler._filter_mobile


payload = {
    "worktrees": [{"root": MINE, "alias": "내방"}, {"root": THEIRS, "alias": "남의방"}],
    "terms": [{"tid": "t1", "root": MINE}, {"tid": "t2", "root": THEIRS}],
    "sessions": [
        {"kind": "agent", "root": MINE, "source": "claude", "sid": "s1"},
        {"kind": "agent", "root": THEIRS, "source": "claude", "sid": "s2"},
    ],
    "rooms": [
        {"root": MINE, "name": "내방", "tabs": [{"source": "claude", "sid": "s1"},
                                                 {"source": "claude", "sid": "숨김세션"}]},
        {"root": THEIRS, "name": "남의방", "tabs": [{"source": "claude", "sid": "s2"}]},
    ],
}

out = 가짜핸들러()._filter_mobile(payload)

# ① root 를 가진 목록은 **전부** 남의 것을 떨궈야 한다 — 키 이름을 미리 알 필요 없이.
for key, value in out.items():
    if not isinstance(value, list):
        continue
    남은것 = [item for item in value
              if isinstance(item, dict) and str(item.get("root") or "") == THEIRS]
    assert not 남은것, f"'{key}' 가 필터를 안 탔다 — 남의 워크트리가 응답에 실린다: {남은것}"

# ② 내 것은 남는다(과잉 차단이면 형 화면이 빈다).
assert [r["name"] for r in out["rooms"]] == ["내방"], out["rooms"]
assert len(out["worktrees"]) == 1 and len(out["sessions"]) == 1

# ③ 방 안의 탭도 세션과 같은 자원 검사를 탄다 — 방만 통과시키고 탭을 안 보면 제목이 샌다.
assert [t["sid"] for t in out["rooms"][0]["tabs"]] == ["s1"], out["rooms"][0]["tabs"]

# ③-b 탭을 걸렀으면 **방 상태·시각도 다시 계산한다.** 안 그러면 "문제라는데 문제인 탭이
# 없는" 방이 나온다 — 볼 수 없는 세션이 만든 상태가 남아 화면이 설명 불가능해진다.
가려진방 = {"root": MINE, "name": "내방", "status": "문제", "lastAt": 999, "tabs": [
    {"source": "claude", "sid": "s1", "status": "대기", "ts": 100},
    {"source": "claude", "sid": "숨김세션", "status": "문제", "ts": 999},
]}
정리됨 = 가짜핸들러()._filter_mobile({"worktrees": [{"root": MINE}], "rooms": [가려진방]})["rooms"][0]
assert [t["sid"] for t in 정리됨["tabs"]] == ["s1"], 정리됨["tabs"]
assert 정리됨["status"] == "대기", f"볼 수 있는 탭엔 없는 상태가 남았다: {정리됨['status']}"
assert 정리됨["lastAt"] == 100, f"걸러진 탭의 활동 시각이 남았다: {정리됨['lastAt']}"

# ④ admin 은 그대로 다 본다(어드민이 웹에서 전부 봐야 한다 — 스펙의 역할 구분).
class 관리자(사용자):
    role = "admin"


class 관리주체:
    user = 관리자()


class 관리핸들러(가짜핸들러):
    auth_principal = 관리주체()


everything = 관리핸들러()._filter_mobile({"rooms": [{"root": THEIRS, "tabs": []}]})
assert len(everything["rooms"]) == 1, everything

print("ok 모바일 응답의 모든 목록이 권한 필터를 탄다")
PY

echo "PASS test-mobile-filter"
