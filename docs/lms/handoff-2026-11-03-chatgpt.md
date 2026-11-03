# 2026-11-03 ChatGPT → Claude Code 인수인계

완료 상태: DONE

범위: 아래 기능의 **시험용 구현·실제 클릭 검증 완료**. 운영 반영 승인은 아직 없음.

## 대표 최신 결정
- My hours는 `[도시 time] / [Korea time]`로 시간표 전체 전환, 00:00~23:30 모두 표시.
- 선택·저장 범위는 **강사 현지 06:00 시작~22:30 시작**, 30분 간격. 한국 운영시간과 교집합으로 My hours 입력 칸을 줄이지 않음. 기존 수업/보강/휴무 잠금은 유지.
- 신규 등록 구글폼 선택 순서: **연도 → 월 → 날짜 → 학생 이름**. 같은 날짜 신청서는 이름별로 모두 표시. 제출일·시각은 KST.
- 신청서 선택 즉시 기존 등록 초안 자동 채움. 결제 방법/입금자명은 채우되 결제 완료로 자동 처리하지 않음. 학생/수강권/일정 저장은 기존 최종 저장 절차 그대로.
- 시험 고정 주소: **https://edge-english-git-lms-test-support-2126.vercel.app**. 개별 배포 URL을 사용자에게 안내하지 말 것.
- 같은 주소의 유효한 로그인 세션은 재사용. 로그아웃·기기 변경·브라우저 저장소 삭제·서버 세션 만료 뒤 재인증은 필요. MFA/RLS는 약화하지 않음.
- 모든 LMS 배포는 **git push**로만. Vercel 직접 deploy 금지. 이번 변경을 운영 DB/운영 브랜치에 적용하는 것은 별도 승인 필요.

## 적용 위치
- 저장소: `Edgeenglish/edge-english`, 브랜치 `lms-test`.
- 시험 DB `kyeimjozkcqbgkepwrnv`: `supabase/migrations/20261103095424_tutor_hours_local_0600_2230.sql` 적용 완료. `lms_hours_times`가 읽기와 저장 모두에 같은 06:00~22:30 범위를 공급.
- **운영 DB `mfamixejxydodclhglbc`에는 이번 변경 미적용.** 운영 학생·수업·결제·Class Record 변경 없음.
- My hours: `TutorHours.tsx`, `src/lms/tutor/hours-view.ts`. 한국 보기에서 현지 요일/날짜 키로 변환하여 기존 저장 동작 유지. 범위 밖/읽어오지 않은 날짜를 열린 시간으로 추정하지 않음.
- 로그인: `LoginFlow.tsx`. 로그인 페이지를 방문해도 유효한 세션이 있으면 기존 역할 화면으로 복귀.
- 신청서: `ApplicationPicker.tsx`, `NewStudent.tsx`, `NewStudentLive.tsx`, `src/lms/admin/form-applications.ts`.
- Google Forms 질문 응답 자체를 읽음. 시트에는 중복 시간표 열/폐기 열이 있으므로 시트 열 위치로 매핑하지 말 것.
- `registration.ts`, `booking.ts`, `parts.tsx`의 `startOnly`는 체크박스 그리드의 **정확한 희망 시작 시각**을 뜻함. 기존 범위형 희망 시간은 기존 동작 유지.
- 서버 `/api/lms/applications`: 사용자 JWT로 `is_admin`(aal2 포함)을 확인한 뒤 Google 연결을 호출. 응답은 private/no-store. 오류 때 직접 입력은 유지. 서버 응답 대기 60초는 통신 설정이며 업무 정책 변경 아님.

