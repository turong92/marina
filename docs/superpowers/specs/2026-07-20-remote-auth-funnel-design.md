# 원격 인증과 다중계정 설계

날짜: 2026-07-20

상태: A단계 인증 기반 구현 및 검증 완료 (2026-07-21)

A단계로 SQLite 계정 저장소, 최초 관리자 초기화, 사전 등록·비밀번호 설정·관리자 승인,
로그인 세션·CSRF·rate limit, desktop/mobile 공통 로그인, 관리 화면과 로컬 복구 CLI를 구현했다.
기존 localhost와 mobile token 호환은 최초 관리자 생성 전까지 유지되며, 인증 활성화 후에는 동일한
계정 session cookie를 사용한다. 자원 소유권·필터링, Tailscale Serve, Funnel은 후속 단계다.

## 목표

Marina를 설치한 컴퓨터에서 대시보드, 모바일 채팅, 터미널을 안전한 단일 HTTPS 주소로 사용한다.
개인 사용은 Tailscale Serve로 시작하고, Marina 인증과 권한 검증이 준비된 뒤 Funnel을 선택적으로 켜
Tailscale을 설치하지 않은 팀원도 같은 주소로 접속하게 한다.

초기 버전은 신뢰된 팀원을 대상으로 하는 애플리케이션 수준 격리다. 사용자별 화면과 API 권한은 분리하지만,
모든 터미널 프로세스가 같은 호스트 OS 사용자로 실행되므로 악의적인 셸 명령까지 격리한다고 주장하지 않는다.
Unix 계정 또는 컨테이너 기반 강한 격리는 회사 서버 배포 단계의 별도 과제로 둔다.

## 범위 분해

한 번에 공개 접속까지 열지 않고 다음 순서로 진행한다.

1. **인증 기반**: 로컬 계정, 최초 비밀번호 설정, 관리자 승인, 로그인 세션, 복구 CLI.
2. **소유권과 권한**: 프로젝트 할당, worktree·터미널·agent 세션 소유권, API 필터와 감사 기록.
3. **Private Remote**: 설정 화면에서 Tailscale Serve를 관리하고 Tailnet 전용 HTTPS 주소를 제공한다.
4. **Public Remote**: 인증·권한·rate limit 검증 후에만 Tailscale Funnel을 활성화한다.

각 단계는 독립 테스트와 배포 단위를 가진다. 1~2단계가 완료되기 전에는 Funnel을 켜지 않는다.

## 인스턴스와 역할

- Marina 설치 단위 하나가 인스턴스 하나다. 초기에는 조직·테넌트 계층을 두지 않는다.
- 인증을 처음 초기화한 로컬 설치자가 최초 `admin`이 된다.
- 최초 관리자 생성은 loopback 요청 또는 로컬 CLI에서만 허용한다. 초기화가 끝나면 생성한 관리자로 즉시
  로그인된 세션을 발급하고 원격 요청에서 bootstrap API를 다시 호출할 수 없게 한다.
- 기존 프로젝트, worktree, 터미널, Claude/Codex 세션은 모두 최초 관리자 소유로 마이그레이션한다.
- 역할은 `admin`과 `member` 두 개만 둔다.
- `admin`은 사용자, 프로젝트 할당, 모든 작업, 원격 모드를 조회·조작한다.
- `member`는 할당된 프로젝트와 본인 소유 작업만 조회·조작한다.
- 최소 한 명의 활성 관리자를 항상 유지한다. 마지막 관리자는 비활성화하거나 강등할 수 없다.

팀원 간 작업 공유는 초기 범위가 아니다. 데이터 모델은 리소스별 단일 `owner_id`만 요구하고,
향후 읽기·조작 ACL을 별도 테이블로 추가할 수 있게 리소스 식별자를 안정적으로 보존한다.

## 사용자 등록과 승인

공개 회원가입, 이메일 발송, 초대 링크, 임시 비밀번호는 두지 않는다.

1. 관리자가 사용자명, 표시 이름, 역할, 접근 프로젝트를 사전 등록한다.
2. 사용자는 일반 Marina 로그인 화면에서 등록된 사용자명과 새 비밀번호를 입력한다.
3. 계정은 `pending_approval` 상태가 되고 어떤 프로젝트 데이터도 반환받지 않는다.
4. 관리자가 접수 시각과 사용자명을 확인해 승인한다.
5. 승인된 계정만 로그인 세션을 발급받는다.

사용자명만으로 최초 설정을 시작할 수 있으므로 선점 시도는 가능하다. 이를 안전하게 다루기 위해 승인 전 계정은
항상 무권한이며, 관리자는 잘못된 요청을 거절하고 계정을 `unclaimed`으로 되돌릴 수 있다. 최초 설정과 로그인 모두
사용자명 단위 rate limit을 적용한다.

