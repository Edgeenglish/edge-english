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

# 백업 → 복구 왕복: 가상 데이터가 든 DB를 백업 → 운영형 DB(대표 계정만 있음)에 복구 → 다시 백업해 표별 내용이 같은지
"${PSQL[@]}" -c "create table if not exists auth.users (id uuid primary key, email text)"
"${RUN_AS[@]}" psql -h "$WORK" -U postgres -d postgres -v ON_ERROR_STOP=1 -q --csv -f "$WORK/backup.sql" > "$WORK/bk1.csv"
node "$ROOT/scripts/lms-restore-sql.mjs" "$WORK/bk1.csv" > "$WORK/restore.sql"; chmod a+r "$WORK/restore.sql"
RESTORE="$("${PROD[@]}" -tA -f "$WORK/restore.sql")"
echo "$RESTORE" | grep -q '|다름$' && { echo "$RESTORE"; echo "❌ 복구 행 수 다름"; exit 1; }
"${PROD[@]}" --csv -f "$WORK/backup.sql" > "$WORK/bk2.csv"
node "$HERE/backup-compare.mjs" "$WORK/bk1.csv" "$WORK/bk2.csv"
# 복구 뒤에도 보호 장치가 다시 켜졌는지 (변경 이력은 지울 수 없음)
DEL="$("${PROD[@]}" -c "delete from audit_log where id = (select min(id) from audit_log)" 2>&1 || true)"
echo "$DEL" | grep -q '삭제할 수 없습니다' || { echo "❌ 복구 뒤 보호 트리거가 꺼져 있음"; exit 1; }
echo "✅ 백업 → 복구 왕복 통과"
