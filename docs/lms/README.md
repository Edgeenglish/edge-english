# 엣지영어 LMS 문서 (Claude가 작업 전에 먼저 읽는 곳)

웹앱 + Supabase(PostgreSQL) 기반 LMS. 원본 기획서(2026-10-11)를 실제 운영정책과 대조해 고친 v2와 실행 계획.

**새 채팅에서는 [`../lms-plan.md`](../lms-plan.md)(인수인계 문서)를 먼저 읽는다.** 기획서 원문 글자본: [`../lms-기획서-원문.md`](../lms-기획서-원문.md)

**정책 결정의 원본은 대표의 Google Docs 정책 원본(v1.0, `policy/sources.md` SRC-POLICY-V1)이다.** 조항별 대조는 [`policy/official-source.md`](policy/official-source.md). 실제 운영 데이터의 원본은 Supabase다.

**개발 기준: 운영정책은 [`policy/register.md`](policy/register.md)(정책 기준표 — 정책 원본의 개발용 사본)를 따른다.** 계약서·FAQ·안내문·시트·코드가 서로 다르면 기준표에서 먼저 정리하고, 바꿀 때는 [`policy/process.md`](policy/process.md) 절차를 따른다.

| 정책 관리 | 내용 |
|---|---|
| [policy/official-source.md](policy/official-source.md) | **정책 원본 v1.0 대조표** (대표확정·개발요구·추가확인·보류 구분, 기존 계약과의 관계) |
| [policy/register.md](policy/register.md) | **운영정책 기준표** 92개 (확정·검토 중·변경 제안·폐지, 근거, 기존/신규 차이, 고칠 곳) |
| [policy/critical-policies.md](policy/critical-policies.md) | **핵심 정책 27개 검토표** (횟수·변경권·보강·이월·급여, 판본별 적용 대상·실제 승인 여부) |
| [policy/contract-version-check.md](policy/contract-version-check.md) | 구계약 적용 학생·강사 확인 방법 (서명·발송·동의 구분, 계약서/안내서만/계약 후 안내서만 유형, 이름 없는 집계) |
| [policy/conflicts.md](policy/conflicts.md) | **정책 충돌 목록** 27건 (횟수·돈·계약 우선) |
| [policy/guide-versions-in-sheets.md](policy/guide-versions-in-sheets.md) | 학생 시트 속 안내서 판 확인 결과 (5가지 판, 이름 없이 건수만) |
| [policy/guide-2026-07-09-review.md](policy/guide-2026-07-09-review.md) | 수업 전 필독안내서(2장 세트) 원문과 계약서·FAQ·기획서 항목별 대조, 학생 유형별 영향 |
| [policy/sources.md](policy/sources.md) | 근거 문서·버전 목록 (계약서 판본, 안내문, 시트) |
| [policy/process.md](policy/process.md) | 정책 변경 절차, 영향 체크리스트, 점검 시점 |

| 문서 | 내용 |
|---|---|
| [01-current-state.md](01-current-state.md) | 지금 실제로 있는 것 (코드·시트 직접 확인), 완료/일부/미구현 |
| [02-plan-v2.md](02-plan-v2.md) | **수정된 최종 기획서** (원본 목차 유지, 변경·추가·미결 표시) |
| [03-changelog.md](03-changelog.md) | 원본 대비 바뀐 점과 이유 |
| [04-policy-review.md](04-policy-review.md) | 기획서 ↔ FAQ·계약서·급여정책·시트 대조 결과 |
| [05-architecture.md](05-architecture.md) | 기술 구조, DB, 권한, 캘린더, 이관, 보안, 비용 |
| [06-roadmap.md](06-roadmap.md) | 개발 순서, 단계별 완료 조건 |
| [07-decisions.md](07-decisions.md) | **대표 결정 필요 사항** (2차, 추천안 포함) — 결정되면 여기 기록 |
| [08-legacy-automation-analysis.md](08-legacy-automation-analysis.md) | Master·이지은·Cindy 샘플 자동화 분석 (구현/중단/수동/제거 대상) |
| [10-terms-consent-design.md](10-terms-consent-design.md) | **수업 안내 확인·동의 기능 설계** (흐름, 기록 항목, 판 관리, 카톡 발송 검토, 법률 미확인 목록) |
| [11-accounts-auth-payments.md](11-accounts-auth-payments.md) | 계정·인증(운영자 초대 → 장래 공개 가입, 운영자 TOTP)·결제 확인 분담·보강 리마인더 설계. 공식 홈페이지 통합 기반 원칙 |
| [12-dashboard-reference-review.md](12-dashboard-reference-review.md) | 대표 참고 이미지 2장(학생·운영자)에서 쓸 요소만 고른 검토 |
| [13-refund-proposal.md](13-refund-proposal.md) | **환불 기준 최종안(제안)** — 적용 법령, 산식, 사은품·위약금 공제 기준, 기존 규정 충돌, FAQ·계약서 문구 초안, 법률 확인 목록 |
| [09-design-review.md](09-design-review.md) | 기존 시트 구조 vs 새 구조 연결표, 입력 주체, SQL v0.2 재검토, 대안 비교 |
| [supabase-test-setup.md](supabase-test-setup.md) | **시험용 Supabase 연결 안내** (SQL Editor 적용 → 접속 허용·키 저장 → 로그인) |
| [drafts/](drafts/) | FAQ 수정 초안·필독안내 새 텍스트 판 초안 (게시 전 승인 필요) |
| [history/](history/) | 이전 판 보관 (1차 결정 질문지) |
| [original/](original/) | 원본 기획서 PDF |
| [previews/consent-drafts/](previews/consent-drafts/) | 수업 안내 동의 화면 시안 (학생 3개·관리자 3개). 미리보기: https://claude.ai/artifact/PFkJbUuMy8CLJtamJxYQBK |
| [previews/lms-screen-drafts.html](previews/lms-screen-drafts.html) | 화면 시안 (운영자 대시보드·신규 학생 등록 각 3개). 미리보기: https://claude.ai/artifact/Jy4xt9WBjQjmqQuLHmLMNS |

