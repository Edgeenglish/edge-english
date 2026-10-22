# 운영 Supabase 만들기 (edgeenglish-lms)

- 시험용 `edgeenglish-lms-test` 와 **완전히 따로** 만든다. 키·주소를 섞지 않는다.
- 운영 DB에는 **가상 데이터를 넣지 않는다.** 실제 학생 데이터 넣기(D-52 간단 입력)는 다음 단계, 대표 승인 후.
- Claude는 운영 프로젝트의 **Secret key·DB 비밀번호를 받지 않는다.** 표 만들기·변경은 대표가 SQL Editor에서 실행 (A32와 같은 방식).
- 대표 안내는 **복사 버튼 페이지**로 (2026-10-22 합의). 페이지: 아래 '복사 버튼 페이지' 참고.

## 0. 먼저 정할 것 (대표) — D-6 요금제

2026-10-22 확인한 내용 (Supabase 공식 문서·요금 페이지 검색 결과. Claude 작업 환경에서 supabase.com 직접 열기는 막혀 있어 검색 요약으로 확인 → 결제 전 대표가 요금 페이지에서 한 번 더 확인):

| | Free ($0) | Pro ($25/월) |
|---|---|---|
| 일시정지 | **1주 동안 사용이 없으면 일시정지** (데이터는 남고 버튼으로 다시 켬). 매일 쓰면 해당 없음 | 없음 |
| 자동 백업 | 공식 문서: 모든 요금제를 매일 백업한다고 하지만 **Free의 보관 기간·복원 방법은 적혀 있지 않고**, Free는 직접 내보내기(db dump)로 따로 보관하라고 권장 | **매일 백업 7일 보관**, 대시보드에서 복원 |
| 프로젝트 수 | 무료 프로젝트 2개까지 → 시험용 + 운영 = 2개로 **한도가 꽉 참** | 조직 단위 요금. $10 컴퓨트 크레딧은 **조직 전체에 1개** (작은 프로젝트 1개분) |
| 용량 | DB 500MB (학생 수백 명 규모까지 충분) | DB 8GB |

- **Pro로 할 때 주의**: 시험용과 같은 조직(EdgeEnglish)을 Pro로 올리면 시험용 프로젝트도 유료 컴퓨트가 붙어 약 $10/월이 더 나올 수 있다. → **운영용 조직을 새로 만들어(예: `EdgeEnglish LMS`) 그 조직만 Pro**로, 시험용은 지금 무료 조직에 그대로 두는 방식을 추천.
- **Claude 의견 (객관)**: 실제 학생 데이터(이름·연락처·결제·수업 횟수)를 넣는 DB이므로 **Pro(운영용 조직만) 추천** — 기존 D-6 추천과 같다. 근거: Free는 자동 백업을 대표가 직접 꺼내거나 복원할 수 있다는 보장이 문서에 없고, 일시정지 위험이 있다. Free로 시작해도 아래 '직접 백업'으로 데이터 손실은 막을 수 있지만, 백업을 사람이 매번 챙겨야 한다.
- Free로 시작하면: 매주 1회 + DB 변경 직전 '직접 백업'을 반드시 받고, 학생 데이터가 늘거나 1주 이상 안 쓸 일이 생기기 전에 Pro로 올린다 (프로젝트를 다시 만들 필요 없이 조직 요금제만 변경).
- Vercel 요금제(Hobby는 상업용 불가)는 D-6의 다른 절반 — 운영 사이트에 LMS를 연결하는 단계에서 다시 확인.

## 1. 순서 (대표, PC 권장, 약 20분)

| 순서 | 어디서 | 하는 것 | 정상 결과 |
|---|---|---|---|
| 1 | supabase.com | (Pro면) 새 조직 `EdgeEnglish LMS` 만들고 Pro 선택 → New project: 이름 `edgeenglish-lms`, 지역 **Northeast Asia (Seoul)**, DB 비밀번호는 **Generate** 로 만들어 대표 비밀번호 관리 앱에만 저장 (Claude에게 주지 않음). Data API 켜 둠 | 프로젝트 생성 (2~3분) |
| 2 | SQL Editor | `prod-setup/00-empty-check.sql` | 표_개수 **0** (41이면 시험용에 들어온 것 — 멈춤) |
| 3 | SQL Editor | `prod-setup/01-schema.sql` (마이그레이션 000~1000 묶음, 가상 데이터 없음) | Success. No rows returned |
| 4 | SQL Editor | `prod-setup/02-check.sql` (읽기만) | 7줄 모두 **통과** |
| 5 | Authentication | 공개 가입 끄기, 이메일 확인 켬, OTP 6자리·600초, MFA(TOTP) 켬 | 시험용과 같은 설정 |
| 6 | Resend → Supabase | Resend에서 **운영용 API key `supabase-prod`** 새로 만들기(Sending access, 도메인 edgeenglish.kr) → Supabase SMTP: `smtp.resend.com` 465, 사용자 `resend`, 비밀번호 = 그 키, 보낸 사람 `엣지영어 <support@edgeenglish.kr>` | 저장됨 (키는 Supabase 화면에만) |
| 7 | Email Templates | 시험용 프로젝트의 **Magic Link** 제목·본문을 그대로 복사해 붙여 넣기 (6자리 코드 한국어 문구) | 저장됨 |
| 8 | Authentication → Users | Add user → Create new user: `support@edgeenglish.kr`, 비밀번호는 아무 긴 값(쓰지 않음), **Auto Confirm User 체크** (Send invitation은 쓰지 않음 — 공개 가입을 끄면 초대 계정은 로그인 안 됨, 2026-10-17 확인) | 사용자 1명 |
| 9 | SQL Editor | `prod-setup/03-owner.sql` | `support@edgeenglish.kr · admin · owner` 한 줄 |
| 10 | Database → Backups | 화면에 무엇이 보이는지 캡처 (Free 백업 범위 실제 확인) | — |
| 11 | Project Settings → Data API | Project URL의 주소 부분(`xxxx.supabase.co`)만 Claude에게 (비밀 아님) | — |