## Google 연결: 승인·연결 완료
- 계정: **support@edgeenglish.kr**.
- 폼 ID: `163rAf9Jn-bCxNN8Px38G2BgUTfK-AeixxIlTLedjXNs`.
- 응답 시트: `1D7YE4s2ZWBfQ97UvFS_Qnn_Qv46MfqVpiotIe-sPoOE`, `설문지 응답 시트1`.
- Apps Script 프로젝트: https://script.google.com/u/2/home/projects/1jgrAXPcfBXumrS5f7smbkFj8TmZi4ZC9mIQ71I1f0ElJD9d3UYMgxrS7/edit
- 기존 `Code.gs` 수정/실행 없음. 별도 `LmsApplications.gs` 추가. 저장소 원본 `apps-script/lms-applications/LmsApplications.gs`.
- 대표 승인으로 연결 주소의 나만 접근 제한 해제 완료. 추가로 **외부 서비스에 연결**(`script.external_request`) 권한도 대표 승인 후 Google 승인 성공 화면 확인.
- **웹 앱 버전 2**, 같은 배포 ID/주소로 갱신 완료:
  https://script.google.com/macros/s/AKfycbyB29_d6HXKxUBOxFyqKlEIeT594M-wI_6YYoQ_TmEGSfnA4FxexOkZxR-Na8rK0JKWdA/exec
- Vercel `edge-english`: `LMS_FORM_RESPONSES_URL`은 **preview · gitBranch=lms-test**에만 설정. 운영 환경 변수 미설정.
- Google 접근은 모든 사용자로 되어 있어도 코드가 허용된 두 Supabase 프로젝트의 `is_admin`을 매 호출 검사한 뒤에만 응답 반환. GET은 `POST required`, 인증 없는 POST는 `Unauthorized` 확인.
- 서비스 역할 키/장기 토큰 없음. 현재 사용자 JWT는 인증 확인에만 쓰고 로그/캐시/저장하지 않음. 질문 메타데이터는 한 번만 읽어 응답마다 반복 조회하지 않음.
- 진단 함수 `lmsApplicationsCheck`는 개인정보 없이 응답 개수·통신 상태만 기록. 기존 폼 수정용 미리보기/적용 함수 실행 금지.
- **구글폼 질문·설명·선택지·응답·응답 시트는 이번 작업에서 수정하지 않음.**

## 검증 완료 증거
- 시간대/기존 My hours 테스트 9개 포함, 등록·폼 변환·배정·로그인 **42개 테스트 통과**. TypeScript 및 `next build --webpack` 통과.
- 시험 DB의 6개 지역/주 조합에서 34칸, 첫 06:00/끝 22:30 확인.
- 가상 강사 트랜잭션에서 06:00·22:30 저장/재조회 성공, 05:30·23:00 거부 후 **전체 rollback**.
- 고정 시험 주소 강사 화면에서 06:00·22:30 칸 실제 클릭 후 원래 상태로 되돌림. 한국 시간 전환 확인. 실제 수업 저장 없음.
- 같은 고정 주소 `/lms/login`에서 이메일/인증번호 입력 없이 기존 세션으로 `/lms/admin` 복귀 확인.
- 실제 Google 응답으로 **2025/2026 연도 목록 조회**, 월/날짜 선택 확인. 2026년 10월 31일 신청서를 클릭해 이름·이메일 자동 입력 확인.
- **2026년 6월 10일의 서로 다른 신청서 2건**을 모두 표시하고 각각 클릭, 선택한 학생 이름과 입력된 이름이 일치함을 두 건 모두 확인. 실제 이름/연락처는 기록하지 않음.
- 390px 모바일 폭에서 신청서 연도·월·날짜 및 버튼들이 가로 화면 안에 들어옴을 확인.
- 실제 학생의 등록/결제/일정 최종 저장은 누르지 않음. 원본 폼/시트 변경 없음.
- 현재 원본에는 2026년 11월 제출 건이 없어 실제 목록에 11월이 없음. 가상 화면에서는 10월·11월 분류를 확인함. 없는 응답/날짜를 만들지 말 것.

## 다음 담당자 주의
- 시험용 신규 등록: https://edge-english-git-lms-test-support-2126.vercel.app/lms/admin/students/new
- 운영에 반영하려면 별도 승인 후 DB 함수 변경과 `lms-prod` git 배포 및 운영용 연결 변수 설정이 필요. 시험 성공을 운영 반영으로 보고하지 말 것.
- 개인정보 원본·토큰은 저장소에 기록하지 않음. 휴무 A안 등 기존 결정 유지.