계정 상태는 `unclaimed`, `pending_approval`, `active`, `disabled`로 제한한다. 비밀번호 초기화는 계정을
`unclaimed`으로 되돌리고 기존 세션을 모두 폐기한다.

## 저장소와 비밀번호

인증 상태는 `~/.marina/auth.db` SQLite 파일 하나에 저장한다. Python 표준 라이브러리 `sqlite3`만 사용하며
DB 서버, Docker 서비스, pip 패키지를 추가하지 않는다. 스키마 변경은 `schema_version` 기반 순차 migration으로
처리하고 WAL 모드를 사용한다.

비밀번호는 현재 기본 macOS Python에서도 동작하는 `PBKDF2-HMAC-SHA256`으로 파생한다.

- 사용자별 16바이트 이상 랜덤 salt
- 기본 반복 횟수 600,000회
- 32바이트 파생 키
- `hmac.compare_digest` 비교
- 알고리즘, 반복 횟수, salt, 파생 키를 별도 필드로 저장
- 로그인 성공 시 저장된 정책이 현재 정책보다 약하면 자동 재해시

비밀번호 원문, 로그인 세션 토큰 원문, CSRF 토큰 원문은 저장하지 않는다. 향후 scrypt 또는 Argon2를 사용할 수
있는 런타임에서는 기존 레코드와 공존한 뒤 로그인 성공 시 점진적으로 교체할 수 있다.

## 데이터 모델

초기 SQLite 테이블은 다음 책임으로 나눈다.

- `meta`: schema version, auth 활성화 시각, 인스턴스 ID.
- `users`: 사용자명, 표시 이름, 역할, 상태, 비밀번호 파생 정보, 승인·변경 시각.
- `project_access`: 사용자와 Marina project ID의 접근 관계.
- `resource_owners`: canonical resource type/key와 owner user ID. worktree root, terminal ID, agent source/session ID를 다룬다.
- `auth_sessions`: 세션 토큰 해시, 사용자, CSRF 해시, 생성·최근 사용·절대 만료 시각.
- `auth_attempts`: 사용자명 기준 최초 설정·로그인 실패 창과 잠금 시각.
- `audit_events`: actor, action, resource, 결과, 시각, 최소 요청 메타데이터.

SQLite에는 대화 내용, 터미널 입출력, 서비스 로그를 저장하지 않는다.

## 로그인 세션과 HTTP 방어

- 세션 토큰은 256비트 이상 난수로 발급하고 DB에는 SHA-256 해시만 저장한다.
- 기본 만료는 30일 비활성, 90일 절대 만료다.
- 비밀번호 변경·초기화, 계정 비활성화, 관리자 `전체 로그아웃`은 대상 세션을 즉시 폐기한다.
- 원격 HTTPS에서는 `Secure`, 모든 경로에서 `HttpOnly`, `SameSite=Lax`, host-only 쿠키를 사용한다.
- localhost HTTP 세션은 localhost host-only 쿠키로 분리하고 외부 호스트에 재사용하지 않는다.
- 모든 변경 API는 허용 Origin과 세션별 CSRF 토큰을 함께 검사한다.
- 최초 설정과 로그인은 사용자명별 최근 15분 5회 실패 후 15분 잠근다. 성공 또는 관리자 초기화로 해제한다.
- 프록시 전달 헤더는 요청이 localhost의 Marina 관리 프록시에서 왔을 때만 신뢰한다.
- 로그인과 인증 응답은 저장하지 않도록 하고 CSP, frame 차단, MIME sniffing 차단, 제한적인 referrer policy를
  공통 적용한다. HSTS는 Marina가 확인한 HTTPS Serve/Funnel 응답에만 적용한다.

인증 초기화 전에는 기존 localhost 무인증 동작을 유지한다. 관리자가 설정 화면에서 인증을 초기화한 뒤에는
localhost, Serve, Funnel을 포함한 모든 대시보드 API가 같은 인증·권한 검사를 사용한다. 정적 로그인 화면,
로그인/최초 설정 API, 최소 health endpoint만 비인증으로 남긴다.

원격 모드 `off`는 Tailscale 노출만 닫으며 인증을 끄지 않는다. 인증 해제는 원격 모드가 `off`인 상태에서만
로컬 CLI로 수행할 수 있고, 명시적 확인 후 모든 세션을 폐기한다. 설정 화면이나 원격 요청에서는 인증을 해제할
수 없다.

