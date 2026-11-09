set -euo pipefail
ROOT=/home/user/edge-english
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
WORK=$(mktemp -d); chown postgres "$WORK"
R=(runuser -u postgres --)
trap '"${R[@]}" "$PGBIN/pg_ctl" -D "$WORK/data" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
"${R[@]}" "$PGBIN/initdb" -D "$WORK/data" -U postgres -A trust >/dev/null
"${R[@]}" "$PGBIN/pg_ctl" -D "$WORK/data" -o "-k $WORK -c listen_addresses='' -c timezone=UTC" -l "$WORK/log" start >/dev/null
P=("${R[@]}" psql -h "$WORK" -U postgres -d postgres -v ON_ERROR_STOP=1 -q)
cp $ROOT/docs/lms/deploy/20261109-a-makeup-renewal-prod.sql $ROOT/docs/lms/deploy/20261109-b-lesson-manage-prod.sql $WORK/; chmod a+r $WORK/*.sql
"${P[@]}" -f $ROOT/supabase/tests/stub_supabase.sql
for f in $ROOT/supabase/migrations/*.sql; do b=$(basename $f); [[ "$b" > "20261109030000_z" ]] && continue; [[ "$b" == 20261109020000* ]] && continue; "${P[@]}" -o /dev/null -f "$f"; done
echo "운영 흉내: ≤030000 적용"; "${P[@]}" -tA -c "select md5(prosrc) from pg_proc where proname='lms_notice_mail'"
"${P[@]}" -o /dev/null -f $WORK/20261109-a-makeup-renewal-prod.sql 2>&1 | grep -v NOTICE || true
"${P[@]}" -o /dev/null -f $ROOT/supabase/migrations/20261109080000_lms_tutor_cancel_entry.sql
echo "배포 A 뒤 (운영 지금):"; "${P[@]}" -tA -c "select md5(prosrc) from pg_proc where proname='lms_notice_mail'"
"${P[@]}" -o /dev/null -f $WORK/20261109-b-lesson-manage-prod.sql && echo "배포 B 1회 OK"
"${P[@]}" -o /dev/null -f $WORK/20261109-b-lesson-manage-prod.sql && echo "배포 B 2회 OK(다시 실행)"
"${P[@]}" -tA -c "select md5(prosrc) from pg_proc where proname='lms_notice_mail'"
"${P[@]}" -tA -c "select string_agg(proname, ',') from pg_proc where proname in ('admin_lesson_add','admin_lesson_edit','lms_makeup_expire_run','student_makeup_withdraw')"
