# 2026-11-03 ChatGPT → Claude Code 인수인계

완료 상태: GOOGLE_CONNECTED_VERIFYING (실제 응답 검증 중)

2026-11-03 대표가 연결 주소의 나만 제한 해제를 승인. 웹 앱 접근을 모든 사용자로 변경 완료(응답은 코드에서 LMS is_admin/aal2 확인). Vercel preview·lms-test에 LMS_FORM_RESPONSES_URL 설정 완료. 운영 환경 변수는 변경하지 않음.

## 대표 최신 요청 · 이 문서가 기존 My hours 시각보다 우선
- 강사 My hours: `[도시 time] / [Korea time]`로 시간표 전체 전환, 00:00~23:30 전부 표시.
- 선택·저장 범위: **강사 현지 06:00 시작~22:30 시작**, 30분 간격. 한국 운영시간과 교집합으로 My hours 입력 칸을 줄이지 않음.
- 구글폼 신청서: **연도 → 월 → 날짜 → 학생 이름**. 같은 날 여러 건은 전부 이름과 제출 시각 표시. 제출일은 KST.
- 신청서 선택 즉시 기존 신규 등록 초안 자동 채움. 결제 방법·입금자명만 가져오며 결제 완료로 자동 처리하지 않음.
- 시험 확인은 **https://edge-english-git-lms-test-support-2126.vercel.app** 한 주소만. 개별 배포 URL 안내 금지.
- 운영은 기존 lms-prod 고정 주소. 배포는 git push만, Vercel 직접 deploy 금지. **이번 작업 운영 반영 승인 없음.**
- 운영 학생·수업·결제·Class Record 수정 없음. 임의 정책 변경 금지. 휴무 A안 유지.

## 저장·적용한 것
- 작업 브랜치 `lms-test`, GitHub `Edgeenglish/edge-english`.
- `TutorHours.tsx`, `src/lms/tutor/hours-view.ts`: 화면 시간대 전환. 원래 강사 현지 저장 키 유지, 한국 보기의 요일·날짜 이동 반영. 변경 확인/수업 상세의 현지 시각에는 도시 이름 표시.
- `supabase/migrations/20261103095424_tutor_hours_local_0600_2230.sql`: `lms_hours_times`만 변경. 시험 DB `kyeimjozkcqbgkepwrnv`에 적용 완료. **운영 DB 미적용.** 기존 가능 시간·수업 행 변경 없음.
- `supabase/tests/schema_test.sql` 기대값 갱신, `supabase/tests/tutor-hours-range.sql` 읽기 검증.
- `LoginFlow.tsx`: 로그인 페이지에서도 유효한 기존 세션을 이어 사용. persistSession/refresh 기존 설정 유지, MFA/RLS 완화 없음. 브라우저 저장소 삭제·다른 기기·서버 세션 만료 뒤 로그인은 필요.
- `ApplicationPicker.tsx`: 신청 연도·월·날짜 선택 후 같은 날 신청서를 학생 이름 버튼으로 전부 표시.
- `form-applications.ts`: 시트의 중복 열을 읽지 않고 실제 폼 질문 응답을 변환. 신형 체크박스 그리드는 정확한 시작 시각(`startOnly`)으로 전달. 기존 자유 서술 응답 보존.
- `registration.ts`·`booking.ts`·`parts.tsx`: 정확한 희망 시작 시각 지원. 기존 범위 기반 희망 시간 동작은 유지.
- `NewStudentLive.tsx`·`/api/lms/applications`: 관리자 인증 뒤 응답 읽기. 설정/연결 실패 시 오류를 알리고 직접 입력 유지. 신청서를 불러온다고 학생/등록/결제를 저장하지 않음.

