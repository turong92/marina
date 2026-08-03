#!/usr/bin/env bash
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
JS="$SCR/marina-web/chat-render.js"

[ -f "$JS" ] || { echo "FAIL: chat-render.js 없음"; exit 1; }

PYTHONPATH="$SCR" python3 - "$JS" "$SCR/marina_mobile.py" <<'PY'
import re
import sys

js = open(sys.argv[1], encoding="utf-8").read()
mob = open(sys.argv[2], encoding="utf-8").read()
html = mob[mob.index('_MOBILE_HTML = r"""'):]

# 1) 네임스페이스 하나로만 노출한다 — 전역 오염 금지
assert "window.MarinaChat" in js, "MarinaChat 네임스페이스가 없다"
assert js.lstrip().startswith("//"), "파일 머리 주석(왜 공유하나)이 사라졌다"

# 2) 모바일이 공유 파일을 로드하고 어댑터를 등록한다
assert '/web/chat-render.js' in html, "모바일 HTML 이 chat-render.js 를 로드하지 않는다"
assert "MarinaChat.configure(" in html, "모바일이 호스트 어댑터를 등록하지 않는다"
for key in ("imageUrl", "fileUrl", "ensureAnswerState"):
    assert re.search(r"\b" + key + r"\s*:", html), f"어댑터 {key} 를 넘기지 않는다"

# 3) 노출 목록을 파싱한다
tail = js[js.index("window.MarinaChat = {"):]
exported = re.findall(r"([A-Za-z0-9_]+)\s*,", tail[:tail.index("};")])
assert len(exported) > 30, f"노출 목록 파싱 실패({len(exported)}개) — 테스트의 정규식을 확인할 것"

# 4) 추출된 함수가 모바일 인라인에 중복 정의돼 있지 않다 (다시 벌어지는 것 차단)
dupes = [n for n in exported
         if re.search(r"^\s*(?:async )?function " + re.escape(n) + r"\s*\(", html, re.M)]
assert not dupes, f"모바일에 중복 정의가 남았다: {dupes}"

# 5) 모바일이 노출 목록을 실제로 꺼내 쓴다 (구조분해)
assert "} = window.MarinaChat;" in html, "모바일이 MarinaChat 을 구조분해하지 않는다"

# 6) 공유 렌더러는 모바일 전용 전역을 참조하지 않는다.
#    금지어를 '설명하는' 주석까지 잡으면 안 되므로 코드 줄만 본다. 트레일링 주석은 " // " 로
#    시작할 때만 잘라낸다 — URL 의 "https://" 를 오려내지 않으려고.
code = []
for raw in js.split("\n"):
    if raw.lstrip().startswith("//"):
        continue
    cut = raw.find(" // ")
    code.append(raw[:cut] if cut >= 0 else raw)
code = "\n".join(code)

BANNED = ["selectedSession", "selectedSessionKey", "selectedRoot", "liveAnswer",
          "promptInput", "turnsEl", "statusEl", "cookieAuth", "transcriptImageUrl",
          "sessionFileUrl", "uploadServeUrl", "openTimelineDetailIds", "targetSelect"]
leaks = [b for b in BANNED if re.search(r"\b" + re.escape(b) + r"\b", code)]
assert not leaks, f"공유 렌더러가 모바일 전역을 참조한다: {leaks}"

# 6b) **매달린 참조**가 없다. 금지어 목록은 아는 이름만 잡는다 — 옮긴 코드가 모바일에 남은
#     임의의 const/function 을 부르면 런타임 ReferenceError 가 되고, 그건 브라우저에서만 터진다.
#     (추출할 때 activityTypeLabels·IMAGE_EXT_RE·displayModel 등이 실제로 이렇게 매달렸었다.)
mob_defined = set(re.findall(r"^\s{4}(?:const|let|var)\s+([A-Za-z_$][\w$]*)", html, re.M))
mob_defined |= set(re.findall(r"^\s{4}(?:async )?function\s+([A-Za-z_$][\w$]*)", html, re.M))
js_defined = set(re.findall(r"^\s*(?:const|let|var)\s+([A-Za-z_$][\w$]*)", js, re.M))
js_defined |= set(re.findall(r"^\s*(?:async )?function\s+([A-Za-z_$][\w$]*)", js, re.M))
# 어댑터 키(host = {imageUrl: …}) 도 '정의된 이름'이다 — 호스트가 채워 넣는 자리다
adapter_block = js[js.index("const host = {"):]
js_defined |= set(re.findall(r"^\s*([A-Za-z_$][\w$]*)\s*:", adapter_block[:adapter_block.index("};")], re.M))
# 템플릿 문자열 안 HTML 속성값이 식별자로 잡히는 오탐(loading="lazy", enterkeyhint="send" …)을 뺀다
FALSE_POSITIVES = {"loading", "send", "state"}
used = set(re.findall(r"\b([A-Za-z_$][\w$]*)\b", code))
dangling = sorted((used & mob_defined) - js_defined - FALSE_POSITIVES)
assert not dangling, (
    "공유 렌더러가 모바일에만 있는 이름을 참조한다(런타임 ReferenceError): "
    f"{dangling} — 순수하면 chat-render.js 로 옮기고, 호스트 결합이면 어댑터로 받을 것")

