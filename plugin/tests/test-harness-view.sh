#!/usr/bin/env bash
# "이 대화가 어떤 하네스로 떴나" — 마리나가 세션에 무엇을 넣는지 보이게 한다.
#
# **왜.** 마리나는 이미 하네스 노릇을 절반 하고 있다: SessionStart 훅이 문맥을 넣고, PreToolUse
# 훅들이 Bash·보호파일·appdata 를 막고, 플러그인이 스킬·커맨드를 싣고, profile/lean 이 CLI
# 플래그를 붙인다. 그런데 그게 전부 안 보이는 데서 일어나서, 프로젝트마다 다르게 주자는
# 얘기를 할 때 형도 나도 "지금 뭘 주고 있는지"를 못 댔다(2026-09-10).
#
# 계약: ① 띄울 때 쓴 argv 를 남긴다 ② **거기에 프롬프트가 들어가면 안 된다** ③ 옛 메타 파일도
# 그대로 읽힌다(없는 필드는 '모름'이지 기본값이 아니다) ④ 뜰 때 값 ≠ 지금 값이면 화면이
# 말한다 ⑤ 마리나가 안 띄운 세션은 '알 수 없음'이라고 말한다 ⑥ 지시문은 플래그 목록과 따로 뺀다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - "$SCR" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
import marina_term as T                                   # noqa: E402
import marina_mobile as M                                 # noqa: E402

비밀 = "형이 보낸 말 — 절대 설정 화면에 남으면 안 된다"

# ② **프롬프트는 저장본에 절대 없다.** 실행용 argv 는 프롬프트를 싣지만, 남기는 것은 빈
# 프롬프트로 다시 만든 것이라 꼬리를 자르는 실수가 원천적으로 불가능하다.
실행 = T._agent_cli("claude", "", 비밀, "claude-opus-5", "high", "chat", False)
저장 = T._agent_cli("claude", "", "", "claude-opus-5", "high", "chat", False)
assert 비밀 in 실행, "실행 argv 에 프롬프트가 없다 — 첫 메시지가 안 실린다"
assert 비밀 not in 저장, "저장할 argv 에 프롬프트가 들어갔다 — 형이 보낸 말이 화면에 샌다"
assert 저장 == [x for x in 실행 if x != 비밀], "프롬프트 말고 다른 게 달라졌다"

# ① 저장본에 하네스가 실제로 들어 있다.
for 조각 in ("--disallowedTools", "Artifact", "--append-system-prompt", "--model", "--effort"):
    assert 조각 in 저장, f"저장본에 {조각} 이 없다"

# ⑥ 지시문은 플래그 목록에서 빠져 따로 나온다 — 문단이라 섞으면 나머지가 안 보인다.
플래그, 지시문 = M._harness_flags(저장)
assert 지시문 and "파일" in 지시문, f"지시문이 안 빠져나왔다: {지시문!r}"
이름들 = [f["flag"] for f in 플래그]
assert 이름들 == ["--disallowedTools", "--append-system-prompt", "--model", "--effort"], 이름들
assert not any(f["value"] == 지시문 for f in 플래그), "지시문이 플래그 값으로도 중복돼 있다"
assert dict(zip(이름들, [f["value"] for f in 플래그]))["--model"] == "claude-opus-5"
# 엔진 이름(argv[0])은 플래그가 아니다.
assert "claude" not in 이름들

# lean 이 켜지면 도구 제한이 보인다.
가볍게 = M._harness_flags(T._agent_cli("claude", "", "", "", "", "", True))[0]
값 = {f["flag"]: f["value"] for f in 가볍게}
assert 값.get("--tools") == "Read Write", 값
assert "--strict-mcp-config" in 값

# 플래그마다 사람이 읽을 라벨이 붙는다 — 폰에서 `--disallowedTools` 만 봐선 모른다.
assert all(f["label"] for f in 가볍게), 가볍게

# 훅·스킬은 실제 플러그인 파일에서 읽는다(지어내지 않는다).
훅 = M._harness_hooks()
assert 훅, "훅을 하나도 못 읽었다"
assert {h["event"] for h in 훅} >= {"SessionStart", "PreToolUse"}, {h["event"] for h in 훅}
assert all(h["script"].endswith(".sh") for h in 훅), 훅
assert "/" not in 훅[0]["script"], "경로가 통째로 들어갔다 — 폰 화면엔 이름이면 된다"
묶음 = M._harness_bundled()
assert "dev-server" in 묶음["skills"], 묶음
assert "project" in 묶음["commands"], 묶음

print("ok 저장·해석: 프롬프트는 안 새고 하네스는 다 보인다")
PY

