# 18. 운영 DB를 쓸 화면 주소 — 비교안 (2026-10-22)

D-52(기존 학생 간단 입력) 전에 정해야 하는 것: 운영 DB(`edgeenglish-lms`, `mfamixejxydodclhglbc.supabase.co`)에 연결된 LMS 화면을 **어느 주소**로 열지.
지금 LMS 화면(Vercel Preview)은 모두 시험용 DB(`edgeenglish-lms-test`)에 연결돼 있다.

## 사실 확인 (코드·Vercel 공식 문서)
- LMS 화면이 쓰는 환경 변수는 3개뿐: `LMS_PREVIEW`(=1일 때만 `/lms` 열림, 아니면 404 — `src/app/lms/layout.tsx`), `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`(공개키, 비밀 아님). 서버 비밀키는 아직 쓰지 않음
- 로그인은 이메일 **6자리 코드 입력** 방식(`signInWithOtp` → `verifyOtp`)이라 메일 링크로 돌아오는 주소가 없음 → **어느 주소를 고르든 Supabase 로그인 설정을 바꿀 필요 없음**
- `/lms` 는 검색엔진 노출 금지(`noindex`)가 이미 들어 있음
- Vercel은 **Preview 환경 변수를 특정 브랜치에만** 줄 수 있고(같은 이름이면 그 브랜치에서만 덮어씀), **도메인을 특정 브랜치에 연결**할 수도 있음 — 둘 다 Hobby 요금제 포함 모든 요금제에서 가능. (이름 붙은 '사용자 지정 환경'은 Pro 이상)
  - https://vercel.com/docs/environment-variables/manage-across-environments
  - https://vercel.com/docs/domains/working-with-domains/assign-domain-to-a-git-branch

## 비교

| | ① 운영 사이트 `edgeenglish.kr/lms` | ② 운영 DB 전용 브랜치 Preview 주소 |
|---|---|---|
| 방법 | LMS 코드 전체를 main에 합쳐 홈페이지와 같이 배포. Production 환경 변수 3개 추가 | `lms-prod` 브랜치를 만들고 그 브랜치에만 운영 DB 주소·공개키를 줌. 다른 Preview는 계속 시험용 DB |
| 주소 | 짧고 기억하기 쉬움 | `edge-english-git-lms-prod-….vercel.app` (길다 → 휴대폰 홈 화면에 즐겨찾기). 원하면 나중에 `lms.edgeenglish.kr` 같은 하위 도메인을 이 브랜치에 연결 가능(DNS 한 줄 추가) |
| 홈페이지 영향 | **있음** — 아직 만드는 중인 LMS 코드가 홈페이지 배포에 들어감. LMS를 고칠 때마다 홈페이지 재배포 | **없음** — 홈페이지(main)는 그대로 |
| 고칠 때 절차 | 매번 홈페이지 배포 승인 | 시험용 Preview에서 확인 → 대표 승인 → `lms-prod`에 반영 (main과 같은 무게의 절차, 홈페이지는 안 건드림) |
| 누가 열 수 있나 | 누구나 주소 접속 가능(로그인·DB 권한으로 막힘) | Vercel 기본 보호 때문에 **Vercel에 로그인한 사람만** 화면이 열림 → 지금(운영자만 쓰는 단계)에는 오히려 한 겹 더 안전. 단, **학생·강사가 쓰는 단계에서는 이 방식으로 못 씀** → 그때 ①로 옮김 |
| 시험용·운영 섞일 위험 | 낮음(주소 자체가 다름) | 브랜치별 환경 변수를 잘못 넣으면 섞임 → 화면 상단에 '운영 DB'/'시험용 DB' 표시를 넣어 막음(아래) |
| Vercel 요금제 | Hobby는 상업용 불가 조건 — 운영 사이트에 LMS를 붙이는 시점에 다시 확인 필요(D-6) | 같은 프로젝트라 조건은 같지만, 결정을 ① 전환 때로 미룰 수 있음 |
| 나중에 옮기기 | — | ②→①은 환경 변수 3개 + main 합치기. 데이터는 같은 운영 DB라 옮길 것 없음 |

## Claude 의견 (객관적으로)
**지금은 ②, 학생·강사 화면을 열 때 ①로.**
- 앞으로 열흘(입력 1~3일 → 1주일 시험 → 11일쯤 본격 사용) 동안 LMS 코드는 계속 바뀐다. ①이면 그 변경이 모두 홈페이지 배포가 되고, 홈페이지 배포 승인 절차가 LMS 수정 속도를 늦춘다.
- 지금 쓰는 사람은 대표(운영자)뿐이라 Vercel 로그인 벽은 단점이 아니라 보호막이다.
- ②의 진짜 약점은 '주소가 길다'와 '시험용·운영을 헷갈릴 수 있다' 두 가지. 앞은 즐겨찾기로, 뒤는 화면 표시로 해결된다.
- ①로 옮기는 자연스러운 시점: 학생 화면을 실제로 열 때, 또는 Pro 전환(본격 사용) 즈음. 그때 Vercel 요금제도 같이 정한다.

## 같이 넣을 작은 안전장치 (선택과 무관하게 권장)
- 화면 맨 위에 **'운영 DB'(빨강) / '시험용 DB'(회색)** 표시. 접속한 Supabase 주소로 자동 판단(운영 주소 `mfamixejxydodclhglbc`일 때만 '운영'). 실제 학생을 시험용 DB에 넣거나, 시험 데이터를 운영 DB에 넣는 실수를 막는 용도. 코드 수정 작음.

## ②를 고르면 대표가 할 일 (휴대폰 가능, 약 10분)
1. Claude: 승인된 코드로 `lms-prod` 브랜치 만들기 + 위 표시 추가
2. 대표: Vercel → 프로젝트 → Settings → Environment Variables → 추가 2개, **Environment = Preview, Branch = `lms-prod`** 만 선택
   - `NEXT_PUBLIC_SUPABASE_URL` = `https://mfamixejxydodclhglbc.supabase.co`
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY` = 운영 프로젝트 Publishable key (복사 버튼으로)
   - `LMS_PREVIEW=1` 은 기존 Preview 값이 그대로 적용돼 추가 불필요
3. Claude가 `lms-prod`에 다시 올려 새 배포 (환경 변수는 새 배포부터 적용)
4. 대표: 그 주소에서 로그인 → 운영 DB는 별도 계정이므로 **인증 앱 QR을 새로 등록**(앱에 두 줄이 생김 — 이름으로 구분) → 화면 맨 위 '운영 DB' 표시 + 학생 0명 확인 (시험용은 6명)
5. 그 다음 D-52 실제 입력 (입력 직전 백업)
