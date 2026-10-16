-- =====================================================================
-- LMS 수업 안내 확인·동의 (초안 v0.1) — POL-OP-12 변경 제안, docs/lms/10-terms-consent-design.md
-- 대표 승인(D-22~D-25) 전에는 어떤 Supabase에도 적용하지 않는다.
--
-- 원칙
-- - 문서 원본은 덮어쓰지 않는다. 고치면 새 판(terms_versions) 또는 새 revision.
-- - 동의는 학생 본인만, 서버 함수로만 기록한다. 운영자도 대신 동의할 수 없다.
-- - 동의 기록은 고치거나 지울 수 없다. 철회·재확인도 새 줄로 쌓는다.
-- - 동의하지 않았다고 수업·등록을 막지 않는다 (lessons·enrollments 에 연결된 제약 없음).
-- - 예전 계약·안내서 근거(terms_deliveries)는 그대로 두고, 이 표들은 LMS 온라인 동의만 기록한다.
-- =====================================================================

-- 학생에게 실제로 보여 준 문서 원본
create table terms_documents (
  id uuid primary key default gen_random_uuid(),
  terms_code text not null references terms_versions(code),
  revision smallint not null default 1 check (revision > 0),  -- 오탈자 수정도 새 revision (이전 것은 그대로 남음)
  format text not null check (format in ('text', 'image_set')),
  body_md text,                            -- 학생 화면에 보여 준 텍스트 원문
  assets jsonb not null default '[]',      -- 이미지 원본 [{page, path, sha256}] — 비공개 저장소 경로
  required_items jsonb not null default '[]',  -- 필수 체크 항목 [{key, text}]
  optional_items jsonb not null default '[]',  -- 선택 항목 (예: 마케팅 수신) — 수강규정과 섞지 않음
  content_sha256 text not null default '', -- 위 4개로 DB가 계산 (앱이 넣은 값은 무시)
  status text not null default 'draft' check (status in ('draft', 'published', 'retired')),
  published_at timestamptz,
  published_by uuid,
  created_at timestamptz not null default now(),
  unique (terms_code, revision),
  check (format <> 'text' or body_md is not null),
  check (format <> 'image_set' or jsonb_array_length(assets) > 0),
  check ((status = 'draft') = (published_at is null))
);

create or replace function terms_document_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and old.status <> 'draft' then
    -- 게시된 문서는 내용을 바꿀 수 없고, 게시 → 내림(retired)만 가능
    if (new.body_md, new.assets, new.required_items, new.optional_items, new.format, new.terms_code, new.revision)
       is distinct from (old.body_md, old.assets, old.required_items, old.optional_items, old.format, old.terms_code, old.revision)
       or not (new.status = 'retired' or new.status = old.status) then
      raise exception '게시된 안내 문서는 고칠 수 없습니다. 새 판을 만드세요.';
    end if;
  end if;
  new.content_sha256 := encode(sha256(convert_to(
    coalesce(new.body_md, '') || new.assets::text || new.required_items::text || new.optional_items::text, 'UTF8')), 'hex');
  return new;
end $$;
create trigger terms_document_guard before insert or update on terms_documents for each row execute function terms_document_guard();
create trigger terms_documents_no_delete before delete on terms_documents for each row execute function forbid_delete();

-- 운영자가 학생에게 보낸 확인 요청 (등록 1건 × 문서 1건)
create table consent_requests (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  enrollment_id uuid not null references enrollments(id),
  document_id uuid not null references terms_documents(id),
  reason text not null check (reason in ('new', 'renewal', 'reconfirm', 'policy_change')),
  required boolean not null default true,  -- 마케팅 등 선택 문서는 false
  created_by uuid,
  created_at timestamptz not null default now(),
  canceled_at timestamptz,                 -- 잘못 보낸 요청 취소 (줄은 남김)
  cancel_note text,
  unique (enrollment_id, document_id),
  check ((canceled_at is null) = (cancel_note is null))
);

create or replace function consent_request_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if not exists (select 1 from enrollments where id = new.enrollment_id and student_id = new.student_id) then
      raise exception '학생과 수강등록의 학생이 다릅니다.';
    end if;
    if not exists (select 1 from terms_documents where id = new.document_id and status = 'published') then
      raise exception '게시된 문서만 요청할 수 있습니다.';
    end if;
  elsif (new.student_id, new.enrollment_id, new.document_id, new.reason, new.required, new.created_at)
        is distinct from (old.student_id, old.enrollment_id, old.document_id, old.reason, old.required, old.created_at)
        or old.canceled_at is not null then
    raise exception '확인 요청은 취소만 할 수 있습니다.';
  end if;
  return new;
end $$;
create trigger consent_request_guard before insert or update on consent_requests for each row execute function consent_request_guard();
create trigger consent_requests_no_delete before delete on consent_requests for each row execute function forbid_delete();

