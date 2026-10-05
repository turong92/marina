# 새 작업 버튼 — Discord 에서 워크트리 열기를 칸 하나로

2026-10-05 · 형 결정("세 칸 다 알아서 입력 못할 거 같은데" → 칸 하나)

## 무엇
- 각 개발 프로젝트 로비 채널(kind `dev-lobby`)에 봇이 **고정 패널 메시지** 하나: "🛠 새 작업 열기" 버튼(custom_id `marina-new:<project>`).
  - 로비가 만들어질 때 + 봇이 뜰 때 보장(없으면 올리고 pin, 있으면 그대로 — 메시지 ID 를 config/로비 기록에 저장). 같은 걸 두 번 올리지 않는다.
- 버튼 → 모달(칸 하나, 문단형, 필수, 1~500자): "뭐 할 거야?" placeholder "예) 결제 페이지 환불 버그 고치기 (dev 에서 시작하려면 'dev에서')".
- 제출 → 즉시 deferReply(ephemeral) → python `new-from-text --project <p> --user <id> --text <text>` (bot.ts 의 기존 execFile 방식) → 결과로 ephemeral 답 수정: "열었어: <채널 링크>" 또는 실패 이유.
- 허용 사용자만(기존 버튼들과 같은 사용자 검사).

## 이름 짓기 (python)
- slug(영문 소문자·숫자·하이픈, `_check_task` 통과): `claude -p --model haiku` 로 한 번(깨끗한 env — CLAUDE* 변수 제거, 20초 제한). 실패·형식 불일치면 `task-<MMDD>-<HHMM>`.
  같은 slug 의 워크트리/세션이 이미 있으면 `-2`, `-3` … 붙인다.
- title: 텍스트 첫 줄을 40자로(넘치면 …). Discord 채널 주제·제목으로.
- base: 텍스트에 `<브랜치>에서` 꼴(정규식, 존재하는 원격/로컬 브랜치일 때만)이 있으면 그것, 아니면 빈 값(기존 기본 = main).
- `cmd_new(project, slug, base, start=False, title=title)` 재사용.

## 첫 지시
- 새 채널에 봇이 "📝 형: <텍스트>" 메시지(allowed_mentions 없음)를 올린다 — 무엇으로 열었는지 보이게.
- 세션 첫 지시는 **argv 초기 프롬프트**로 준다(부팅 중 TUI 가 타이핑을 삼키는 문제 — 2026-09-10 메모). 내용:
  "[Discord 새 작업 버튼] 형이 이 작업으로 채널을 열었어: <텍스트>\n이걸 첫 지시로 받아 시작해. 진행·결과·질문은 이 채널 reply 로."
  claude_argv 에 초기 프롬프트 인자를 추가(없으면 기존 동작 그대로). cmd_new 에 `first` 인자로 전달.

## 경계·안전
- 텍스트는 argv 한 원소로만(셸 안 거침). Discord 표시용은 백틱·멘션 무력화.
- 데몬 python3.9 호환. 테스트는 lib/harness.sh + 가짜 Discord, `claude` 는 가짜 실행 파일로.

## 검증
- 단위: slug 정리·충돌 접미사·폴백, base 추출, 패널 보장(한 번만), new-from-text 가 cmd_new·첫 메시지·argv 프롬프트를 부르는지(가짜), 허용 안 된 사용자 거부.
- bot.ts: 버튼→모달→제출 흐름(기존 mqo/mqt 와 같은 패턴).
- 실측은 지휘 세션이 Discord 테스트 채널에서.
