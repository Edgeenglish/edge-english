#!/usr/bin/env bash
# LMS 스키마 로컬 검증: 임시 PostgreSQL을 띄워 스키마를 적용하고 제약·권한 테스트를 돌린 뒤 지움.
# 실제 Supabase·운영 데이터에는 접속하지 않음. 가짜 데이터만 사용.
# 사용: bash supabase/tests/run.sh   (PostgreSQL 15+ 의 initdb/pg_ctl 필요)
set -euo pipefail
shopt -s nullglob

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
WORK="$(mktemp -d)"
RUN_AS=()
if [ "$(id -u)" = "0" ]; then RUN_AS=(runuser -u postgres --); chown postgres "$WORK"; fi

cleanup() { "${RUN_AS[@]}" "$PGBIN/pg_ctl" -D "$WORK/data" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

"${RUN_AS[@]}" "$PGBIN/initdb" -D "$WORK/data" -U postgres -A trust >/dev/null
"${RUN_AS[@]}" "$PGBIN/pg_ctl" -D "$WORK/data" -o "-k $WORK -c listen_addresses='' -c timezone=UTC" -l "$WORK/log" start >/dev/null

PSQL=("${RUN_AS[@]}" psql -h "$WORK" -U postgres -d postgres -v ON_ERROR_STOP=1 -q)
"${PSQL[@]}" -f "$HERE/stub_supabase.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do "${PSQL[@]}" -o /dev/null -f "$f"; done
"${PSQL[@]}" -o /dev/null -f "$HERE/schema_test.sql" 2>&1 | sed -n -e "s/.*NOTICE:  //p" -e "/ERROR/p"
echo "✅ LMS 스키마 검증 통과"

# 로그인 사용자 권한 점검: 시험용 Supabase 상태(가상 데이터 적용 후)와 같게 만든 뒤 실물용 파일을 그대로 실행
"${PSQL[@]}" -o /dev/null -f "$ROOT/supabase/test-setup/seed_fake.sql"
"${PSQL[@]}" -o /dev/null -f "$HERE/stub_supabase_platform.sql"   # 실물 Supabase 플랫폼 함수 흉내
OUT="$("${RUN_AS[@]}" psql -h "$WORK" -U postgres -d postgres -q -f "$ROOT/supabase/test-setup/authz-probe.sql" 2>&1 || true)"
echo "$OUT" | sed -n 's/^.*ERROR:  //p; /^[-(참실]/p; /^$/d'
echo "$OUT" | grep -q 'AUTHZ-PROBE 결과: 모두 통과' || { echo "❌ 로그인 사용자 권한 점검 실패"; exit 1; }
echo "✅ 로그인 사용자 권한 점검 통과"

# 운영 DB 표 만들기 파일(supabase/prod-setup) 점검: 빈 DB에 한 묶음으로 실행 → 확인 모두 통과, 두 번째 실행은 안전장치로 멈춤
"${PSQL[@]}" -c "create database prod"
PROD=("${RUN_AS[@]}" psql -h "$WORK" -U postgres -d prod -v ON_ERROR_STOP=1 -q)
cp "$ROOT"/supabase/prod-setup/*.sql "$ROOT"/supabase/backup/backup.sql "$WORK"/; chmod a+r "$WORK"/*.sql
"${PROD[@]}" -f "$HERE/stub_supabase.sql"
[ "$("${PROD[@]}" -tA -f "$WORK/00-empty-check.sql")" = "0" ] || { echo "❌ 빈 DB 확인 실패"; exit 1; }
"${PROD[@]}" -o /dev/null -f "$WORK/01-schema.sql"
CHECK="$("${PROD[@]}" -tA -f "$WORK/02-check.sql")"
echo "$CHECK" | grep -v '|통과$' && { echo "❌ 운영 DB 확인 실패"; exit 1; }
AGAIN="$("${PROD[@]}" -o /dev/null -f "$WORK/01-schema.sql" 2>&1 || true)"
echo "$AGAIN" | grep -q '멈춤: public 에 이미 표가 있습니다' || { echo "❌ 두 번째 실행 안전장치 없음"; exit 1; }
"${PROD[@]}" -c "create table auth.users (id uuid primary key, email text)" \
  -c "insert into auth.users values ('00000000-0000-4000-8000-0000000000aa', 'Support@EdgeEnglish.kr')"
"${PROD[@]}" -o /dev/null -f "$WORK/03-owner.sql"; "${PROD[@]}" -o /dev/null -f "$WORK/03-owner.sql"
[ "$("${PROD[@]}" -tA -c "select count(*) from app_users where role = 'admin' and admin_level = 'owner'")" = "1" ] || { echo "❌ 대표 계정 연결 실패"; exit 1; }
echo "✅ 운영 DB 표 만들기 파일 점검 통과 (확인 $(echo "$CHECK" | wc -l)줄 통과)"

# 백업 → 복구 왕복 + 안전장치: 시험용 이름이 붙은 가상 데이터 DB(postgres)를 백업 →
#  ① 운영 DB에 복구 시도 → '다른 프로젝트' 로 멈춤  ② 이름 안 고침·틀린 이름 → 멈춤
#  ③ 같은 이름의 빈 시험용 DB(test2)에 복구 → 다시 백업해 표 41개 내용 같음
#  ④ 한 번 더 복구 → 직전 저장본(snapshots)을 꺼내 보면 ③ 상태와 같음 (잘못 복구해도 되돌릴 수 있음)
"${PSQL[@]}" -c "create table if not exists auth.users (id uuid primary key, email text)" \
  -c "insert into lms_backup.project (name) values ('edgeenglish-lms-test')"
cp "$ROOT"/supabase/backup/from-snapshot.sql "$WORK"/; chmod a+r "$WORK"/from-snapshot.sql
"${RUN_AS[@]}" psql -h "$WORK" -U postgres -d postgres -v ON_ERROR_STOP=1 -q --csv -f "$WORK/backup.sql" > "$WORK/bk1.csv"
node "$ROOT/scripts/lms-restore-sql.mjs" "$WORK/bk1.csv" > "$WORK/restore.sql"
with_name() { sed "s/'여기에 프로젝트 이름'/'$1'/" "$WORK/restore.sql" > "$WORK/restore-$1.sql"; chmod a+r "$WORK/restore-$1.sql"; echo "$WORK/restore-$1.sql"; }
expect_stop() { # DB파일 SQL파일 기대문구
  local out; out="$("${RUN_AS[@]}" psql -h "$WORK" -U postgres -d "$1" -v ON_ERROR_STOP=1 -q -f "$2" 2>&1 || true)"
  echo "$out" | grep -q "$3" || { echo "$out" | tail -3; echo "❌ 복구 안전장치 실패: $3"; exit 1; }
}
chmod a+r "$WORK/restore.sql"
expect_stop prod "$(with_name edgeenglish-lms)" '다른 프로젝트(edgeenglish-lms-test)의 백업'
expect_stop prod "$WORK/restore.sql" '입력한 이름(여기에 프로젝트 이름)이 이 DB(edgeenglish-lms)와 다릅니다'
[ "$("${PROD[@]}" -tA -c "select count(*) from students")" = "0" ] || { echo "❌ 멈춘 복구가 운영 DB를 바꿈"; exit 1; }
"${PSQL[@]}" -c "create database test2"
T2=("${RUN_AS[@]}" psql -h "$WORK" -U postgres -d test2 -v ON_ERROR_STOP=1 -q)
"${T2[@]}" -f "$HERE/stub_supabase.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do "${T2[@]}" -o /dev/null -f "$f"; done
"${T2[@]}" -c "create table auth.users (id uuid primary key, email text)" -c "insert into lms_backup.project (name) values ('edgeenglish-lms-test')"
expect_stop test2 "$(with_name edgeenglish-lms)" '입력한 이름(edgeenglish-lms)이 이 DB(edgeenglish-lms-test)와 다릅니다'
RESTORE="$("${T2[@]}" -tA -f "$(with_name edgeenglish-lms-test)")"
echo "$RESTORE" | grep -q '|다름$' && { echo "$RESTORE"; echo "❌ 복구 행 수 다름"; exit 1; }
"${T2[@]}" --csv -f "$WORK/backup.sql" > "$WORK/bk2.csv"
node "$HERE/backup-compare.mjs" "$WORK/bk1.csv" "$WORK/bk2.csv"
"${T2[@]}" -o /dev/null -f "$WORK/restore-edgeenglish-lms-test.sql"
"${T2[@]}" --csv -f "$WORK/from-snapshot.sql" > "$WORK/bk3.csv"
node "$HERE/backup-compare.mjs" "$WORK/bk2.csv" "$WORK/bk3.csv"
[ "$("${T2[@]}" -tA -c "select count(*) from lms_backup.snapshots")" = "2" ] || { echo "❌ 복구 직전 저장본 수 다름"; exit 1; }
# 앱 사용자는 백업 영역을 못 봄
DENY="$("${T2[@]}" -c "set role authenticated; select count(*) from lms_backup.snapshots" 2>&1 || true)"
echo "$DENY" | grep -q 'permission denied' || { echo "❌ 로그인 사용자가 백업 영역에 접근함"; exit 1; }
# 복구 뒤에도 보호 장치가 다시 켜졌는지 (변경 이력은 지울 수 없음)
DEL="$("${T2[@]}" -c "delete from audit_log where id = (select min(id) from audit_log)" 2>&1 || true)"
echo "$DEL" | grep -q '삭제할 수 없습니다' || { echo "❌ 복구 뒤 보호 트리거가 꺼져 있음"; exit 1; }
echo "✅ 백업 → 복구 왕복·안전장치 통과 (다른 프로젝트·틀린 이름 멈춤, 복구 직전 저장본으로 되돌리기 확인)"

# 시험용 DB 적용 안내 파일 (migration 1200·1300): 확인 6줄 통과, 가상 휴무는 시험용 이름일 때만·한 번만
cp "$ROOT"/supabase/test-setup/d52-check.sql "$ROOT"/supabase/test-setup/d52-time-off.sql "$WORK"/; chmod a+r "$WORK"/d52-*.sql
for f in "$ROOT"/supabase/migrations/2026102{2001100,2001200,2001300,2001400,4001500,6001600}_*.sql; do "${PSQL[@]}" -o /dev/null -f "$f"; done   # 두 번째 적용해도 오류 없음
D52="$("${PSQL[@]}" -tA -f "$WORK/d52-check.sql")"
echo "$D52" | grep -v '|통과$' && { echo "❌ d52-check 실패"; exit 1; }
"${PSQL[@]}" -o /dev/null -f "$WORK/d52-time-off.sql"; "${PSQL[@]}" -o /dev/null -f "$WORK/d52-time-off.sql"
[ "$("${PSQL[@]}" -tA -c "select count(*) from tutor_time_off where reason = '가상 휴무 시험' and extract(dow from starts_at at time zone 'Asia/Seoul') = 3")" = "1" ] || { echo "❌ 가상 휴무 시험 데이터"; exit 1; }
"${PROD[@]}" -o /dev/null -f "$WORK/d52-time-off.sql"
[ "$("${PROD[@]}" -tA -c "select count(*) from tutor_time_off")" = "0" ] || { echo "❌ 운영 DB에 가상 휴무가 들어감"; exit 1; }
echo "✅ migration 1200·1300·1400 적용 확인 파일 통과 (확인 $(echo "$D52" | wc -l)줄, 가상 휴무는 시험용에만)"

# migration 1500 (기존 학생 입력 확대) 적용 확인 파일: 6줄 통과
cp "$ROOT"/supabase/test-setup/d52x-check.sql "$WORK"/; chmod a+r "$WORK"/d52x-check.sql
D52X="$("${PSQL[@]}" -tA -f "$WORK/d52x-check.sql")"
echo "$D52X" | grep -v '|통과$' && { echo "❌ d52x-check 실패"; exit 1; }
echo "✅ migration 1500 적용 확인 파일 통과 (확인 $(echo "$D52X" | wc -l)줄)"

# migration 1600 (기존 학생 입력 시안 2) 적용 확인 파일: 4줄 통과
cp "$ROOT"/supabase/test-setup/d52y-check.sql "$WORK"/; chmod a+r "$WORK"/d52y-check.sql
D52Y="$("${PSQL[@]}" -tA -f "$WORK/d52y-check.sql")"
echo "$D52Y" | grep -v '|통과$' && { echo "❌ d52y-check 실패"; exit 1; }
echo "✅ migration 1600 적용 확인 파일 통과 (확인 $(echo "$D52Y" | wc -l)줄)"

# migration 1700 (수업 변경·보강·되돌리기·안내 기록) 적용 확인 파일: 5줄 통과, 두 번 적용해도 오류 없음
"${PSQL[@]}" -o /dev/null -f "$ROOT/supabase/migrations/20261026001700_lms_lesson_change.sql"
cp "$ROOT"/supabase/test-setup/c17-check.sql "$WORK"/; chmod a+r "$WORK"/c17-check.sql
C17="$("${PSQL[@]}" -tA -f "$WORK/c17-check.sql")"
echo "$C17" | grep -v '|통과$' && { echo "❌ c17-check 실패"; exit 1; }
"${PROD[@]}" -tA -f "$WORK/c17-check.sql" | grep -v '|통과$' && { echo "❌ 운영 묶음 c17-check 실패"; exit 1; }
echo "✅ migration 1700 적용 확인 파일 통과 (확인 $(echo "$C17" | wc -l)줄, 다시 적용해도 오류 없음)"