# ③④⑤ 화면 — 렌더러만 vm 에 싣고 데이터로 흔든다.
python3 - "$SCR" <<'PY' | node
import json
import sys
from pathlib import Path

src = (Path(sys.argv[1]) / "marina_mobile.py").read_text(encoding="utf-8")
start, end = src.find("// HARNESS_VIEW_START"), src.find("// HARNESS_VIEW_END")
if start < 0 or end < 0:
    raise SystemExit("HARNESS_VIEW_START/END 경계가 없다")
helpers = (Path(sys.argv[1]) / "marina-web" / "chat-render.js").read_text(encoding="utf-8")
esc = helpers[helpers.find("// ESC_HELPERS_START"):helpers.find("// ESC_HELPERS_END")]
print("const src = " + json.dumps(esc + src[start:end]) + ";")
print(r'''
const vm = require("node:vm");
const assert = require("node:assert/strict");
const context = {};
vm.createContext(context);
vm.runInContext(`${src}
this.renderHarness = renderHarness;`, context, {filename: "marina_mobile::harness"});
const {renderHarness} = context;

const 훅 = [{event: "PreToolUse", script: "marina-pretooluse-hook.sh", matcher: "Bash"}];
const 묶음 = {skills: ["dev-server"], commands: ["project"]};

// ⑤ 마리나가 안 띄운 세션 — **모르면 모른다고 한다.** 지금 설정으로 메우면 안 뜬 값을 뜬
// 것처럼 말하게 된다.
const 입양 = renderHarness({launched: false, engine: "claude", hooks: 훅, bundled: 묶음});
assert.match(입양, /알 수 없어요/, "안 띄운 세션인데 아는 척한다");
assert.ok(!입양.includes("붙은 플래그"), "없는 플래그 목록을 그렸다");
// 훅·스킬은 입양 세션에도 걸려 있으므로 그대로 보여준다.
assert.match(입양, /marina-pretooluse-hook\.sh/);
assert.match(입양, /dev-server/);

// ④ 뜰 때 값 ≠ 지금 값이면 **다시 띄워야 한다**고 말한다. 하네스는 뜰 때 정해지고 도는
// 세션엔 안 붙는다 — 이걸 안 말하면 형은 설정을 바꾸고 왜 안 먹는지 모른 채로 있는다.
const 어긋남 = renderHarness({
  launched: true, engine: "claude", model: "claude-opus-5", effort: "high",
  flags: [{flag: "--tools", value: "Read Write", label: "이 도구만 쓴다"}],
  atLaunch: {profile: "", lean: false}, now: {profile: "chat", lean: true}, stale: true,
  hooks: 훅, bundled: 묶음,
});
assert.match(어긋남, /다시 시작해야/, "설정이 어긋났는데 안 알려준다");
assert.match(어긋남, /지금 프로젝트 설정과 달라요/);

// 안 어긋났으면 경고를 띄우지 않는다 — 늘 뜨는 경고는 아무도 안 읽는다.
const 같음 = renderHarness({
  launched: true, engine: "claude", flags: [], atLaunch: {profile: "chat", lean: false},
  now: {profile: "chat", lean: false}, stale: false, hooks: 훅, bundled: 묶음,
});
assert.ok(!같음.includes("다시 시작해야"), "멀쩡한데 경고가 떴다");
// 모델·effort 를 안 줬으면 빈칸이 아니라 "CLI 기본값"이라고 말한다.
assert.match(같음, /CLI 기본값/);

// 지시문은 접힌 상자로 따로 나온다.
const 지시 = renderHarness({launched: true, engine: "claude", flags: [],
  systemPrompt: "결과물은 파일로 만들어 건네줘.", atLaunch: {}, now: {}, hooks: [], bundled: {}});
assert.match(지시, /class="hPrompt"/);
assert.match(지시, /결과물은 파일로/);

// **남의 글자는 마크업이 되면 안 된다** — 지시문·플래그 값은 서버가 파일에서 읽어온 것이다.
const 주입 = renderHarness({launched: true, engine: "claude",
  flags: [{flag: "--x", value: "<img src=x onerror=alert(1)>", label: ""}],
  systemPrompt: "<script>alert(2)</scr" + "ipt>", atLaunch: {}, now: {}, hooks: [], bundled: {}});
assert.ok(!주입.includes("<img"), "플래그 값이 마크업이 됐다");
assert.ok(!주입.includes("<script"), "지시문이 마크업이 됐다");

console.log("ok");
''')
PY

