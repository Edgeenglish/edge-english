#!/bin/bash
# 시험용 Supabase(edgeenglish-lms-test) 실물 보안 점검 — 로그인 안 한 사용자(anon)로만 접속
# 사용: bash supabase/test-setup/anon-probe.sh
# - 환경 변수 NEXT_PUBLIC_SUPABASE_URL, NEXT_PUBLIC_SUPABASE_ANON_KEY(publishable key) 필요. 키 값은 출력하지 않는다.
# - 시험용 프로젝트 주소가 아니면 바로 멈춘다 (운영 프로젝트에 실행 금지).
# - 쓰기 시도는 '가상_침입시험' 1건 추가와 없는 번호 수정·삭제뿐. 정상이라면 모두 거절된다.
set -u
TEST_HOST="kyeimjozkcqbgkepwrnv.supabase.co"
U="${NEXT_PUBLIC_SUPABASE_URL:-}"; K="${NEXT_PUBLIC_SUPABASE_ANON_KEY:-}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
B="$(mktemp)"; trap 'rm -f "$B"' EXIT
fail=0

host=$(echo "$U" | sed -E 's#^https?://([^/]+).*#\1#')
[ "$host" = "$TEST_HOST" ] || { echo "중단: 주소가 시험용 프로젝트가 아님"; exit 2; }
case "$K" in
  sb_publishable_*) [ ${#K} -ge 30 ] && ! printf '%s' "$K" | grep -q '[^A-Za-z0-9_-]' || { echo "중단: publishable key 형식이 아님 (설명 문구·일부만 복사됐는지 확인)"; exit 2; } ;;
  sb_secret_*) echo "중단: 비밀키(sb_secret_)가 들어 있음 — publishable key로 바꿔 주세요"; exit 2 ;;
  eyJ*) ;;
  *) echo "중단: 키 형식을 알 수 없음"; exit 2 ;;
esac

req() { # method path [json]
  if [ -n "${3:-}" ]; then
    curl -sS -o "$B" -w '%{http_code}' -X "$1" "$U$2" -H "apikey: $K" -H "Content-Type: application/json" -H "Prefer: return=minimal" -d "$3"
  else
    curl -sS -o "$B" -w '%{http_code}' -X "$1" "$U$2" -H "apikey: $K"
  fi
}
msg() { python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print(open(sys.argv[1]).read()[:100]); sys.exit()
print(d.get("code"), (d.get("message") or "")[:80]) if isinstance(d,dict) else print("배열", len(d))' "$B"; }
denied() { [ "$1" = 401 ] || [ "$1" = 403 ] || { [ "$1" != 200 ] && [ "$1" != 201 ] && [ "$1" != 204 ] && grep -q '42501' "$B"; }; }
ok()  { echo "  통과  $*"; }
bad() { echo "  실패  $*"; fail=1; }

echo "1. 접속"
c=$(req GET "/rest/v1/class_status_rules?select=code&limit=1")
if grep -q 'Invalid API key' "$B"; then echo "  실패  키가 거절됨 (Invalid API key) — 환경 변수 값 확인"; exit 1; fi
echo "  응답 $c — 키 인정됨"

echo "2. 표·뷰 읽기 (데이터가 0건이거나 거절돼야 통과)"
for t in $(grep -oiE "create (table|view|or replace view) (if not exists )?(public\.)?[a-z_]+" "$ROOT/supabase/test-setup/schema_all.sql" | awk '{print $NF}' | sed 's/public\.//' | sort -u); do
  c=$(req GET "/rest/v1/$t?select=*&limit=5")
  if [ "$c" = 200 ]; then
    n=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$B")
    [ "$n" = 0 ] && ok "$t (0건)" || bad "$t 에서 ${n}건 보임"
  elif denied "$c"; then ok "$t (거절 $c)"; else bad "$t 응답 $c $(msg)"; fi
done

echo "3. 함수 실행 (거절돼야 통과)"
Z=00000000-0000-0000-0000-000000000000
for f in "add_business_days|{\"p_from\":\"2026-10-16\",\"p_n\":3}" "is_admin|{}" "my_student_id|{}" "my_tutor_id|{}" \
         "student_my_tutors|{}" "tutor_my_students|{}" "credit_balance|{\"p_period\":\"$Z\"}" "reward_balance|{\"p_student\":\"$Z\"}" \
         "consent_record|{\"p_request\":\"$Z\",\"p_action\":\"agree\"}"; do
  n=${f%%|*}; c=$(req POST "/rest/v1/rpc/$n" "${f#*|}")
  denied "$c" && ok "$n (거절 $c)" || bad "$n 응답 $c $(msg)"
done

echo "4. 쓰기 (거절돼야 통과)"
c=$(req POST /rest/v1/students '{"name_ko":"가상_침입시험"}');                          denied "$c" && ok "학생 추가 (거절 $c)" || bad "학생 추가 응답 $c $(msg)"
c=$(req PATCH "/rest/v1/students?id=eq.$Z" '{"name_ko":"가상_침입시험"}');              denied "$c" && ok "학생 수정 (거절 $c)" || bad "학생 수정 응답 $c $(msg)"
c=$(req DELETE "/rest/v1/students?id=eq.$Z");                                           denied "$c" && ok "학생 삭제 (거절 $c)" || bad "학생 삭제 응답 $c $(msg)"
c=$(req PATCH "/rest/v1/feature_flags?key=eq.__none__" '{"enabled":true}');             denied "$c" && ok "기능 스위치 수정 (거절 $c)" || bad "기능 스위치 수정 응답 $c $(msg)"

echo "5. 참고 (판정 없음)"
c=$(req GET /auth/v1/settings)
echo "  로그인 설정 $c: $(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("회원가입 막음=",d.get("disable_signup"),"/ 이메일 로그인=",d.get("external",{}).get("email"))' "$B" 2>/dev/null)"
c=$(req POST /graphql/v1 '{"query":"{ __schema { queryType { fields { name } } } }"}'); echo "  GraphQL $c: $(head -c 160 "$B")"

[ $fail = 0 ] && echo "결과: 모두 통과" || echo "결과: 실패 항목 있음"
exit $fail
