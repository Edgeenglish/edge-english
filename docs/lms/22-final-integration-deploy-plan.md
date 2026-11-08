# lms-test → 운영 최종 통합 배포 준비 (2026-11-08 작성, 실행 전 — 대표 승인 대기)

확인한 것(11/8, 읽기만): 저장소 브랜치 전체 · 운영 DB(mfamixejxydodclhglbc)·시험 DB(kyeimjozkcqbgkepwrnv) migration 기록 · 예약 작업 3개. DB·코드는 아무것도 안 바꿈.

## 1. 지금 위치

| | 코드 | DB |
|---|---|---|
| 시험 | lms-test `8b2a6bd` (11/8 21:03 KST) | 11/8 것까지 모두 적용 |
| 운영 | lms-prod `071e897` (cherry-pick 줄) | 아래 5개 빠짐 |

- lms-test 가 lms-prod 보다 커밋 59개 앞. lms-prod 에만 있는 커밋 1개(071e897)는 내용이 lms-test 에 이미 있음(그 뒤 더 고쳐짐).
- lms-test 에 lms-prod 를 합쳐 보면 묶음 SQL 2곳(`schema_all.sql`·`schema_test.sql`)만 충돌 → **lms-test 쪽 내용으로 통일**하면 됨.

## 2. 운영 대기 항목 (빠짐없이)

### DB migration — 운영에 없음 (순서대로)
| 순서 | 파일 | 내용 | 비고 |
|---|---|---|---|
| ① | 20261108020000_lms_fault_extension | 강사 귀책 자동 연장 H26(90)(92)(93) | **적용한 날 = 시행일**(feature_flags `tutor_fault_extension_since`) |
| ② | 20261108030000_lms_leave_extension_no_shrink | 휴무 보강 취소해도 종료일 안 줄임 | ① 뒤 |
| ③ | 20261108040000_lms_student_regular_slots | 학생 홈 '수업 시간' | 단독 가능 |
| ④ | 20261108120000_lms_mail_no_noshow_word | 학생 메일 '노쇼' 표현 제거 + 보상수업 칸 이름 버그 | ⑤ 앞 |
| ⑤ | 20261108130000_lms_admin_makeup_reason_reschedule | 운영진 바로 확정 사유·보강 시간 고치기·운영 기록 | 시험 DB 엔 4번 나눠 적용됨 → **운영 적용 뒤 함수 본문을 시험 DB 와 해시 대조** |

- 함수 겹침 확인: ①~⑤ 는 운영에 이미 적용된 재등록 4개(050000~080000)의 함수를 덮어쓰지 않음. ⑤ 가 `lms_makeup_conflict` 6칸판을 만들지만 5칸판을 그대로 두므로 `admin_carry_over_makeups`(운영 적용분)도 그대로 동작.
- handoff '🕐 12시간 표기' 절의 운영 순서 '20261108120000 → 코드'는 **20261108130000 이 맞음**(120000 은 링크 작업 것). 위 표대로 둘 다 적용.

### 코드 — lms-prod 에 없음 (lms-test 전체를 내보내면 함께 나감)
- 강사 귀책 자동 연장 화면 · [맞는 시간이 없어요] · 운영진 '예외 연장 검토' 카드
- 학생 화면 시간대 통일(거주지 시간만, 운영자만 KST 전환·주황 띠) · 12시간 표기
- 학생 홈 수업 시간 · 운영진 종료일 연장 창 정리(ace4f24)
- 보강 날짜 고르기 바로가기 링크 + 로그인 뒤 원래 화면 · 취소 안내 톡 신청 안내 줄 · [보강 링크 복사]
- 운영진 보강 바로 확정 사유·시간 고치기·운영 기록 카드

### 저장소 정리 — 배포 전에 꼭
- **재등록·이월·적립금 migration 4개가 운영·시험 DB 엔 있는데 lms-test 저장소엔 없음** (`claude/amazing-mendel-vxc5q4` 에만 있음): 050000·060000·070000·080000 + CLAUDE.md 이름 O 처리 규칙. → lms-test 에 합친 뒤 배포(파일만, DB 재적용 안 함).
- handoff 가 4개 브랜치에 따로 적혀 있음(eloquent-carson 3줄, laughing-archimedes 1줄, amazing-mendel 1절) → lms-test handoff 하나로 합침.

## 3. 배포 순서 (승인 뒤, 한 번에)

0. 사전: 저장소 정리(위) → lms-test 에서 tsc·eslint·vitest·test:db 다시 돌림
1. **운영 DB 백업** `lms_backup.snapshots` 새 번호(지금 마지막 22, 그 뒤 데이터 바뀜) + 바뀔 함수 본문 저장(되돌릴 때 씀)
2. migration ①→②→③→④→⑤ (저장소 파일 그대로)
3. 확인: 바뀐 함수 본문 해시 = 시험 DB · 학생·수업·보강·보상·변경권 건수 백업과 같음 · 학생/강사 신분 권한 경계 · `tutor_fault_extension_since` 날짜
4. **코드**: lms-prod 를 lms-test 내용으로 맞춤(합침 커밋, 충돌 2곳은 lms-test 쪽) → push → Vercel 배포
5. 운영 화면 확인: 학생(?demo=1 PC·휴대폰) · 강사 · 운영자 TOTP(KST 띠·예외 연장 검토·보강 링크 복사·바로 확정)
6. handoff·H26 기록

## 4. 되돌리기

| 문제 | 되돌리는 법 |
|---|---|
| 코드 | 배포 전에 `lms-prod-before-final` 태그(071e897) → 그 커밋으로 되돌려 push, 또는 Vercel 이전 배포로 Promote |
| DB 함수 | 1단계에서 저장한 함수 본문으로 다시 만듦 |
| DB 데이터 | snapshots 새 번호에서 복구 |
| 자동 연장 | 시행일 줄(feature_flags) 기준이라 적용 직후엔 연장된 학생 0 — 문제 시 그 줄 날짜로 판단 |

## 5. 대표 결정이 필요한 것
1. 배포 방식: **lms-prod = lms-test 전체** (추천 — cherry-pick 은 StudentHome 겹침으로 따로 얹기 어려움)
2. **배포 날짜·시각** — 자동 연장 시행일이 이 날로 정해짐 (Claude 가 정하지 않음)
3. 이관 휴무 보강이 종료일 뒤 날짜도 고를 수 있는데 안내 문구 넣을지 (QA ④)
4. 미검증 화면: 운영자 TOTP 화면 4곳 — 대표가 시험 주소에서 볼지, 운영 배포 직후 볼지
