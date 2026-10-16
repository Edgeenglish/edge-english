# 엣지영어 LMS 문서 (Claude가 작업 전에 먼저 읽는 곳)

웹앱 + Supabase(PostgreSQL) 기반 LMS. 원본 기획서(2026-10-11)를 실제 운영정책과 대조해 고친 v2와 실행 계획.

**최우선 원칙: 운영정책은 [`policy/register.md`](policy/register.md)(정책 기준표)가 기준이다.** 계약서·FAQ·안내문·시트·코드가 서로 다르면 기준표에서 먼저 정리하고, 바꿀 때는 [`policy/process.md`](policy/process.md) 절차를 따른다.

| 정책 관리 | 내용 |
|---|---|
| [policy/register.md](policy/register.md) | **운영정책 기준표** 68개 (확정·검토 중·변경 제안·폐지, 근거, 기존/신규 차이, 고칠 곳) |
| [policy/critical-policies.md](policy/critical-policies.md) | **핵심 정책 27개 검토표** (횟수·변경권·보강·이월·급여, 판본별 적용 대상·실제 승인 여부) |
| [policy/contract-version-check.md](policy/contract-version-check.md) | 구계약 적용 학생·강사 확인 방법 (서명·발송·동의 구분, 이름 없는 집계) |
| [policy/conflicts.md](policy/conflicts.md) | **정책 충돌 목록** 22건 (횟수·돈·계약 우선) |
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
| [09-design-review.md](09-design-review.md) | 기존 시트 구조 vs 새 구조 연결표, 입력 주체, SQL v0.2 재검토, 대안 비교 |
| [history/](history/) | 이전 판 보관 (1차 결정 질문지) |
| [original/](original/) | 원본 기획서 PDF |
| [previews/lms-screen-drafts.html](previews/lms-screen-drafts.html) | 화면 시안 (운영자 대시보드·신규 학생 등록 각 3개). 미리보기: https://claude.ai/artifact/Jy4xt9WBjQjmqQuLHmLMNS |

## 코드 위치

| 위치 | 내용 | 검증 |
|---|---|---|
| `src/lms/rules/` | 수강기간·회차·변경권·변경 판정·휴무 미리보기 규칙 + 정책 기준표 일관성 검사 | `npm test` (74개) |
| `supabase/migrations/` | DB 스키마 초안 v0.2, 단계별 4개 파일 (**아직 어떤 Supabase에도 적용 안 함**) | `npm run test:db` (45개, 로컬 임시 PostgreSQL) |
| `supabase/tests/` | DB 제약·권한 테스트 | |

## 지켜야 할 것
- 정책이 들어가는 코드·문서를 고칠 때는 기준표의 정책 ID를 확인하고, 코드 주석에 `POL-…` ID를 남긴다.
- 미결정 규칙(07 문서의 ⬜)은 코드에 기본값으로 넣지 않는다. `PendingPolicy` 처럼 값이 없으면 동작하지 않게 한다.
- 기존 학생·강사는 서명한 계약 판본(`terms_versions`)이 다를 수 있다. 새 규칙에는 "언제부터, 누구에게"를 적는다.
- 운영 DB 생성, 실제 데이터 이관, 유료 결제, 실제 메일 발송, 캘린더 쓰기, 공개 배포는 운영자 승인 후.
- 테스트 데이터는 가짜만. 실제 학생 정보를 저장소에 넣지 않는다.
- 화면은 시안 3개 → 운영자 선택 → 개발. 휴대폰(390px)·PC(1280px)에서 확인.
- 홈페이지 개선 과제는 LMS와 별도: [`docs/homepage/backlog.md`](../homepage/backlog.md)