-- 열람·동의·철회 기록 (쌓기만 함)
create table consent_events (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references consent_requests(id),
  action text not null check (action in ('viewed', 'accepted', 'withdrawn')),
  checked_items text[] not null default '{}',  -- 학생이 직접 체크한 항목 key
  document_sha256 text not null,           -- 그 순간 보여 준 문서 해시
  acted_at timestamptz not null default now(),  -- 서버 시각 (학생 기기 시각을 쓰지 않음)
  actor_auth_id uuid not null,
  actor_role text not null check (actor_role in ('student', 'admin')),
  note text,                               -- 철회 사유 등 (이름·연락처 적지 않음)
  check (action <> 'accepted' or actor_role = 'student'),   -- 동의는 학생 본인만
  check (action <> 'withdrawn' or actor_role = 'student' or note is not null)
);
create trigger consent_events_no_update before update on consent_events for each row execute function forbid_update();
create trigger consent_events_no_delete before delete on consent_events for each row execute function forbid_delete();

select lms_protect(t::regclass) from unnest(array['terms_documents', 'consent_requests', 'consent_events']) as t;

create policy everyone_read on terms_documents for select to authenticated using (status <> 'draft');
create policy student_own on consent_requests for select to authenticated using (student_id = my_student_id());
create policy student_own on consent_events for select to authenticated
  using (request_id in (select id from consent_requests where student_id = my_student_id()));

-- ---------------------------------------------------------------------
-- 학생 화면에서 부르는 함수 (로그인한 본인 확인은 DB가 직접 함)
-- ---------------------------------------------------------------------

create or replace function consent_record(p_request uuid, p_action text, p_items text[] default '{}', p_note text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  r consent_requests;
  d terms_documents;
  me uuid := my_student_id();
  role text;
  required_keys text[];
  allowed_keys text[];
  last_action text;
  new_id uuid;
begin
  select * into r from consent_requests where id = p_request;
  if r.id is null or r.canceled_at is not null then raise exception '확인 요청을 찾을 수 없습니다.'; end if;

  if me is not null and r.student_id = me then
    role := 'student';
  elsif is_admin() and p_action = 'withdrawn' then
    role := 'admin';                       -- 학생이 카톡 등으로 철회를 요청했을 때 운영자가 대신 기록 (사유 필수)
  else
    raise exception '본인의 확인 요청이 아닙니다.';   -- 다른 학생·강사·운영자의 대신 동의 차단
  end if;

  select * into d from terms_documents where id = r.document_id;
  if d.status <> 'published' and p_action = 'accepted' then raise exception '내려간 문서에는 새로 동의할 수 없습니다.'; end if;

  select action into last_action from consent_events
   where request_id = r.id and action <> 'viewed' order by acted_at desc, id desc limit 1;

  if p_action = 'accepted' then
    select coalesce(array_agg(x->>'key'), '{}') into required_keys from jsonb_array_elements(d.required_items) x;
    select coalesce(array_agg(x->>'key'), '{}') into allowed_keys
      from jsonb_array_elements(d.required_items || d.optional_items) x;
    if not (required_keys <@ p_items) then raise exception '필수 항목을 모두 체크해야 합니다.'; end if;
    if not (p_items <@ allowed_keys) then raise exception '문서에 없는 항목입니다.'; end if;
    if last_action = 'accepted' then
      return (select id from consent_events where request_id = r.id and action = 'accepted' order by acted_at desc, id desc limit 1);
    end if;
  elsif p_action = 'withdrawn' then
    if last_action is distinct from 'accepted' then raise exception '동의한 상태가 아닙니다.'; end if;
    p_items := '{}';
  elsif p_action = 'viewed' then
    p_items := '{}';
  else
    raise exception '알 수 없는 동작입니다.';
  end if;

  insert into consent_events (request_id, action, checked_items, document_sha256, actor_auth_id, actor_role, note)
  values (r.id, p_action, p_items, d.content_sha256, auth.uid(), role, p_note)
  returning id into new_id;
  return new_id;
end $$;
revoke all on function consent_record(uuid, text, text[], text) from public, anon;
grant execute on function consent_record(uuid, text, text[], text) to authenticated;

-- 운영자 현황: 요청마다 마지막 상태 (RLS 를 그대로 따름 — 학생은 본인 것만)
create view consent_status with (security_invoker = true) as
select r.id as request_id, r.student_id, r.enrollment_id, r.document_id, d.terms_code, d.revision, r.reason, r.required,
       r.created_at as requested_at, r.canceled_at,
       (select e.action from consent_events e where e.request_id = r.id and e.action <> 'viewed'
         order by e.acted_at desc, e.id desc limit 1) as last_action,
       (select max(e.acted_at) from consent_events e where e.request_id = r.id and e.action = 'accepted') as accepted_at,
       (select min(e.acted_at) from consent_events e where e.request_id = r.id and e.action = 'viewed') as first_viewed_at
from consent_requests r join terms_documents d on d.id = r.document_id;
grant select on consent_status to authenticated;
