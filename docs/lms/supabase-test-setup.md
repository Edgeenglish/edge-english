# 시험용 Supabase 연결 안내 (edgeenglish-lms-test)

- 프로젝트: Organization **EdgeEnglish (Free)** · Project **edgeenglish-lms-test** · Region Seoul · GitHub 자동 연결 없음 (2026-10-16 대표 생성)
- **가상 데이터만** 넣는다. 실제 학생·강사 정보, 실제 시트 데이터는 넣지 않는다.
- 비밀번호·비밀키는 **채팅에 붙여 넣지 않는다.** Claude 작업 환경 설정의 '비밀 값' 칸에만 넣는다.
- 실제 운영 프로젝트는 나중에 별도로 만든다. 이 시험용 프로젝트와 키를 섞지 않는다.

## 1단계 — DB 표 만들기 (대표, PC 권장, 약 5분, 비밀키 필요 없음)

1. GitHub에서 작업 브랜치 `claude/trusting-feynman-kujjnm` 의 `supabase/test-setup/schema_all.sql` 을 열고 **Raw** 버튼 → 전체 선택 → 복사
2. Supabase → edgeenglish-lms-test → 왼쪽 **SQL Editor** → **New query** → 붙여 넣기 → **Run**
   - "Success. No rows returned"가 나오면 성공. 빈 프로젝트에 **한 번만** 실행 (두 번째는 "already exists" 오류 — 문제 아님, 이미 만들어진 것)
   - 중간에 오류가 나면 전체가 취소됨(한 묶음으로 실행). 오류 문구 **첫 줄만** Claude에게 알려 주면 됨
3. 같은 방법으로 `supabase/test-setup/seed_fake.sql` 실행 → 가상 학생 4명·가상 강사 2명·업무 4건 (여러 번 실행해도 중복 안 됨)
4. `supabase/test-setup/check.sql` 실행 → 결과 6줄이 모두 **'통과'** 면 완료. 화면을 캡처하거나 결과를 알려 주세요.

이 파일들은 로컬 임시 DB에서 같은 순서로 실행해 6줄 모두 '통과'를 확인했다 (Supabase 실물은 Claude가 아직 접속하지 못함).

## 2단계 — Claude가 시험용 프로젝트에 접속하도록 허용 (대표, 한 번만)

지금 Claude 작업 환경은 `supabase.co` 주소가 막혀 있다(네트워크 정책). 아래 두 가지를 해 주면 Claude가 화면·로그인을 실제 Supabase로 시험할 수 있다.

**(1) 접속 주소 허용** — 이 채팅의 클라우드 환경 메뉴(세션 제목 줄) → **Edit** → **Network access** → Allowed domains에 추가:
- `<프로젝트 주소>.supabase.co` (Supabase → Project Settings → **Data API** 의 Project URL에서 `https://` 뒤 부분. 예: `abcdxyz.supabase.co`) — 프로젝트 주소는 비밀이 아님

**(2) 키 저장** — 같은 Edit 화면의 **환경 변수 / 비밀 값(Network secrets 또는 API credentials)** 칸에 아래 이름으로 저장. 값은 Supabase → Project Settings → **API Keys** 에서 복사:

| 변수 이름 (그대로) | 넣을 값 | 비밀인가 |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | Project URL (`https://….supabase.co`) | 아님 |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | **Publishable key** (`sb_publishable_…`) 또는 옛 이름 anon key | 아님 (화면에 공개되는 키, RLS로 보호) |
| `SUPABASE_SERVICE_ROLE_KEY` | **Secret key** (`sb_secret_…`) 또는 옛 이름 service_role key | **비밀** — 이 칸에만. 채팅·GitHub·Vercel Production 금지 |

- 저장 후 **새 세션**에서 반영된다. Claude는 값을 출력하지 않고 존재 여부만 확인한다.
- DB 비밀번호(Database password)와 Supabase 계정 Access Token은 **필요 없다.** 표를 고칠 때는 1단계처럼 대표가 SQL Editor에서 실행한다. (Access Token은 계정 전체 권한이라 나중에 만들 운영 프로젝트까지 건드릴 수 있어 쓰지 않는다.)
- 키가 노출됐다고 생각되면 Supabase → API Keys에서 **새 Secret key 생성 후 이전 키 삭제**.

## 3단계 — 로그인 설정 (Claude가 화면을 만든 뒤 함께, 지금은 안 해도 됨)

- Authentication → Sign In / Providers → **Email**: 켜기, "Confirm email" 켜기. 학생·강사는 이메일 6자리 코드 (POL-OP-15).
- Authentication → **Allow new users to sign up: 끄기** (회원가입 없음 — 운영자가 등록한 이메일만).
- 이메일 템플릿(Magic Link)을 6자리 코드 방식으로 바꾸는 문구는 Claude가 준비.
- 무료 요금제의 기본 메일 발송은 시간당 몇 통으로 제한됨 → 시험용으로는 충분, 실제 운영 전 메일 발송 서비스 연결(비용 승인 D-6).

## 지금 상태

| 항목 | 상태 |
|---|---|
| 시험용 프로젝트 | ✅ 생성 (대표) |
| 마이그레이션·가상 데이터 | ⬜ 1단계 대기 |
| Claude 접속 (주소 허용·키) | ⬜ 2단계 대기 |
| 로그인 | ⬜ 3단계 (화면 개발 후) |
| Vercel 연결 | 하지 않음 (실제 운영 환경 — 별도 승인) |

## 파일

| 파일 | 내용 |
|---|---|
| `supabase/test-setup/schema_all.sql` | 마이그레이션 7개(000~600)를 순서대로 묶은 파일 (자동 생성: `node scripts/lms-test-bundle.mjs`, 테스트가 최신인지 확인) |
| `supabase/test-setup/seed_fake.sql` | 가상 데이터 (이름 모두 '가상…', 이메일 example.com) |
| `supabase/test-setup/check.sql` | 적용 확인 (읽기만) |
| `supabase/migrations/20261016000600_lms_supabase_hardening.sql` | Supabase 기본 권한 정리: 로그인 안 한 사용자는 LMS 함수·학생 번호를 못 씀 |
