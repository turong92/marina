# SDD ledger — plan: ../homeserver/docs/superpowers/plans/2026-10-06-marina-live-L1.md (+ L2/L3 from design doc)

Pre-flight: shared interfaces checked against real marina code before Task 1.
- Ruling: 테스트 파일명은 계획의 `live-*.sh` 가 아니라 레포 관례 `test-live-*.sh` — `run-affected.sh` 가 `test-*.sh` 글롭으로만 테스트를 찾는다(tests 변수). 계획 이름을 쓰면 테스트가 러너에 영원히 안 걸린다 — 비용: 파일명뿐.
- Ruling: 테스트는 `lib/harness.sh` 를 source 하고 MARINA_HOME 을 직접 mktemp 로 세우지 않는다 — 하네스가 MARINA_* 를 전부 지우고 테스트별 고정 경로를 세운다(실 ~/.marina 오염 방지가 그 파일의 목적). 비용: 계획의 export MARINA_HOME 줄 삭제.
- Ruling: `marina_live.py`·`marina_live_cli.py` 에 `from __future__ import annotations` 를 반드시 넣는다 — 데몬은 CLT python3.9 로 돌고 `test-py39-compat.sh` 가 PEP604 시그니처를 정적으로 막는다. 계획 코드의 `dict | None` 이 그대로면 3.9 import 실패. 비용: 한 줄.
- Ruling: `up_argv(stored, ...)` 의 `stored` 는 dict 가 아니라 **compose 파일 경로**다(`_compose_base` 가 `-f stored` 로 쓴다). 계획의 "프로젝트 compose 정보" 표현이 모호했다 — live 는 `live/src/<composeFile>` 경로를 넘긴다. 비용: 틀렸다면 docker 가 즉시 거부.
- Ruling: GC 면제는 계획의 `label!=` 필터만으로 부족하다. 실측: ⑤ orphans 단계가 `<id>-live` 를 "등록 프로젝트 접두사로 시작하는데 발견된 워크트리 어디에도 없는" 고아로 판정한다(라이브는 워크트리가 없는 것이 정상). 실행 중이면 busy 로 건너뛰지만 **정지된 live 컨테이너와 그 이미지는 회수 대상**이다. 라벨 기반 제외를 ④⑤ 양쪽에 넣는다. 비용: 안 하면 재부팅 실패 중인 live 의 이미지가 사라진다.
Task 1: complete (tests: bash plugin/tests/test-live-paths.sh -> PASS)
Task 2: complete (tests: bash plugin/tests/test-live-checkout.sh -> PASS)
Task 2: Ruling: ref 는 **프로젝트 레포에서 SHA 로 풀어** 워크트리에 준다 — 계획 코드는 `git -C src checkout <ref>` 였고, src 가 detached 라 'HEAD'/'main' 이 **이전 기동 시점**으로 풀려 배포가 조용히 안 되는 것을 테스트 3에서 실측(two 기대, one 나옴). 비용: 틀렸다면 ref 해석이 한 군데 더 늘 뿐.
Task 2: Ruling: `git worktree prune` 을 add 앞에 넣었다 — src 를 손으로 지우면 레포에 등록만 남아 add 가 '이미 등록됨' 으로 영구 거부된다(테스트 7). 비용: prune 이 다른 stale 등록도 지우지만 그것은 이미 없는 워크트리다.
Task 3: complete (tests: test-live-overlay.sh PASS; 회귀 8개 PASS — compose-overlay/config/name, py39-compat, remote-volume/watch-rewrite, profile-overlay, docker-gc-overlay-labels)
Task 3: Ruling: `develop: !reset null` 은 그 서비스에 develop 이 있을 때만 쓴다 — 없는 키를 reset 하면 overlay 가 쓸데없이 커지고 모든 서비스가 overlay 에 등장한다. `docker compose config` 로 !reset 동작을 실측 확인(develop 사라지고 ports·restart 유지). 비용: 없음.
Task 3: Ruling: `project_dir_binds` 는 long syntax(dict) 도 읽고 type!=bind 는 건너뛴다 — 계획은 문자열만 봤는데 resolved config 는 long syntax 를 dict 로 준다. 그걸 빼면 가장 위험한 마운트(명시적 bind)에 경고가 안 나간다. 비용: 없음.
Task 4: complete (tests: test-live-cli.sh PASS, test-install-cli.sh PASS)
Task 4: Ruling: `live` 를 marina-entrypoint.sh 의 그룹 dispatch 목록에도 넣었다 — 계획은 marina.sh 만 고쳤는데, 전역 `marina` 는 entrypoint 를 타므로 `marina live` 가 "명령 없음" 으로 떨어진다(entrypoint 주석이 worktree/gateway 누락으로 같은 사고를 기록해 뒀다). 비용: 없음.
Task 4: Ruling: `pin` 은 services 가 비면 경고만 하고 성공한다 — pin 은 '정하기' 고 거부는 `up` 의 일이다. 그래야 pin→services 편집→up 순서가 가능하다. 비용: services 를 안 적고 up 하면 거부 메시지를 한 번 더 본다.
Task 5: complete (tests: test-live-unit.sh PASS, test-py39-compat.sh PASS)
Task 5: Ruling: 유닛 등록(launchctl/systemctl)은 `MARINA_HOME == ~/.marina` 일 때만 한다 — 계획대로면 테스트가 형의 기계에 `dev.marina.live.ovation` launchd 잡과 ~/Library/LaunchAgents 파일을 실제로 심는다. marina-dashboard.sh install_login_plist 가 이미 쓰는 가드를 그대로 재사용했다. 비용: 등록 경로 자체는 테스트가 아니라 Task 7 수동 왕복에서만 확인된다.
Task 5: Ruling: 유닛에 PATH·MARINA_HOME·ThrottleInterval 을 넣었다 — 계획 코드엔 없었다. launchd 는 최소 PATH 만 주므로 docker 를 못 찾고(재부팅 후 조용히 실패), KeepAlive 만 있으면 도커가 안 뜬 동안 초당 재시도로 폭주한다. 비용: 없음.
Task 6: complete (tests: test-live-gc.sh PASS; 회귀 test-docker-gc-*.sh 9개 PASS)
Task 6: Ruling: 계획의 "익명 볼륨 조회에 label!=marina.live 필터를 더한다" 는 **버렸다**. 실측: compose 가 만든 익명 볼륨은 라벨을 하나도 안 받는다(`com.docker.volume.anonymous` 뿐) — 필터가 아무것도 지키지 않는다. 대신 ③ 은 정지 컨테이너도 '사용자' 로 세어 dangling 이 아니므로 돌거나 정지만 한 live 에는 닿지 않음을 확인하고, 그 근거를 LIVE_LABEL 주석에 박았다. 비용: compose down 이후의 익명 볼륨은 여전히 유예 후 회수된다(다음 up 이 새로 만들어 쓰므로 진짜 쓰레기).
Task 6: Ruling: 면제를 ⑤ 고아 단계에 **두 겹**으로 넣었다 — ① `_live_session_project_names` 로 `<id>-live` 를 발견 목록에 더하고(이름), ② live 라벨 컨테이너가 있는 프로젝트를 busy 로 취급(라벨). 레지스트리에서 프로젝트를 지운 뒤에도 운영 중인 것을 지키려면 라벨이 필요하다. 비용: 라벨만 손으로 붙인 컨테이너도 면제된다.
Task 6: Ruling: `_is_e2e` 는 live 라벨이 있으면 False — 두 라벨이 동시에 붙은 경우 운영이 테스트 표식을 이긴다. 비용: 테스트가 만든 live 스택은 자동 회수되지 않는다(테스트는 MARINA_HOME 격리로 live 를 안 만든다).
Task 7: complete — L1 끝 (tests: test-live-up.sh 왕복 PASS, test-live-* 7개 PASS, py39/compose-overlay/install-cli PASS)
Task 7: Ruling: `up_argv` 의 stored 에 **live/src 안의 compose 파일 경로**를 준다 — 그래야 compose 정의가 ref 와 함께 배포된다(`marina project add` 가 ~/.marina 로 복사해 둔 사본을 쓰면 코드만 롤백되고 compose 는 안 돌아간다). 비용: 프로젝트가 compose 를 레포 밖에 두면 live.composeFile 로 지정해야 한다.
Task 7: Ruling: `down`·`logs` 는 체크아웃이 없어도 **프로젝트명만으로** 동작한다 — src 를 손으로 지운 뒤에도 돌고 있는 컨테이너를 거둘 길이 있어야 한다. 비용: overlay 없이 내리므로 orphan 경고가 날 수 있다(--remove-orphans 로 덮는다).
Task 7: Ruling: 테스트의 MARINA_HOME 을 하네스 기본($TMPDIR=/var/folders/…)에서 /tmp 아래로 옮겼다. 실측: Docker Desktop 기본 공유 경로에 /var/folders 가 없어 그 아래 바인드 마운트가 **조용히 VM 내부 디렉터리**로 만들어진다(컨테이너에는 파일이 보이고 호스트에는 안 보임). 데이터 경로를 단정하는 테스트가 그 위에서는 거짓 실패한다. 비용: 그 테스트만 /tmp 를 쓴다(실사용 ~/.marina 는 /Users 라 공유됨).
Task 7: Ruling: 기동 직후 상태 확인을 `up` 안에 넣고, 떠 있지 않은 컨테이너가 있으면 로그 tail 을 내고 **비0으로 끝낸다** — "Started" 출력만 보고 운영을 믿으면 홈서버에서 겪은 '떴다는데 죽어 있다' 가 반복된다. 비용: 느린 기동(헬스체크 전) 서비스에서 거짓 실패 가능 — 상태가 running 이면 통과하므로 창이 좁다.
L2: complete (tests: test-live-expose.sh PASS; 회귀 remote 14개·gateway 13개·live 8개·py39 PASS)
L2: Ruling: **설계 결정 1을 뒤집었다.** 설계는 "443 의 경로 하나를 할당" 이었는데, 코드 실측으로 Tailscale `AllowFunnel` 이 **경로가 아니라 authority(host:port) 단위**임을 확인했다(`marina_remote._routes` 가 `AllowFunnel[host:443]` 로 판정). 443 의 /app 을 공개하려고 funnel 을 켜면 같은 443 의 "/" 에 있는 **대시보드까지 인터넷에 열린다** — 관리 UI 공개 금지 위반. 그래서 live 는 8443·10000 만 쓰고 동시 공개는 최대 2개, 세 번째는 거부하고 Cloudflare 를 안내한다(한도를 자동 배정으로 숨기지 않는다). 비용: 주소가 `https://host.ts.net:8443/<앱>` 로 못생기고 일부 기업망이 비표준 포트를 막는다.
L2: Ruling: `RemoteController` 에 live 라우트 개념을 넣었다(`liveRoutes` 저장 + `_own_routes`/`_own_mode`). 안 하면: `activate()` 의 `_matches` 가 "라우트 1개" 를 요구해 롤백하고, `off()` 가 live 라우트를 보고 "안 꺼졌다" 로 판정한다 — 즉 live 를 공개하면 대시보드 원격 접근을 켜지도 끄지도 못한다(테스트로 실측). 비용: 소유 판정이 저장 상태에 의존하는 면이 늘었다.
L2: Ruling: 우리 자신이 설정을 바꾼 직후 지문을 다시 저장한다(`_refresh_fingerprint`). live 라우트가 남아 설정이 비지 않으면 저장 지문이 낡아 `conflict=True` 가 되고, "남의 설정은 건드리지 않는다" 안전장치가 **우리 변경** 때문에 작동해 off/activate 가 영구 실패한다(실측). 비용: 밖에서 바뀐 변경을 감지하는 창이 그 한 순간 좁아진다.
L2: Ruling: cloudflared 토큰 **값**은 overlay 에 넣지 않고 `live/secrets.env`(0600)를 `env_file` 로 참조한다 — overlay 는 평문으로 ~/.marina 에 남는 생성물이다. 비용: 그 파일이 백업에서 빠지면 공개가 복구되지 않는다(L3 backup-paths 가 목록에 넣는다).
L2: Ruling: 백엔드 포트는 **선언된 published 포트**에서 찾고, 둘 이상이면 `--service` 를 요구한다 — 추측하면 엉뚱한 서비스가 인터넷에 열린다. 비용: 포트를 안 게시한 앱은 공개하려면 compose 를 고쳐야 한다.
