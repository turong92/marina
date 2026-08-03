# web·mobile 정합 — 대화 탭 · CLI 버전 배너 · 모바일 로그/깃

- 날짜: 2026-08-03
- 상태: 승인됨 (형 "ㄱㄱ", 2026-08-03)
- 브랜치: `asdf`

## 배경

marina 의 두 프론트엔드가 서로 다른 방향으로 벌어졌다.

- **web** (`plugin/scripts/marina-web/*.js`) = 인프라 조종석. 로그 뷰어·깃 그래프·연결·터미널·compose 등록.
- **mobile** (`plugin/scripts/marina_mobile.py` 인라인 SPA) = 대화 클라이언트. 타임라인·이미지·질문카드·전송·갤러리·사용량.

실측한 기능 diff:

| | web | mobile |
|---|---|---|
| 세션/워크트리 목록, 에이전트 Inbox, 서비스 시작/정지, 워크트리 생성 | ✅ | ✅ |
| 대화 보기 | 읽기전용 텍스트 모달 (`/api/agent-transcript`) — 도구호출·이미지 생략 | 풀 채팅 (타임라인·도구활동·diff·이미지) |
| 메시지 전송 / 질문 카드 / 첨부·업로드 / 갤러리 / 사용량 / 슬래시 카탈로그 / 모델·effort / 서브에이전트 / 정지 | ❌ | ✅ |
| 서비스 로그 뷰어 / 깃 탭 / 연결 탭 / 터미널 / compose 등록 | ✅ | ❌ |
| marina 플러그인 업데이트 배너 | ✅ | ❌ (모바일 `updateBanner` 는 데몬 재시작 감지 새로고침일 뿐) |
| claude·codex **CLI 자체** 버전 업데이트 | ❌ | ❌ (터미널에서 CLI 띄울 때만 보임) |

세 가지 문제를 푼다.

1. web 에서 세션을 터미널로만 열 수 있어 **이미지·diff 를 보기 힘들다**.
2. **claude/codex CLI 새 버전**을 터미널 밖에서는 알 수 없다. 형 환경은 `installMethod=native`, `autoUpdates=false` 라 자동으로 올라가지도 않는다.
3. 모바일에서 **로그·깃 상태를 못 본다** — 밖에서 "빌드 깨졌나" 확인 불가.

## 멘탈 모델 (모든 결정의 기준)

> **에이전트 세션은 "대화"에서, 셸은 "터미널"에서.**

현재는 터미널 탭이 두 역할을 겸한다: ① 워크트리 셸(cmux 멀티탭·4분할), ② `AGENTS` 행 클릭 시 `claude --resume` PTY attach (`app-5-sessions.js:275`). 그리고 채팅 전송도 결국 같은 PTY 로 들어간다 (`mobile_send` → `_live_agent_tid` → term-input, PTY 없으면 takeover/outbox). 즉 대화는 다른 채널이 아니라 **같은 세션의 다른 렌즈**다.

둘이 서로를 대체하지 못하는 이유:

- 터미널만 있으면 — detach 된 세션·과거 세션의 이미지를 못 본다 (지금 겪는 문제).
- 대화만 있으면 — 셸 명령을 못 친다. 권한 프롬프트·`/명령`·TUI 조작도 원본이 필요하다.

그래서 역할을 완전히 가른다.

| 탭 | 대상 | 안에서 하는 것 |
|---|---|---|
| **대화** (신규) | 에이전트 세션 1개 | `[대화]` 정리된 타임라인·이미지·질문카드·전송 / `[원본]` 그 세션의 PTY 그대로 |
| **터미널** | 워크트리 셸 | bash 만. cmux 멀티탭·4분할 유지 |

- `AGENTS` 행 클릭 → **대화 탭**으로 점프 (현재는 터미널 attach).
- 터미널 탭 사이드바에서 **에이전트 PTY 를 제외**한다 (`app-10-term.js:63-71`). 에이전트 PTY 의 원본 보기·kill 은 대화 탭 `[원본]` 이 담당.
- `[대화|원본]` 세그먼트 토글이 "같은 세션의 두 시점"임을 시각적으로 보증한다.

## 아키텍처

### 1. 백엔드 — 에이전트 API 이중 프리픽스