## 코드 위치

| 화면 | 상태 |
|---|---|
| `/lms/admin` 운영자 대시보드 (A안 처리할 일 중심, 2026-10-16 확정) | 가상 데이터 미리보기. `LMS_PREVIEW=1` 환경에서만 열림 (운영 사이트는 404). 로그인·실제 데이터 연결 전 |
| `/lms/student` 학생 마이페이지 (3차 시안 A-1 최종, 2026-10-17 확정) — 판정 `src/lms/student/home.ts` | 가상 데이터 미리보기 (위 상단 칩으로 할 일·재등록 상태 바꿔 보기). `LMS_PREVIEW=1` 에서만 열림. 보강 신청·수업 안내 동의·알림 설정 화면과 학생 로그인·실제 데이터·Meet 주소·아임웹 주문조회 링크는 다음 단계 |


| 위치 | 내용 | 검증 |
|---|---|---|
| `src/lms/rules/` | 수강기간·회차·변경권·변경 판정·휴무·장기 연기·적립금 규칙 + 정책 기준표 일관성 검사 | `npm test` (전체 138개) |
| `src/lms/student/` | 학생 홈 판정 (재등록 안내 POL-RN-08, 할 일, 결제·적립금 이력 POL-PAY-11, 취소 확인) | `npm test` |
| `supabase/migrations/` | DB 스키마 초안 v0.2, 단계별 7개 파일 (400 = 수업 안내 확인·동의, 500 = 정책 원본 v1.0: 적립금·운영 업무·장기 연기, 600 = Supabase 권한 정리) (**아직 어떤 Supabase에도 적용 안 함**) | `npm run test:db` (106개, 로컬 임시 PostgreSQL) |
| `supabase/tests/` | DB 제약·권한 테스트 | |

## 지켜야 할 것
- 정책이 들어가는 코드·문서를 고칠 때는 기준표의 정책 ID를 확인하고, 코드 주석에 `POL-…` ID를 남긴다.
- 미결정 규칙(07 문서의 ⬜)은 코드에 기본값으로 넣지 않는다. `PendingPolicy` 처럼 값이 없으면 동작하지 않게 한다.
- 기존 학생·강사는 서명한 계약 판본(`terms_versions`)이 다를 수 있다. **계약서를 받지 않은 학생에게 계약 판본을 넣지 않는다** (안내서만 받은 학생은 `contract_version` 비움). 새 규칙에는 "언제부터, 누구에게"를 적는다.
- 운영 DB 생성, 실제 데이터 이관, 유료 결제, 실제 메일 발송, 캘린더 쓰기, 공개 배포는 운영자 승인 후.
- 테스트 데이터는 가짜만. 실제 학생 정보를 저장소에 넣지 않는다.
- 화면은 시안 3개 → 운영자 선택 → 개발. 휴대폰(390px)·PC(1280px)에서 확인.
- 홈페이지 개선 과제는 LMS와 별도: [`docs/homepage/backlog.md`](../homepage/backlog.md)