기존 `/mobile` token은 인증 비활성 상태에서만 호환한다. 인증 활성화 이후 모바일은 데스크톱과 같은 세션 쿠키를
사용하고 token 기반 데이터 API 접근은 거부한다.

## 권한과 소유권

API 응답에서 필터링하고, 변경 요청에서 다시 권한을 검사한다. UI에서 숨기는 것만으로 권한을 구현하지 않는다.

### 관리자

- 모든 프로젝트, worktree, 서비스, agent, 터미널을 조회·조작한다.
- 사용자 생성·승인·거절·비활성화·프로젝트 할당·비밀번호 초기화를 수행한다.
- 기존 또는 미소유 리소스를 특정 사용자에게 재할당한다.
- Serve/Funnel 모드와 전체 세션 폐기를 관리한다.

### 팀원

- 할당된 프로젝트의 이름과 공용 상태를 조회한다.
- 본인 소유 worktree와 그 서비스·로그·터미널·agent 세션만 조회·조작한다.
- 로그인 상태에서 만든 worktree, 터미널, agent 세션의 owner가 자동으로 된다.
- 다른 사용자의 리소스는 목록과 검색 결과에서 제외한다.
- main checkout과 기존 리소스는 관리자 소유이므로 명시적 재할당 전에는 조작할 수 없다.

이 권한은 우발적 충돌과 화면 혼선을 막는 애플리케이션 정책이다. 팀원이 허용된 터미널에서 호스트 파일 시스템을
직접 탐색하는 행위까지 막지 않는다.

## 원격 모드

설정의 `원격 접근` 섹션은 다음 세 상태를 가진다.

- `off`: 로컬 대시보드만 사용한다.
- `serve`: Tailscale Serve를 통해 Tailnet 내부에 HTTPS로 제공한다.
- `funnel`: Tailscale Funnel을 통해 공개 인터넷에 HTTPS로 제공한다.

모바일 UI는 별도 활성화 대상이 아니다. 대시보드가 실행 중이면 `/mobile`은 항상 존재하고 같은 로그인 쿠키를
사용한다. 기본 주소 `/`의 frontend bootstrap이 `matchMedia`로 좁은 화면을 감지해 `/mobile`로 이동시키며
`?desktop=1`로 데스크톱 화면을 강제할 수 있다. 이 판단은 서버의 User-Agent 추측에 의존하지 않는다.

### Tailscale 상태 확인

Marina는 다음 상태를 15초 이상 캐시해 진단한다.

- CLI 설치와 버전
- daemon `Running` 여부
- Tailnet DNS 이름과 Tailscale IP
- Serve/Funnel 현재 설정
- HTTPS와 MagicDNS 준비 여부
- 마지막 정상 확인 시각과 최근 오류

Tailscale이 끊겨도 로컬 Marina는 계속 실행한다. `--bg` 설정은 tailscaled가 복구하며 Marina는 상태가 다시
정상으로 바뀌는지만 확인한다.

### 설정 변경

- Serve는 `http://127.0.0.1:3900`을 대상 backend로 사용한다.
- Funnel은 인증 초기화, 활성 관리자 존재, localhost bind, 인증 guard self-check를 모두 통과해야 켤 수 있다.
- Funnel 전환은 관리자 비밀번호를 다시 확인한다.
- 원격 모드를 켜면 Marina의 persisted dashboard bind를 `localhost`로 변경하고 supervisor를 재기동한다.
- 재기동 요청은 먼저 desired state를 저장한 뒤 detached helper가 수행하며, UI는 health endpoint로 복구를 확인한다.
- Tailscale 명령이 사용자 동의를 요구하면 URL을 설정 화면에 표시하고 설정을 `action_required`로 유지한다.

Serve/Funnel 설정은 노드 전체 자원이다. Marina는 기존 Tailscale 설정이 비어 있거나 Marina가 저장한 fingerprint와
일치할 때만 변경한다. 다른 서비스의 Serve/Funnel route가 있으면 덮어쓰거나 `reset`하지 않고 충돌로 표시한다.
Marina가 만든 설정을 끌 때도 생성 당시의 정확한 listener/path/target만 해제한다.

## 설정 화면

기존 우측 상단 설정 패널에 `원격 접근`과 `사용자 관리` 진입점을 둔다.

원격 접근 화면은 다음을 제공한다.

- 현재 모드, 실제 HTTPS 주소, 주소 복사·열기
- Tailscale, HTTPS, daemon, proxy, Marina auth 상태
- `Serve로 열기`, `Funnel로 공개`, `원격 끄기`
- 관리자 계정 초기화 또는 비밀번호 재확인
- 활성 세션 전체 폐기
- 설정 실패 원인과 복구 동작