**문제.** 웹은 `/mobile/api/*` 를 부를 수 없다: auth 가 꺼진 로컬에서 `authorize()` 가 `principal=None` 을 돌려주고, 모바일 라우트는 `if principal is None and not mobile_request_ok(...)` 로 토큰 검사에 떨어져 403 이 된다. 반대로 모바일은 `/api/*` 를 부를 수 없다: `do_GET`/`do_POST` 의 `host_guarded` 가 `/api/` 를 호스트로 막아 펀넬 호스트에서 오면 `forbidden host` 다 (`marina_handler.py:213` 주석에 이미 명시).

**해법.** 라우트를 옮기지 않는다. **경로 별칭 + 인증 술어** 두 가지만 더한다. 이미 존재하는 `/api/mobile-send` / `/api/mobile-state` 별칭 패턴을 일반화하는 것이다.

```
do_GET / do_POST 진입부:
    /api/agent/<op>  ──정규화──>  /mobile/api/<op>       (self._agent_api_web = True)

기존 /mobile/api/<op> 라우트 본문은 그대로. 반복되던
    if principal is None and not mobile_request_ok(self, parsed): 403
을 다음 한 줄로 교체:
    if not self._agent_api_ok(parsed, principal): 403
```

```python
def _agent_api_ok(self, parsed, principal) -> bool:
    """에이전트 API 인증 — 웹(/api/agent/*)과 모바일(/mobile/api/*)이 같은 라우트를 공유한다.
    웹 경로는 이미 host_guarded(+POST 는 origin/CSRF)를 통과했으므로 모바일 토큰을 요구하지 않는다.
    나머지 자원 권한(_require_root_access · can_resource)은 라우트 본문에서 종전대로 검사한다."""
    if principal is not None:
        return True
    if getattr(self, "_agent_api_web", False):
        return is_loopback_client(self)      # auth 꺼진 로컬 대시보드
    return mobile_request_ok(self, parsed)
```

- 기존 `/mobile/api/*` 는 **경로·동작·응답 불변**. 모바일 회귀 위험 0.
- 기존 웹 라우트 `/api/agent-transcript` 도 **경로 유지**한다. 웹 대화 탭은 새 경로 `/api/agent/transcript` 를 쓰고, 옛 경로는 제거하지 않는다.
- `/api/agent/*` 는 `host_guarded` 예외로 빼지 **않는다** — 웹은 대시보드 호스트로만 들어오므로 통과하고, 펀넬 호스트에서 오는 요청은 여기서 막히는 게 옳다(모바일은 `/mobile/api/*` 로 간다).
- 새 모듈을 만들지 않는 이유: 라우트 배선은 핸들러의 책임이고, 모바일 라우트 12개를 통째로 옮기는 리팩터는 이 작업의 목표(정합)와 무관한 회귀 위험만 더한다. `marina_handler.py` 가 큰 것은 선행 문제이며 범위 밖이다.

### 2. 프론트 — 타임라인 렌더러 공유

모바일 렌더러는 이미 잘 쪼개져 있다: `timelineFromTurns`, `mergeTimelineItems`, `renderTimelineMessage`, `renderTimelineImages`, `renderActivityItem`, `renderActivityGroup`, `reconcileActivityList`, `renderQuestionCard`, `renderRichText`, `renderMarkdownBlocks`, `renderActivityCode` 등 약 30개 함수.

웹에 다시 짜면 **또 벌어진다** — 지금 문제의 재생산이다. 그래서 추출한다.

- 이 함수군을 `marina-web/chat-render.js` 로 옮긴다.
- 모바일 인라인 HTML 은 `<script src="/web/chat-render.js"></script>` 로 로드한다. `/web/` 는 `PUBLIC_PREFIXES` 라 auth 가 켜져도, 펀넬 호스트에서도 접근 가능하고(`host_guarded` 는 `/api/` 만 검사), `cache-control: no-store` 라 staleness 가 없다 — 코드로 확인함.
- **마크업 계약은 공유, CSS 는 각자.** 클래스명이 같으면 모바일은 인라인 스타일, 웹은 `styles.css` 로 각자 스킨을 입힌다.
- 전역 오염을 피하려고 `window.MarinaChat = {...}` 네임스페이스 하나로 노출한다.

웹 신규 파일:

- `marina-web/chat-render.js` — 공유 렌더러 (모바일에서 추출)
- `marina-web/app-11-chat.js` — 웹 전용 대화 탭 셸: 세션 셀렉터, `[대화|원본]` 토글, 폴링, 컴포저