# 3 저장/복원 왕복 — 그리고 **옛 메타 파일**(이 필드들이 없던 시절)도 그대로 읽혀야 한다.
# 없는 필드를 지금 설정으로 메우면 안 뜬 값을 뜬 것처럼 보여주게 된다: 빈 값 = 모름이다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'ROUNDTRIP'
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
import marina_term as T                                   # noqa: E402

terms = T._terms_dir()
terms.mkdir(parents=True, exist_ok=True)
살아있는pid = os.getpid()          # 이 프로세스를 빌려 살아있는 term 을 흉내낸다
지문 = T._pid_start(살아있는pid)

def 복원(meta):
    for f in terms.glob("*.json"):
        f.unlink()
    (terms / f"{meta['tid']}.json").write_text(json.dumps(meta), encoding="utf-8")
    T._by_tid.clear()
    T._by_key.clear()
    T._reconstructed = False
    T._reconstruct_registry()
    return T._by_tid.get(meta["tid"])

새것 = 복원({"tid": "t-new", "cwd": os.getcwd(), "pid": 살아있는pid, "pid_start": 지문,
             "source": "claude", "sid": "s1", "prompted": True, "key": "",
             "launch": ["claude", "--tools", "Read", "Write"], "model": "claude-opus-5",
             "effort": "high", "profile": "chat", "lean": True, "created": 1.0})
assert 새것 is not None, "새 메타를 복원 못 했다"
agent = 새것.agent or {}
assert agent.get("launch") == ["claude", "--tools", "Read", "Write"], agent
assert agent.get("model") == "claude-opus-5" and agent.get("effort") == "high", agent
assert agent.get("profile") == "chat" and agent.get("lean") is True, agent

옛것 = 복원({"tid": "t-old", "cwd": os.getcwd(), "pid": 살아있는pid, "pid_start": 지문,
             "source": "claude", "sid": "s2", "prompted": False, "key": "", "created": 1.0})
assert 옛것 is not None, "옛 메타 파일이 복원되지 않는다 — 배포 한 번에 도는 세션을 다 잃는다"
옛agent = 옛것.agent or {}
assert "launch" not in 옛agent, f"없던 필드를 지어냈다: {옛agent}"
for 칸 in ("model", "effort", "profile", "lean"):
    assert 칸 not in 옛agent, f"{칸} 을 지어냈다: {옛agent}"
print("ok 왕복: 새 메타는 다 실리고, 옛 메타는 모른다고 남는다")
ROUNDTRIP

# 2-b **진짜 term_open 을 태워서** 디스크에 남는 것을 본다. 위의 단위 검사는 _agent_cli 만
# 보므로, term_open 이 실행용 argv 를 그대로 저장하도록 바뀌면 못 잡는다(실제로 변이로
# 확인했다 — 통과해버렸다). 여기선 디스크에 적힌 것을 직접 읽는다.
#
# 에이전트를 진짜로 띄우지는 않는다: SHELL 을 잠만 자는 껍데기로 바꾸면 자식은 그걸 exec 하고,
# 메타를 적는 것은 부모라 저장 경로는 그대로 탄다.
PYTHONPATH="$SCR" python3 - "$SCR" <<'REALOPEN'
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
import marina_term as T                                   # noqa: E402

비밀 = "형이 보낸 말 — 절대 설정 화면에 남으면 안 된다"
home = Path(os.environ["MARINA_HOME"])
가짜셸 = home / "fake-shell"
가짜셸.write_text("#!/bin/sh\nexec sleep 5\n", encoding="utf-8")
가짜셸.chmod(0o755)
os.environ["SHELL"] = str(가짜셸)

result = T.term_open(Path(os.getcwd()), 80, 24, agent_source="claude", agent_sid="",
                     agent_prompt=비밀, agent_model="claude-opus-5", agent_effort="high")
tid = str(result.get("tid") or "")
assert tid, result
try:
    meta = json.loads((T._terms_dir() / f"{tid}.json").read_text(encoding="utf-8"))
finally:
    T.term_kill(tid)

adrift = json.dumps(meta, ensure_ascii=False)
assert 비밀 not in adrift, f"디스크에 적힌 메타에 형이 보낸 말이 들어갔다: {adrift}"
assert meta.get("launch"), f"띄울 때 쓴 것이 안 남았다: {meta}"
assert "--model" in meta["launch"] and "claude-opus-5" in meta["launch"], meta["launch"]
assert meta.get("model") == "claude-opus-5" and meta.get("effort") == "high", meta
print("ok 실기동: 디스크에 남은 하네스에 프롬프트가 없다")
REALOPEN

echo "PASS: 하네스가 화면에 보이고, 프롬프트는 안 샌다"
