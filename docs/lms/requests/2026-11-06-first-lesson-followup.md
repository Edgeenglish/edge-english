# 첫 수업 후 강사 프로필·To-do 구현 요청 (2026-11-06 대표, 정책 원본 H26(67)·(68)·(71))

시안(대표 제공, 그대로 구현): `2026-11-06-first-lesson-followup-pc-v2.html` · `2026-11-06-first-lesson-followup-mobile-v2.html`
기존 화면에 덧붙이지 말고 시안의 레이아웃·입력 순서·버튼·완료 상태·접기/펼치기 동작을 최대한 그대로 반영.

## 1. 먼저 기존 작업 확인
- 시험 브랜치 `lms-test`, 작업 브랜치 `claude/qa-ux-report-reflection-lg5x4i`, 최근 A-01·A-03 수정·시험 DB migration 20261107000000, 정책 원본 H26(66)~(72), 최신 handoff. A-01·A-03 유지, 기존 정상 기능 훼손 금지.

## 2. 첫 수업 후 강사 To-do
첫 수업이 Held 로 기록되면 강사 Home 에 학생별 First Lesson Follow-up 할 일 표시. 체크박스 나열이 아니라 번호와 실제 입력칸을 직접 연결.
1. English Level — 강사가 첫 수업 후 평가, 실제 레벨 저장 후 자동 완료
2. Wants to Improve — 강사가 학생에게 직접 물어보고 기록, 저장 후 자동 완료
3. Class Style — 학생의 기존 희망을 초기 정보로 보여 주기, 강사가 확인하거나 수정, 저장/확인 완료 시 자동 완료
4. Class Record — 실제 첫 수업 기록이 저장되면 자동 완료, 이미 작성했다면 다시 작성하게 하지 않기
- Textbook 은 Class Style 에 따라 조건부로 나타나는 입력 항목. 완료 상태는 체크박스 클릭이 아니라 실제 DB 저장 정보로 자동 반영.

## 3. Class Style 통일
- 기존 `Type of Class` 표시는 Class Style 로 통일. 옵션: Conversation / Textbook-based / Student-provided Materials / Mixed
- Textbook-based: 엣지영어 웹사이트의 실제 교재 목록에서 선택 (임의 목록 금지). Student-provided Materials: 자료 이름·종류 선택적 기록. Mixed: Conversation / Textbook / Student-provided Materials / Other 복수 선택, Textbook 포함 때만 교재 선택 표시. 교재는 나중에도 변경 가능.

## 4. 학생의 원래 답변 보존
- 운영진이 첫 수업 전 카톡 한국어 답변을 ChatGPT 번역 후 기존 ABOUT & PREFERENCES · STUDENT'S ANSWERS 에 입력(계속 수동).
- Job / Hobbies / Interests / Corrections / Hopes for Class: 운영진 사전 입력 · Wants to Improve: 강사가 첫 수업에서 직접 질문·기록 · 학생 희망 Class Style: 운영진 사전 입력 · 실제 Class Style: 강사가 첫 수업 후 확인·수정
- 강사가 Class Style 을 수정해도 학생 원래 답변은 절대 덮어쓰지 않음. 학생 사전 답변을 별도 중복 입력칸으로 다시 만들지 않음.

## 5. PC·모바일 UI
- PC: 시안처럼 학생 기존 정보와 강사 입력 영역 분리. 모바일: 번호별 입력 세로 배치, 기존 학생 정보는 필요할 때 펼쳐 보기.
- 확인: 번호 누르면 해당 입력 영역으로 이동/열림 · 입력·저장 후 완료 상태 즉시 갱신 · 필요한 항목 '입력 필요' · 완료 항목 자동 완료 표시 · 교재 안 쓰면 교재 입력 불필요 · 화면 나갔다 돌아와도 저장 상태 유지 · 모바일 글자 잘림·가로 스크롤·버튼 겹침 없음
- 시안 디자인을 LMS 색상·폰트와 조화, 구조를 임의로 복잡하게 바꾸지 않음.

## 6. 기존 데이터·권한 보호
- 기존 학생 프로필·Class Record 데이터 보존, 학생·강사·운영진 권한 유지, 수업 시작 전에는 미완료 To-do 표시 안 함, 첫 수업 후 필요한 항목만, 완료된 To-do 반복 생성 금지, 운영진이 입력한 학생 답변을 강사 수정 과정에서 덮어쓰지 않기.

## 7. 실제 검증 (시험 사이트·시험 DB, 실제 브라우저 클릭·저장·DB 대조)
1 첫 수업 전 학생 프로필 · 2 첫 수업 Held 저장 · 3 강사 Home To-do 생성 · 4 English Level 저장 · 5 Wants to Improve 저장 · 6 Class Style 확인·변경·Mixed · 7 교재 선택 · 8 Class Record 자동 완료 · 9 PC·모바일 저장·새로고침 · 10 학생 사전 답변 원본 보존

## 8. 완료 보고
구현 완료 항목 · PC·모바일 캡처 · 실제 저장 검증 결과 · 기존 데이터·정책 영향 · 최신 커밋·시험 배포 상태 · 남은 오류·미검증 항목.
시험 DB·lms-test 에서만. 운영 DB·운영 사이트·lms-prod 는 대표 별도 승인 전 변경 금지.
