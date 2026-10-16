# 엣지영어 LMS 문서 (Claude가 작업 전에 먼저 읽는 곳)

웹앱 + Supabase(PostgreSQL) 기반 LMS. 원본 기획서(2026-10-11)를 실제 운영정책과 대조해 고친 v2와 실행 계획.

| 문서 | 내용 |
|---|---|
| [01-current-state.md](01-current-state.md) | 지금 실제로 있는 것 (코드·시트 직접 확인), 완료/일부/미구현 |
| [02-plan-v2.md](02-plan-v2.md) | **수정된 최종 기획서** (원본 목차 유지, 변경·추가·미결 표시) |
| [03-changelog.md](03-changelog.md) | 원본 대비 바뀐 점과 이유 |
| [04-policy-review.md](04-policy-review.md) | 기획서 ↔ FAQ·계약서·급여정책·시트 대조 결과 |
| [05-architecture.md](05-architecture.md) | 기술 구조, DB, 권한, 캘린더, 이관, 보안, 비용 |
| [06-roadmap.md](06-roadmap.md) | 개발 순서, 단계별 완료 조건 |
| [07-decisions.md](07-decisions.md) | **운영자 결정 필요 사항** (추천안 포함) — 결정되면 여기 기록 |
| [original/](original/) | 원본 기획서 PDF |
| [previews/lms-screen-drafts.html](previews/lms-screen-drafts.html) | 화면 시안 (운영자 대시보드·신규 학생 등록 각 3개). 미리보기: https://claude.ai/artifact/Jy4xt9WBjQjmqQuLHmLMNS |

## 코드 위치

| 위치 | 내용 | 검증 |
|---|---|---|
| `src/lms/rules/` | 수강기간·회차·변경권·변경 판정·휴무 미리보기 규칙 (TypeScript, 외부 의존 없음) | `npm test` |
| `supabase/migrations/` | DB 스키마 초안 (**아직 어떤 Supabase에도 적용 안 함**) | `npm run test:db` (로컬 임시 PostgreSQL) |
| `supabase/tests/` | DB 제약·권한 테스트 | |

## 지켜야 할 것
- 미결정 규칙(07 문서의 ⬜)은 코드에 기본값으로 넣지 않는다. `PendingPolicy` 처럼 값이 없으면 동작하지 않게 한다.
- 운영 DB 생성, 실제 데이터 이관, 유료 결제, 실제 메일 발송, 캘린더 쓰기, 공개 배포는 운영자 승인 후.
- 테스트 데이터는 가짜만. 실제 학생 정보를 저장소에 넣지 않는다.
- 화면은 시안 3개 → 운영자 선택 → 개발. 휴대폰(390px)·PC(1280px)에서 확인.