### 3. 대화 탭 상세

`index.html`:

- `ws-tabs` 에 `대화` 버튼 추가, `<div class="ws-pane" id="tab-chat" hidden>` 추가.

탭 내부 구성 (위→아래):

1. **세션 탭 스트립 (브라우저식 멀티탭)** — 열어 둔 에이전트 세션이 각각 탭 하나다.
   - **워크트리를 넘나든다.** 다른 워크트리의 세션을 열면 교체가 아니라 탭이 추가된다 — 브라우저 탭과 같은 감각이고, 여러 워크트리를 동시에 돌릴 때 왔다 갔다 하지 않아도 된다.
   - 탭 라벨 = `상태점 · 하네스 · 세션 제목`. 워크트리가 둘 이상 열려 있을 때만 워크트리명을 앞에 붙인다(같은 워크트리끼리는 군더더기).
   - `✕` 로 닫고 가운데 클릭으로도 닫는다. `+` 는 현재 선택된 워크트리의 아직 안 열린 세션 목록을 드롭다운으로 띄우고, 세션이 없으면 `세션 시작`(`/mobile/api/launch` 재사용)을 제공한다.
   - 열린 탭 목록은 `localStorage` 에 남긴다(`{root, source, sid}` 배열 + 활성 인덱스). 새로고침·재시작해도 복원되고, 사라진 세션은 복원 때 조용히 걷어낸다.
   - 탭이 많으면 스트립이 가로 스크롤된다. 상한은 두지 않는다 — 브라우저도 안 둔다.
   - **탭마다 상태가 독립이다**: 트랜스크립트 커서·스크롤 위치·`[대화|원본]` 선택·입력 중인 초안. 탭을 바꿔도 치던 글이 날아가지 않는다.
   - 안 읽은 변화 표시: 비활성 탭의 세션에 새 턴이 붙으면 라벨에 점을 찍는다.
2. **`[대화 | 원본]` 세그먼트** — 활성 탭에만 적용된다.
3. `대화` — `chat-render.js` 타임라인. 이전 메시지 페이지네이션(`before` 커서), 이미지 인라인, 도구활동 그룹, 질문 카드, 새 메시지 버튼.
4. `원본` — 그 세션의 PTY 를 이 pane 에 xterm 으로 마운트. `app-10-term.js` 의 attach 로직을 `mountAgentTerm(paneEl, root, agent)` 로 추출해 재사용. kill 버튼 포함.
5. **컴포저** — 첨부(이미지 업로드)·슬래시 제안·전송·정지·모델/effort. `대화` 뷰에서만 표시(`원본` 은 PTY 가 직접 입력을 받음).

진입점 변경:

- `wireAgentRows` 의 행 클릭: `openAgentTerminal` → `openAgentChat`(대화 탭 활성화 + 그 세션 탭을 열거나, 이미 열려 있으면 그 탭으로 이동).
- 행의 `대화` peek 버튼은 제거하고(중복), 대신 `>_` 아이콘으로 "원본으로 열기"를 제공한다.
- 기존 읽기전용 모달 `openAgentTranscript`(`app-6-modals.js:655`)는 **삭제**한다 — 대화 탭이 상위 호환.

폴링:

- **활성 탭** — 3초마다 트랜스크립트를 폴링한다. 기존 `render()` 전체 재렌더와 충돌하지 않게 `reconcileActivityList` 계약을 그대로 쓰고, 입력 중·전송 중·질문 응답 중에는 재렌더를 미룬다 (모바일의 defer-guard 와 동일 규칙).
- **비활성 탭** — 트랜스크립트를 받아오지 않는다. 대신 이미 5초마다 도는 `loadWorktrees()` 의 `agents[].statusTs` 로 "새 턴이 붙었나"만 판정해 점을 찍는다. 탭 N개를 각각 폴링하면 N배 부하가 되므로 안 한다.
- 대화 워크스페이스 탭이 비활성이거나 브라우저 탭이 숨겨져 있으면 전부 멈춘다.

### 4. CLI 버전 배너

신규 `marina_cliver.py`:

- **설치본** — `claude --version`, `codex --version` (타임아웃 10s). 실패하면 `unknown` 이고 배너를 띄우지 않는다.
- **최신** — `https://registry.npmjs.org/@anthropic-ai/claude-code/latest`, `.../@openai/codex/latest` 의 `version`. native·brew 설치본도 번호가 npm 과 일치함을 실측 확인 (claude 2.1.220 / codex 0.146.0 양쪽 일치).
- **설치 방식** — claude 는 `~/.claude.json` 의 `installMethod`(`native`/`global`/…) 와 `autoUpdates`. codex 는 `which codex` 경로로 brew(`/opt/homebrew`, `/usr/local`) vs npm 판별.
- **업데이트 명령** — `native` → `claude update`, `brew` → `brew upgrade codex`, `npm` → `npm i -g <pkg>`.
- **캐시** — TTL 30분. 버전은 하루 단위로 바뀌고 네트워크 조회라 짧을 이유가 없다. `marina_update.py` 의 `_status_cache` 와 같은 패턴.
- 네트워크 실패 시 `latest=None` → `behind=False` (배너 없음). 오탐보다 미탐이 낫다.

노출:

- `/api/update-status` 페이로드에 `cli` 키를 **얹는다**:
  ```json
  "cli": {"claude": {"installed": "2.1.220", "latest": "2.2.0", "behind": true,
                     "method": "native", "cmd": "claude update", "autoUpdates": false},
          "codex":  {"installed": "0.146.0", "latest": "0.146.0", "behind": false,
                     "method": "brew", "cmd": "brew upgrade codex"}}
  ```
  웹은 이미 60초마다 이걸 폴링하므로(`app-6-modals.js` `loadUpdateStatus`) 배너 컴포넌트 하나가 marina 플러그인 업데이트와 CLI 업데이트를 같이 그린다.
- 모바일용 `/mobile/api/update-status` 를 추가하고, 모바일 헤더에 같은 배너를 띄운다. 기존 모바일 `updateBanner`(데몬 재시작 감지)와는 **다른 요소**다 — 이름 충돌을 피해 신규 요소는 `cliUpdateBanner` 로 한다.

**원클릭 + 안전가드** — `POST /api/agent/cli-update {harness}` (모바일은 `/mobile/api/cli-update`):

- 실행 전 `agents_payload` 의 `resolve_session_liveness` 로 해당 source 의 세션 상태를 본다.
- `running` 또는 `waiting` 세션이 하나라도 있으면 **409** + `{"busy": [{"title": ..., "status": ...}]}` 로 거부한다. UI 는 버튼을 비활성화하고 "claude 세션 2개 작업 중 — 끝나면 받기" 로 표시한다.
- 전부 유휴일 때만 명령을 실행한다. 타임아웃 300s, stdout 마지막 200자를 응답에 담는다.
- 성공 후 캐시를 무효화하고 즉시 재조회한다 (`update_claude` 의 `_status_cache.clear()` 와 같은 순서 — 완료 "후" 무효화로 진행 중 폴링의 재충전 레이스 차단).

### 5. 모바일 로그·깃 (읽기 전용)

모바일의 기존 시트(sheet) 패턴을 그대로 따라 두 개를 추가한다.

**로그 시트** — 세션 카드에서 진입.

- 서비스 선택 → tail + 필터 + 에러만 + run 선택.
- 신규 라우트 `/mobile/api/logs/chunk`, `/mobile/api/logs/matches` 가 기존 `read_log_chunk`·`scan_log_matches`·`selected_log` 를 그대로 호출한다. **서버 로직 신규 0.**
- 게이지 바·다운로드·콘솔 로그·빌드 요약은 넣지 않는다 (작은 화면 ROI).

**깃 시트** — 세션 카드에서 진입.

- 브랜치 상태(ahead/behind/dirty) → WIP 변경파일 목록 → 파일별 diff → 최근 커밋 목록 → 커밋 상세.
- 신규 라우트 `/mobile/api/git-wip-stat`, `/mobile/api/git-diff`, `/mobile/api/git-graph`, `/mobile/api/git-commit-info` 가 기존 함수를 재사용한다.
- 레인 그래프는 그리지 않고 **커밋 리스트**로만 표시한다.
- 쓰기 계열(커밋·푸시·머지·리베이스·스태시·fetch)은 **넣지 않는다**.

두 시트 모두 `_require_root_access` 로 워크트리 접근을 검사한다.

## 데이터 흐름

