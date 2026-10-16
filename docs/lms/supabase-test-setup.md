# 시험용 Supabase 연결 안내 (edgeenglish-lms-test)

- 프로젝트: Organization **EdgeEnglish (Free)** · Project **edgeenglish-lms-test** · Region Seoul · GitHub 자동 연결 없음 (2026-10-16 대표 생성)
- **가상 데이터만** 넣는다. 실제 학생·강사 정보, 실제 시트 데이터는 넣지 않는다.
- 비밀번호·비밀키는 **채팅에 붙여 넣지 않는다.** Claude 작업 환경 설정의 '비밀 값' 칸에만 넣는다.
- 실제 운영 프로젝트는 나중에 별도로 만든다. 이 시험용 프로젝트와 키를 섞지 않는다.

## 0. 실행 전 안전성 검토 결과 (2026-10-16, Claude)

Supabase 새 프로젝트의 기본 권한(anon·authenticated에 표·함수·시퀀스를 자동으로 여는 설정)을 로컬 PostgreSQL에 똑같이 만들어 놓고 세 파일을 실제 순서대로 실행해 확인했다. 실물 Supabase에는 아직 접속하지 못했으므로 **로컬 재현 결과**다.

| 점검 | 결과 |
|---|---|
| 실제 학생 데이터 접근 | 없음. 세 파일 모두 외부 연결(다른 DB·인터넷·파일 읽기) 명령이 없고, 새 빈 프로젝트 안에서만 동작. 기준 데이터는 상태값 14개·계약/안내서 판 이름·기능 스위치뿐(사람 이름·연락처 없음). 가상 데이터는 이름이 모두 '가상…', 이메일은 example.com |
| 기존 표 삭제 위험 | 없음. DROP·TRUNCATE·DELETE·권한 계정 변경 명령 0개. Supabase 자체 영역(auth·storage 등)에 아무것도 만들거나 고치지 않음 (public 영역에만 표를 만듦) |
| RLS·접근 권한 | 모든 표 RLS 켜짐. 로그인 안 한 사용자(anon)는 표·뷰를 하나도 못 읽음, LMS 함수·학생 번호도 못 씀. 등록되지 않은 로그인 사용자는 학생·결제·업무를 0건으로 봄(판본·상태값·공휴일 목록만 보임). 쓰기는 서버만 |
| 실행 순서 | ① schema_all → ② seed_fake → ③ check. 순서를 틀려 seed를 먼저 실행하면 "표가 없음" 오류로 **아무것도 들어가지 않음** |
| 재실행 | schema_all을 두 번 실행하면 "already exists" 오류가 나고 **전체 취소**(기존 표·데이터 그대로). seed_fake는 여러 번 실행해도 데이터가 늘지 않음(변경 이력 1줄만 추가). check는 읽기만 함 |
| 중간 오류 | schema_all·seed_fake 모두 한 묶음(begin~commit)이라 중간에 오류가 나면 반쯤 만들어진 상태가 남지 않음 |
| 알려진 경고 | Supabase 'Security Advisor'가 "btree_gist 확장이 public에 있음"을 경고할 수 있음 — 시험용에서는 문제 없음, 운영 프로젝트 만들 때 정리 |

## 1단계 — DB 표 만들기 (대표, PC 권장, 약 5분, 비밀키 필요 없음)

1. GitHub에서 작업 브랜치 `claude/trusting-feynman-kujjnm` 의 `supabase/test-setup/schema_all.sql` 을 열고 **Raw** 버튼 → 전체 선택 → 복사
2. Supabase → edgeenglish-lms-test → 왼쪽 **SQL Editor** → **New query** → 붙여 넣기 → **Run**
   - "Success. No rows returned"가 나오면 성공. 빈 프로젝트에 **한 번만** 실행 (두 번째는 "already exists" 오류 — 문제 아님, 이미 만들어진 것)
   - 중간에 오류가 나면 전체가 취소됨(한 묶음으로 실행). 오류 문구 **첫 줄만** Claude에게 알려 주면 됨
