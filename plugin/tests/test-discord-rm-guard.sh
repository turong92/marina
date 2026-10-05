#!/usr/bin/env bash
# 변수 경로 rm 가드 — 우회 모드에서도 Claude Code 가 사람에게 묻는 창(형 2026-10-06 "자꾸 권한 묻는데")을 애초에 안 뜨게.
#  - PreToolUse(Bash) 훅이 실행되는 rm 의 인자에 맨 변수·명령 치환이 있으면 거부 + 고치는 법(${VAR:?}) → 에이전트가 스스로 다시 실행
#  - 서브에이전트 것도 PreToolUse 는 탄다(권한 훅 버튼은 안 온다) · 아무것도 자동 허용하지 않는다
#  - 글자로 담긴 rm(커밋 메시지·검색어·heredoc)과 다른 도구의 하위명령(git rm·docker rm)은 안 막는다 — 못 고치는 거부는 루프가 된다
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/session_fixture.sh"
start_fake_discord
fail() { echo "FAIL: $*"; exit 1; }
msess new proj feat/a --no-start >/dev/null 2>&1 || fail "new"

# 실제 훅 경로(stdin → main 분기 → stdout) — 분기가 깨지면 가드가 조용히 사라진다
out="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"rm -rf $A/x"}}' | msess hook-rm-guard)"
case "$out" in *'"permissionDecision": "deny"'*'${VAR:?}'*) ;; *) fail "CLI 거부 출력: $out" ;; esac
out="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' | msess hook-rm-guard)"
[ -z "$out" ] || fail "CLI 통과는 출력 없음: $out"
out="$(printf '%s' 'not json' | msess hook-rm-guard)" || fail "깨진 입력에도 0"
[ -z "$out" ] || fail "깨진 입력은 출력 없음: $out"

PYTHONPATH="$DSCRIPTS:$SCRIPTS" python3 - <<'PY'
import json, sys
from pathlib import Path
import marina_session as ms
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)
rec = ms.find_session("proj/feat/a")
st = json.loads((Path(rec["stateDir"]) / "settings.json").read_text())
check(any(e.get("matcher") == "Bash" and any("hook-rm-guard" in h["command"] for h in e["hooks"])
          for e in st["hooks"]["PreToolUse"]), "Bash PreToolUse 에 가드 등록")
def dec(cmd, tool="Bash"):
    out = ms.hook_rm_guard({"tool_name": tool, "tool_input": {"command": cmd}}) or {}
    return out.get("hookSpecificOutput", {})
BS = chr(92)
DENY = [
    "G=a/b && rm -rf $G && ls", 'rm -fr "$S/raw"', "cd x; rm -R ${OUT}/tmp", "rm --recursive $A", "sudo rm -rf -- $A",
    "rm -f $G/*portrait*", "rm $A -rf", "rm -rf " + BS + "\n  $A/x", "rm -rf ${A%/}/x", "rm -rf ${A:-}/x", "rm -rf ${A?}/x",
    'rm -rf "$@"', 'rm -rf "$(cat f)/x"', "rm -rf `cat f`/x", "if x; then y; else rm -rf $A; fi", "{ rm -rf $A; }",
    "command rm -rf $A", BS + "rm -rf $A", "/bin/rm -rf $A", "X=1 rm -rf $A", "sudo -n rm -rf $A", "sudo /bin/rm -rf $A",
    "find . -name x -exec rm -rf $A/{} " + BS + ";", "ls | xargs -I{} rm -rf $A/{}", "bash -c 'rm -rf $A'",
    "rm -rf $(ls | head -1) $A", "rm -rf 'a;b' $A", "rm -rf /tmp/x 2>&1 $A", "echo hi\nrm -rf $A",
    "for f in a b; do rm \"$f\"; done", "trap 'rm -rf \"$tmp\"' EXIT", 'tmp=$(mktemp -d); rm -rf "$tmp"',
    'rm -rf "${files[@]}"', "f() { rm -rf $A; }", "case x in a) rm -rf $A;; esac",
]
for cmd in DENY:
    d = dec(cmd)
    why = d.get("permissionDecisionReason", "")
    check(d.get("permissionDecision") == "deny" and "${VAR:?}" in why and "Write" in why and "for f in" in why,
          f"거부 + 고치는 법: {cmd!r} → {d}")
ALLOW = [
    # 안내대로 고친 것은 통과해야 한다 — 안 그러면 루프
    'rm -rf "${G:?}/raw"', 'rm -f "${G:?}"/*portrait*', 'rm -rf "${G:?빈 값}/x"', 'for f in a b; do rm "${f:?}"; done',
    "trap 'rm -rf \"${tmp:?}\"' EXIT", 'tmp=$(mktemp -d); rm -rf "${tmp:?}"', 'rm -rf "${files[@]:?}"', 'rm -rf "${1:?}"',
    # 변수 없는 rm · rm 뒤 다른 명령의 변수
    "rm -rf /tmp/fixed/dir", "echo $HOME; rm -r build", 'S=/a; rm -rf "${G:?}" && node $S/x.mjs $G', "rm -rf build; echo $A",
    "rm -f x || echo $A", "rm -rf build & echo $A", "rm -rf build # $A", "rm -rf " + BS + "$literal",
    "find . -name '*.tmp' -exec rm {} +", 'find "$D" -name x -exec rm -f {} ' + BS + ";",
    # 다른 도구의 하위명령 · rm 이 낀 이름
    "git rm --cached $FILE", 'git rm -r "$dir"', "docker rm -f $CID", "docker rm -f $(docker ps -aq)", "docker compose rm -f $SVC",
    "docker image rm $IMG", "npm rm $pkg", "docker run --rm -v $PWD:/w img", "npm run rm-cache -- $A", "ls bin/rm $A",
    # 실행이 아니라 글자로 담긴 rm
    "ls $A | grep rm", "grep rm $FILE", "grep -n \"rm \" f | awk '{print $1}'", 'echo "about to rm stuff" && echo $HOME',
    'git commit -m "chore: rm old cache" && git push origin $BRANCH', "sed -n '/rm /p' f; echo $x",
    'gh pr create --body "removes via rm ${X}"', "grep -rn 'the rm -rf $O case' docs",
    "git commit -m \"$(cat <<'EOF'\nfix: guard\n\nrm -rf $O/raw 같은 명령을 막는다\nEOF\n)\"",
    "python3 - <<'PY'\nx = 'rm -rf $A'\nprint(x)\nPY", "node - <<'EOF'\nrun(`rm -rf ${dir}`)\nEOF\necho $A",
    "sed -i 's/a/b/' /tmp/x.sh", "git status",
]
for cmd in ALLOW:
    check(dec(cmd) == {}, f"안 건드림(결정 없음): {cmd!r} → {dec(cmd)}")
check(dec("rm -rf $A", tool="Write") == {}, "Bash 만 본다")
check(ms.hook_rm_guard({"tool_name": "Bash", "tool_input": None}) is None, "입력이 이상해도 안 죽는다")
if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-discord-rm-guard"