# 7) 렌더러가 소유하기로 한 상태는 모바일에 남아 있지 않다
assert "openTimelineDetailIds" not in html, "펼침 상태가 모바일에 아직 있다"
assert "noteDetailToggle(" in html, "모바일이 펼침 토글을 렌더러에 위임하지 않는다"
assert "setDetailScope(" in html, "모바일이 세션 스코프를 렌더러에 알려주지 않는다"

# 8b) **반대 방향 매달린 참조** — 모바일이 MarinaChat 의 이름을 쓰면서 구조분해에 안 넣으면
#     브라우저에서만 ReferenceError 가 난다(실제로 collectViewables 가 이렇게 빠졌다).
#     6b 는 'chat-render → 모바일' 한 방향만 봤다.
decl = html[html.index("} = window.MarinaChat;") - 3000: html.index("} = window.MarinaChat;")]
taken = set(re.findall(r"([A-Za-z_$][\w$]*)\s*,", decl[decl.rindex("const {"):]))
mob_code = []
for raw in html.split("\n"):
    if raw.lstrip().startswith("//"):
        continue
    cut = raw.find(" // ")
    mob_code.append(raw[:cut] if cut >= 0 else raw)
mob_code = "\n".join(mob_code)
missing = [n for n in exported
           if n not in taken
           and re.search(r"(?<![.\w$])" + re.escape(n) + r"\s*\(", mob_code)
           and not re.search(r"MarinaChat\." + re.escape(n), mob_code)]
assert not missing, (
    f"모바일이 MarinaChat 의 {missing} 를 쓰는데 구조분해에 없다 — 브라우저에서만 터진다")

# 9) 뷰어 목록(A안) 계약 — 채팅에서 열면 그 대화 것만, 순서대로. 중복 파일은 마지막 자리로 접힌다.
assert "function collectViewables" in js, "뷰어 목록 빌더가 없다"
assert "collectViewables" in exported, "collectViewables 가 노출되지 않았다"

# 10) 이미지는 접힘 밖으로. <details> 두 겹(그룹→항목) 안에 있으면 대화를 읽어서는 안 보인다.
grp = js[js.index("function renderActivityGroup"):]
grp = grp[:grp.index("\n    function ", 10)]
assert "hoisted" in grp, "활동 그룹이 이미지를 접힘 밖으로 끌어올리지 않는다"
assert grp.index("renderTimelineImages") > grp.index("<details") or "shots ? `${fold}" in grp, \
    "이미지가 <details> 안에 남아 있다"
item = js[js.index("function renderActivityItem"):]
item = item[:item.index("\n    function ", 10)]
assert "renderTimelineImages" not in item, \
    "활동 항목이 이미지를 또 그린다 — 펼치면 같은 그림이 두 번 나온다"

# 11) 파일 활동은 경로를 내보내 채팅에서 바로 열 수 있어야 한다
assert "data-file-path" in js, "활동 카드가 파일 경로를 안 내보낸다"
assert "item.path" in js, "백엔드가 준 path 를 안 쓴다(label 파싱은 계약이 아니다)"

print("ok")
PY

# 8) 문법 검사 — node 가 있으면
if command -v node >/dev/null 2>&1; then
  node --check "$JS" || { echo "FAIL: chat-render.js 문법 오류"; exit 1; }
fi
echo "ok"