3. 같은 방법으로 `supabase/test-setup/seed_fake.sql` 실행 → 가상 학생 4명·가상 강사 2명·업무 4건 (여러 번 실행해도 중복 안 됨)
4. `supabase/test-setup/check.sql` 실행 → 결과 6줄이 모두 **'통과'** 면 완료. 화면을 캡처하거나 결과를 알려 주세요.

이 파일들은 로컬 임시 DB에서 같은 순서로 실행해 6줄 모두 '통과'를 확인했다 (Supabase 실물은 Claude가 아직 접속하지 못함).

## 2단계 — Claude가 시험용 프로젝트에 접속하도록 허용 (대표, 한 번만)

지금 Claude 작업 환경은 `supabase.co` 주소에서 403이 난다. 작업 환경의 외부 접속 관문(프록시)이 허용 목록에 없는 주소를 막을 때 나는 오류이고, 관문 안내서도 "대부분 허용되지 않은 주소"라고 설명한다. 그래서 **허용 목록에 주소를 넣으면 풀릴 가능성이 높지만, 넣은 뒤 Claude가 실제로 접속해 봐야 확정**된다. 접속은 HTTPS(웹 주소)로만 하고, DB 직접 접속(5432 포트)은 쓰지 않는다.

**최소 권한 원칙에 따른 순서**
- **지금 필요한 것**: 접속 주소 허용 + `NEXT_PUBLIC_SUPABASE_URL` + `NEXT_PUBLIC_SUPABASE_ANON_KEY`(publishable key). 둘 다 원래 화면에 공개되는 값이라 비밀이 아니다. 이것만으로 Claude는 ① 실물 Supabase에 접속되는지 ② 로그인 안 한 상태에서 데이터가 정말 하나도 안 보이는지(RLS)를 실물로 확인할 수 있다.
- **아직 필요 없는 것**: Secret key(service_role). 서버가 결제 확인·업무 처리 같은 '쓰기'를 할 때 필요한데, 그 기능을 만들고 로그인 화면이 준비된 뒤에 요청한다. 그때도 **시험용 프로젝트 전용 Secret key를 새로 하나 만들어**(이름 예: claude-test) 넣고, 다 쓰면 그 키만 삭제한다. 레거시 service_role 키는 지우거나 바꾸기 어려워 쓰지 않는다.
- 쓰지 않는 것: DB 비밀번호, Supabase 계정 Access Token(계정 전체 권한).

**(1) 접속 주소 허용** — 이 채팅의 클라우드 환경 메뉴(세션 제목 줄) → **Edit** → **Network access** → Allowed domains에 추가:
- `<프로젝트 주소>.supabase.co` (Supabase → Project Settings → **Data API** 의 Project URL에서 `https://` 뒤 부분. 예: `abcdxyz.supabase.co`) — 프로젝트 주소는 비밀이 아님

**(2) 키 저장** — 같은 Edit 화면의 **환경 변수 / 비밀 값(Network secrets 또는 API credentials)** 칸에 아래 이름으로 저장. 값은 Supabase → Project Settings → **API Keys** 에서 복사:

| 변수 이름 (그대로) | 넣을 값 | 비밀인가 |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | Project URL (`https://….supabase.co`) | 아님 |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | **Publishable key** (`sb_publishable_…`) 또는 옛 이름 anon key | 아님 (화면에 공개되는 키, RLS로 보호) |
| `SUPABASE_SERVICE_ROLE_KEY` | **(나중에)** 시험용 전용으로 새로 만든 **Secret key** (`sb_secret_…`) | **비밀** — 이 칸에만. 채팅·GitHub·Vercel Production 금지. 쓰기 기능 시험 단계에서 Claude가 요청할 때 |

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
| 마이그레이션·가상 데이터 | ✅ 2026-10-17 대표가 SQL Editor에서 실행, check.sql 6줄 모두 '통과' (프로젝트 주소 `kyeimjozkcqbgkepwrnv.supabase.co`) |
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