사용자 관리 화면은 계정 생성, 프로젝트 할당, 승인·거절, 비활성화, 비밀번호 초기화, 리소스 재할당을 제공한다.
Funnel은 준비 조건이 충족되기 전까지 비활성화하고 이유를 버튼 근처에 표시한다. 공개 중에는 전역 헤더에 작은
`PUBLIC` 상태를 표시한다.

CLI는 비상 복구와 자동화를 담당한다.

- `marina auth status|reset-admin|disable`
- `marina user list|add|approve|reject|disable|reset-password`
- `marina remote status|serve|funnel|off`

CLI의 변경 명령은 로컬 호스트에서만 실행하며 대시보드와 같은 SQLite 및 원격 상태 모듈을 사용한다.

## 감사 기록

초기 감사 로그는 다음 이벤트를 기록한다.

- 최초 설정, 로그인 성공·실패·잠금, 로그아웃
- 사용자 생성·승인·거절·비활성화·초기화
- 프로젝트 할당과 리소스 재할당
- 원격 모드 변경과 실패
- worktree 생성·삭제
- 서비스 lifecycle, 터미널 생성·종료, agent prompt 전송

터미널 키 입력, prompt 본문, 대화 내용, 서비스 로그는 감사 DB에 기록하지 않는다.

## 오류와 복구

- SQLite를 열 수 없으면 인증을 우회하지 않고 로그인 화면에 로컬 CLI 복구 안내를 표시한다.
- DB migration 실패 시 기존 파일을 수정하지 않고 대시보드를 read-only 복구 상태로 시작한다.
- 인증 활성 상태에서 DB가 손상되면 localhost도 자동 무인증으로 되돌리지 않는다.
- Tailscale 명령 실패는 기존 Serve/Funnel 설정과 dashboard bind를 유지한다.
- dashboard 재기동 후 health 확인이 실패하면 supervisor 로그와 `marina remote status` 복구 명령을 보여준다.
- 관리자는 로컬 CLI에서 세션 전체 폐기, 비밀번호 초기화, 원격 off를 수행할 수 있다.

## 구현 단위

### A. 인증 기반

SQLite schema, password/session service, bootstrap·claim·approve·login·logout API, 공통 auth middleware,
관리자 복구 CLI를 구현한다. 이 단계에서는 원격 공개와 리소스 필터링을 하지 않는다.

### B. 소유권과 관리 UI

기존 리소스를 관리자 소유로 가져오고 API 목록·변경 권한을 적용한다. 설정의 사용자 관리 화면과 감사 이벤트를
추가한다. desktop/mobile 회귀를 함께 검증한다.

### C. Serve

Tailscale 상태 모듈과 설정 UI를 추가하고 localhost bind 전환, Serve background 설정, 주소 표시와 복구를
검증한다. 이 단계가 개인 원격 사용의 첫 릴리스다.

### D. Funnel

인증 self-check, 관리자 재인증, 공개 상태 표시, Funnel 전환과 off 복구를 구현한다. 실제 공개 검증은 사용자가
명시적으로 승인한 테스트 시간에만 수행한다.

## 검증

- password hash·migration·세션 만료·폐기·rate limit의 Python 단위 테스트
- claim 경쟁, 관리자 승인, 마지막 관리자 보호, DB migration 실패 fixture
- 모든 기존 JSON API의 비인증 401과 역할·owner별 403/필터 계약 테스트
- 모바일 token 호환과 인증 활성 후 거부 테스트
- 가짜 `tailscale` CLI로 없음·offline·Serve·Funnel·동의 필요·충돌·실패 상태 테스트
- dashboard bind 재기동과 기존 Tailscale config 비파괴 테스트
- Aside에서 desktop·mobile 로그인, 관리자 설정, 사용자 승인, owner 격리 확인
- Serve 실제 HTTPS 접속과 재부팅 후 복구 확인
- Funnel은 auth guard 및 rate limit 자동 테스트 통과 후 제한된 시간에만 실제 접속 확인

## 비목표

- 공개 회원가입, 이메일, 초대 링크, 비밀번호 찾기 메일
- GitHub/Google OAuth, SSO, WebAuthn
- Tailnet 사용자를 Marina 사용자로 자동 매핑
- 사용자별 Unix 계정, 컨테이너, 파일시스템 보안 격리
- 팀원 간 worktree 공유와 세밀한 ACL
- Marina 데이터의 외부 DB 또는 클라우드 동기화
- Funnel을 대규모·고가용성 프로덕션 호스팅으로 사용하는 것
