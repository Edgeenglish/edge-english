#!/usr/bin/env bash
# 기존 학생 자동 등록 SQL(scripts/lms-import-existing.ts 결과) 로컬 검증
# 임시 PostgreSQL에 운영과 같은 migration을 모두 적용 → 운영 이름표·대표 계정 흉내 → paste.sql 실행
#  ① 기대값(expected.json)과 학생별 정규·추가·미예약 보강·남은 수·변경권·종료일·수업 날짜 비교
#  ② 같은 SQL 두 번째 실행 → 학생·수업 수 그대로 (중복 없음)
#  ③ 시험용 이름표 DB에서는 멈추고 아무것도 안 바뀜
#  ④ 들어간 수업 하나로 1700 수업 변경 미리 보기(저장 안 함)가 동작
# 사용: bash scripts/lms-import-verify.sh <out-dir>     (운영·시험용 Supabase에는 접속하지 않음)
set -euo pipefail
OUT="$(cd "$1" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
WORK="$(mktemp -d)"
RUN_AS=()
if [ "$(id -u)" = "0" ]; then RUN_AS=(runuser -u postgres --); chown postgres "$WORK"; fi
cleanup() { "${RUN_AS[@]}" "$PGBIN/pg_ctl" -D "$WORK/data" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

"${RUN_AS[@]}" "$PGBIN/initdb" -D "$WORK/data" -U postgres -A trust >/dev/null
"${RUN_AS[@]}" "$PGBIN/pg_ctl" -D "$WORK/data" -o "-k $WORK -c listen_addresses='' -c timezone=UTC" -l "$WORK/log" start >/dev/null
cp "$OUT/paste.sql" "$WORK/"; chmod a+r "$WORK/paste.sql"
PSQL=("${RUN_AS[@]}" psql -h "$WORK" -U postgres -v ON_ERROR_STOP=1 -q)

for db in prod test; do
  "${PSQL[@]}" -d postgres -c "create database $db"
  "${PSQL[@]}" -d $db -f "$ROOT/supabase/tests/stub_supabase.sql"
  for f in "$ROOT"/supabase/migrations/*.sql; do "${PSQL[@]}" -d $db -o /dev/null -f "$f"; done
  "${PSQL[@]}" -d $db -c "insert into app_users (auth_user_id, role, admin_level) values ('00000000-0000-4000-8000-0000000000aa', 'admin', 'owner')"
done
"${PSQL[@]}" -d prod -c "insert into lms_backup.project (name) values ('edgeenglish-lms')"
"${PSQL[@]}" -d test -c "insert into lms_backup.project (name) values ('edgeenglish-lms-test')"

# ③ 시험용 이름표 DB → 멈춤
ERR="$("${PSQL[@]}" -d test -f "$WORK/paste.sql" 2>&1 || true)"
echo "$ERR" | grep -q '멈춤: 운영 DB' || { echo "❌ 운영 DB 확인 없이 실행됨"; echo "$ERR"; exit 1; }
[ "$("${PSQL[@]}" -d test -tA -c "select count(*) from students") $("${PSQL[@]}" -d test -tA -c "select count(*) from tutors")" = "0 0" ] || { echo "❌ 시험용 DB에 무엇인가 들어감"; exit 1; }
echo "✅ ③ 다른 DB에서는 멈춤 (아무것도 안 바뀜)"

# 실행 → 결과 표
"${PSQL[@]}" -d prod -f "$WORK/paste.sql" > "$WORK/result1.txt"
cat "$WORK/result1.txt"

# ① 기대값 비교
Q="select coalesce(json_agg(x order by x.name_ko), '[]') from (
  select s.name_ko, e.final_end_date::text as end_date,
    (select count(*) from lessons l where l.enrollment_id = e.id and l.kind = 'regular')::int as regular,
    (select count(*) from lessons l where l.enrollment_id = e.id and l.kind = 'migrated_extra')::int as extras,
    (select count(*) from migrated_items m where m.enrollment_id = e.id and m.kind = 'makeup_open')::int as open,
    c.lms_left, c.sheet_total - c.sheet_used as sheet_left, c.checked_at is not null as checked,
    (select p.credits_granted + coalesce((select sum(delta) from credit_ledger cl where cl.period_id = p.id), 0)
       from enrollment_periods p where p.enrollment_id = e.id and p.idx = (select idx from enrollment_periods q
         where q.enrollment_id = e.id and (now() at time zone 'Asia/Seoul')::date between q.start_date and q.end_date))::int as credits_left,
    (select json_agg(d order by d) from (
       select (l.starts_at at time zone 'Asia/Seoul')::date::text as d from lessons l where l.enrollment_id = e.id
       union all select m.original_date::text from migrated_items m
         where m.enrollment_id = e.id and m.kind = 'makeup_open' and m.original_date >= (select min(kst_date) from lessons where enrollment_id = e.id)
     ) z) as dates
  from students s join enrollments e on e.student_id = s.id join import_checks c on c.enrollment_id = e.id) x"
"${PSQL[@]}" -d prod -tA -c "$Q" > "$WORK/actual.json"
node -e '
const [a, b] = [require(process.argv[1]), require(process.argv[2])];
const K = ["name_ko", "end_date", "regular", "extras", "open", "lms_left", "sheet_left", "checked", "credits_left", "dates"];
const norm = (xs) => JSON.stringify(xs.map((x) => K.map((k) => (k === "dates" ? [...(x.dates ?? [])].sort() : x[k]))).sort((p, q) => p[0].localeCompare(q[0])));
if (norm(a) !== norm(b)) { console.log("❌ ① 기대값과 다름\n기대", JSON.stringify(b, null, 1), "\n실제", JSON.stringify(a, null, 1)); process.exit(1); }
console.log(`✅ ① 학생 ${a.length}명 기대값과 같음 (정규·추가·미예약 보강·남은 수·변경권·종료일·수업 날짜)`);
' "$WORK/actual.json" "$OUT/expected.json"

# ② 두 번째 실행 → 그대로
COUNT="select (select count(*) from students) || ' ' || (select count(*) from lessons) || ' ' || (select count(*) from migrated_items) || ' ' || (select count(*) from tutors) || ' ' || (select count(*) from tutor_time_off)"
B="$("${PSQL[@]}" -d prod -tA -c "$COUNT")"
"${PSQL[@]}" -d prod -o /dev/null -f "$WORK/paste.sql"
A="$("${PSQL[@]}" -d prod -tA -c "$COUNT")"
[ "$A" = "$B" ] || { echo "❌ ② 두 번째 실행에서 늘어남: $B → $A"; exit 1; }
echo "✅ ② 두 번째 실행해도 그대로 (학생·수업·보강 기록·강사·휴무 $B)"

# ④ 1700 수업 변경 미리 보기 (저장 안 함): 학생마다 다음 정규 수업 하나, 7일 전 요청으로
"${PSQL[@]}" -d prod -tA -c "
select set_config('request.jwt.claims', '{\"sub\":\"00000000-0000-4000-8000-0000000000aa\",\"role\":\"authenticated\",\"aal\":\"aal2\"}', false);
select s.name_ko || ' ' || to_char(l.starts_at at time zone 'Asia/Seoul', 'MM/DD HH24:MI') || ' → ' ||
       (admin_change_lesson(gen_random_uuid(), l.id, 'student', l.starts_at - interval '7 days', true))::text
from students s cross join lateral (select * from lessons where student_id = s.id and kind = 'regular' order by starts_at limit 1) l
order by s.code;" | sed '1d' > "$WORK/dry.txt"
cat "$WORK/dry.txt"
[ "$("${PSQL[@]}" -d prod -tA -c "select count(*) from change_requests")" = "0" ] || { echo "❌ ④ 미리 보기가 저장됨"; exit 1; }
echo "✅ ④ 수업 변경 미리 보기 동작 (저장 안 됨)"