## 실제 응답 연결: 접근 승인 완료, 검증 중
- Google 계정 **support@edgeenglish.kr**.
- 폼 ID `163rAf9Jn-bCxNN8Px38G2BgUTfK-AeixxIlTLedjXNs`.
- 실제 연결 응답 시트 `1D7YE4s2ZWBfQ97UvFS_Qnn_Qv46MfqVpiotIe-sPoOE`, 탭 `설문지 응답 시트1`.
- 기존 Apps Script 프로젝트: https://script.google.com/u/2/home/projects/1jgrAXPcfBXumrS5f7smbkFj8TmZi4ZC9mIQ71I1f0ElJD9d3UYMgxrS7/edit
- 기존 `Code.gs` 수정/실행하지 않음. **별도 `LmsApplications.gs` 추가·저장 완료**, 원본은 `apps-script/lms-applications/LmsApplications.gs`.
- 웹 앱 버전 1: 대표 2026-11-03 승인 후 모든 사용자 접근으로 변경 완료. 코드의 LMS 관리자/aal2 검사는 유지.
- 실행 주체 support@edgeenglish.kr. 서버가 접근할 엔드포인트는 Google 로그인 벽이 없어야 하지만, 스크립트가 매 호출마다 **허용된 두 Supabase 프로젝트의 `is_admin`(aal2 포함)**을 검증한 뒤에만 응답을 읽음. 미인증/학생/강사에게 응답 공개 금지.
- 장기 비밀키/서비스 역할 키 없음. 현재 세션 JWT를 Google의 해당 스크립트에 전달해 일회 검증. 토큰/응답을 로그·캐시·저장하지 않음. 폼 질문·응답·시트 수정 함수 없음.
- 현재 배포 URL: https://script.google.com/macros/s/AKfycbyB29_d6HXKxUBOxFyqKlEIeT594M-wI_6YYoQ_TmEGSfnA4FxexOkZxR-Na8rK0JKWdA/exec
- 승인 후 배포 관리에서 접근 허용을 변경하고 웹 앱 배포 URL(`/exec`)을 Vercel 프로젝트 `edge-english`의 **preview · gitBranch=lms-test** 환경 변수 `LMS_FORM_RESPONSES_URL`에 설정. 운영 환경 변수는 승인 전 추가하지 말 것.
- 이후 git push로 시험 배포. 신규 등록에서 실제 응답의 연도/월/날짜/동일 날짜 다건/자동 입력을 검증하되 **실제 학생 등록 저장은 누르지 말 것**.
- 새 API는 피드 미설정 시 "구글폼 연결 설정이 아직 완료되지 않았습니다" 표시. 이를 연동 완료로 보고하지 말 것.

## 검증 증거
- My hours 기존/시간대 테스트 9개 통과. 날짜·요일 경계, 미국/호주 DST 포함.
- 시험 DB에서 6개 지역/주 조합 모두 34칸, 첫 06:00/끝 22:30 확인.
- 시험 DB 트랜잭션 가상 강사로 06:00·22:30 저장/재조회 성공, 05:30·23:00 거부 확인 후 **전부 rollback**.
- 고정 시험 주소의 강사 화면에서 현지 06:00·22:30 실제 클릭 후 원래 상태로 되돌림. 한국 시간 전환 확인. 운영/시험의 실제 수업 저장 없음.
- 폼 변환/등록/배정/로그인 테스트 33개 통과 (My hours 포함 합계 42개). 연·월 경계를 KST로 구분, 정확한 시작 시각의 50분 수업 판정 포함.
- TypeScript 및 `next build --webpack` 통과. 기본 Turbopack은 격리 작업 디렉터리의 외부 node_modules 심볼릭 링크 때문에 실패했으며 코드 오류 아님.
- 고정 주소 /lms/login에서 기존 세션으로 이메일·인증번호 없이 /lms/admin 복귀를 실제 브라우저에서 확인.
- 실제 Google 응답→LMS 전체 흐름은 **새 git 배포 후 확인 대기**, 미검증.

## 이어서 할 순서
1. Google 접근 승인·웹 앱 설정·시험용 Vercel 변수 설정 완료. 중복 승인 요청하지 말 것.
2. 최신 GitHub HEAD 확인(다른 작업을 덮어쓰지 말 것), git push 자동 배포 READY 확인.
3. 같은 고정 주소의 유효 세션으로 /lms/login 방문 시 재인증 없이 복귀 확인, 폼 연도→월→날짜→이름 자동 채우기 확인, 모바일 확인. 저장 금지.
4. 증거를 적고 이 문서 상태를 DONE으로 변경. 승인 없이 운영 배포/운영 DB 적용하지 말 것.
5. 대표에게 완료 알림. 완료 감시 알림 작업은 한 번 알린 뒤 비활성화하도록 설정돼 있음.

개인정보 원본은 저장소에 기록하지 않음.
