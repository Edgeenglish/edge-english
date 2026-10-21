-- =====================================================================
-- 권한 정리 2차 (2026-10-17 로그인 사용자 권한 점검 authz-probe 결과)
-- Supabase 는 public 에 새로 만든 표·보기·시퀀스에 anon·authenticated 모든 권한을 자동으로 준다.
-- 표는 lms_protect 가 막았지만 아래 두 가지가 남아 있었다 (데이터가 새지는 않음, 미리 닫음):
--   - consent_status 보기: 추가·수정·삭제 권한이 남아 있음 (보기가 RLS를 따르고 원본 표가 막혀 실제 쓰기는 안 됨)
--   - audit_log_id_seq: 앱 사용자가 이력 번호를 건드릴 수 있음 (REST API로는 못 부르지만 닫음)
-- 그리고 표 보호용 내부 함수 lms_protect 를 로그인 사용자 실행 목록에서 뺀다 (불러도 소유자가 아니라 실패하지만 닫음).
-- 다시 실행해도 같은 결과 (권한 회수·부여만 함, 데이터 변경 없음)
-- =====================================================================

revoke all on consent_status from anon, authenticated;
grant select on consent_status to authenticated;   -- security_invoker: 실제로 보이는 행은 원본 표의 RLS 대로

revoke all on all sequences in schema public from anon, authenticated;

revoke execute on function lms_protect(regclass) from authenticated;

-- 앞으로 만드는 표·보기·시퀀스도 앱 사용자에게 자동으로 열리지 않게 (필요한 읽기 권한은 lms_protect·각 파일에서 직접 부여)
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