- 3번은 한 묶음 실행이라 오류가 나면 아무것도 만들어지지 않는다. 오류 첫 줄만 Claude에게.
- 3번을 두 번 실행하면 "멈춤: public 에 이미 표가 있습니다" — 정상(이미 만들어진 것).
- 운영 사이트(Vercel) 연결, 실제 로그인 시험, 학생 데이터 입력은 **이 단계에 포함하지 않음** → 각각 다음 단계에서 승인 후.

로컬 검증 (2026-10-22, Claude): `npm run test:db` 에서 빈 DB에 2~4·9번 파일을 같은 순서로 실행 → 확인 7줄 통과, 3번 두 번째 실행은 안전장치로 멈춤, 9번 두 번 실행해도 1줄.

## 2. 운영 DB 변경 절차 (앞으로 매번)

1. Claude가 **바꿀 내용**(무엇이 바뀌고 무엇이 그대로인지)을 먼저 보여 줌 → 대표 승인
2. 로컬 검증 (`npm run test:db`)
3. 시험용 DB 적용·확인
4. 운영 DB: **① 직접 백업** → ② 적용 → ③ 확인
   - ① `supabase/backup/backup.sql` 실행 → 결과 표 [Export] → [Download CSV] → 파일 이름 앞에 날짜(예: `2026-10-25_적용전_lms-backup.csv`) → 구글 드라이브(support@) **'LMS 백업'** 폴더
   - 백업 파일에는 실제 개인정보가 들어 있다 → **채팅·GitHub에 올리지 않는다.** 복구가 필요할 때만 Claude 작업 환경에 올림

### 직접 백업·복구 (`supabase/backup/backup.sql`, `scripts/lms-restore-sql.mjs`)

- 백업: 읽기만 하는 SQL. 표마다 한 줄(행 수·내용 JSON) + 백업 시각 + 번호 순서(학생 번호 등) + 로그인 계정 번호·이메일. 임시 함수(`pg_temp`)를 써서 DB에 아무것도 남기지 않음
- 복구: Claude가 CSV로 복구 SQL을 만든다 → 대표 승인 → SQL Editor 실행. 한 묶음(오류면 전체 취소). 표 41개 확인 → 트리거·참조 제약 잠시 끔 → 내용 교체 → 다시 켜며 참조 전체 검사 → 번호 순서 복원 → 표별 행 수 '같음/다름' 표
- 로컬 검증: `npm run test:db` 에서 가상 데이터 DB 백업 → 운영형 빈 DB에 복구 → 다시 백업해 **표 41개 내용이 같음**, 복구 뒤 변경 이력 삭제 금지 등 보호 장치가 다시 켜짐 확인
- 남은 것: **시험용 DB에서 실물 연습 1회** (Supabase SQL Editor의 CSV 내보내기 형식 확인 — 시험용은 가상 데이터라 파일을 Claude에게 올려도 됨). 새 프로젝트로 옮기는 복구는 로그인 계정 번호가 달라져 `app_users` 재연결이 필요 (그때 이메일로 다시 연결)

## 3. 알려진 점

- btree_gist 확장이 public에 있다는 Security Advisor 경고가 나올 수 있음 — 데이터 접근 없음. 시험용과 운영용 스키마를 같게 두기 위해 이번에는 그대로 두고, 옮길 때는 마이그레이션으로 시험용 → 운영 순서로
- 공휴일(`holidays`) 표는 비어 있음 — 변경권 면제(D-4: 법정·대체·임시공휴일) 기능을 쓰기 전에 목록 입력 필요
- 학생 번호는 STU-0001부터. 기존 학생 번호를 이어 쓰려면 데이터 넣기(D-52) 때 결정

## 복사 버튼 페이지

- 운영 DB 만들기: https://claude.ai/artifact/Y9aAahy2YVz8ukXdFtWStd (`node scripts/lms-prod-page.mjs` 로 다시 만들고 같은 주소에 다시 발행)