```
[웹 대화 탭]  ──> /api/agent/<op>   ──┐  (경로 별칭으로 정규화)
                                      ├──> 같은 /mobile/api 라우트 본문 ──> marina_mobile.py
[모바일 채팅] ──> /mobile/api/<op> ──┘                          ──> marina_sessions.py

[웹 배너]     ──> /api/update-status        ──┐
                                              ├──> marina_update.py (plugin SHA)
[모바일 배너] ──> /mobile/api/update-status ──┘  + marina_cliver.py (CLI 버전)

[모바일 로그] ──> /mobile/api/logs/*  ──> read_log_chunk / scan_log_matches (기존)
[모바일 깃]   ──> /mobile/api/git-*   ──> marina_git.py (기존)
```

## 에러 처리

- **CLI 버전 조회 실패** (네트워크·타임아웃·CLI 미설치) → `latest=None`, `behind=False`, 배너 없음. 조용히 실패한다.
- **CLI 업데이트 busy** → 409 + `busy` 배열. UI 는 버튼 비활성 + 사유 표시.
- **CLI 업데이트 실패** → 명령 stdout/stderr 마지막 200자를 토스트로. 캐시는 무효화하지 않는다(옛 상태 유지가 정확).
- **대화 탭 세션 없음** → 빈 상태 + `세션 시작` 버튼.
- **PTY 없는 세션에서 `[원본]`** → "이 세션은 지금 붙어있는 터미널이 없어요 · 대화에서 메시지를 보내면 이어받아요" 안내. `mobile_send` 의 takeover 경로가 그 역할을 한다.
- **모바일 로그/깃 권한 없음** → 기존 `_forbidden()` 403 경로 그대로.

## 테스트

`plugin/tests/` 에 추가한다. **`lib/harness.sh` 를 반드시 소스한다** — 실 `MARINA_HOME` 을 읽고 쓰던 격리 결함이 재발하면 안 된다.

- `test-cli-version.sh` — `--version` 파싱, npm 조회 스텁, `behind` 판정, 설치 방식별 명령 매핑, busy 가드 409, 네트워크 실패 시 무배너.
- `test-agent-api-dual-prefix.sh` — 같은 op 가 `/api/agent/*`(loopback)와 `/mobile/api/*`(token) 양쪽에서 동일 응답. 권한 없는 root 는 양쪽 다 403.
- `test-mobile-logs-git.sh` — 신규 읽기 라우트의 페이로드와 `_require_root_access` 검사. 쓰기 라우트가 모바일 프리픽스에 **없음**도 확인.
- `test-chat-render-shared.sh` — `marina-web/chat-render.js` 가 존재하고 모바일 HTML 이 그것을 `<script src>` 로 참조하며, 추출된 함수들이 모바일 인라인에 중복 정의돼 있지 않은지. 추출이 되돌아가지 않게 잠근다.
- 기존 모바일 테스트 전량 통과 (`test-agent-timeline.sh`, `test-agent-history-pagination.sh`, `test-agent-question-surfacing.sh`, `test-mobile-*` 등) — 2단계의 게이트.

브라우저 실측(Aside): 대화 탭에서 전송·이미지 렌더·`[원본]` 토글·CLI 배너·모바일 로그/깃 시트.

## 구현 순서

각 단계가 독립적으로 검증 가능하도록 나눈다.

1. **백엔드 이중 프리픽스** — `/api/agent/*` 경로 별칭 + `_agent_api_ok`. 기존 모바일 무회귀가 통과 기준.
2. **`chat-render.js` 추출** — 모바일이 그것을 쓰게 전환. **모바일 동작 불변 확인이 게이트** (기존 모바일 테스트 전량 + Aside 실측).
3. **웹 대화 탭 + 터미널 역할 분리** — `app-11-chat.js`, `index.html`, `app-5-sessions.js` 진입점, `app-10-term.js` 에이전트 PTY 제외, `openAgentTranscript` 삭제.
4. **`marina_cliver.py` + 배너** — web·mobile 양쪽.
5. **모바일 로그·깃 시트** — 라우트 + 시트 UI.

## 범위 밖 (다음 사이클 백로그)

- 모바일에 터미널·compose 등록 위저드·연결 탭 — 작은 화면 ROI 가 나쁘다.
- 웹에 갤러리 시트·사용량 패널 — 대화 탭이 자리 잡은 뒤 얹는다.
- 모바일 깃 쓰기 작업(커밋·푸시·머지).
- 모바일 로그의 게이지 바·다운로드·콘솔 로그·빌드 요약.
