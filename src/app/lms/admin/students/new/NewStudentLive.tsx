'use client';

// 실제 데이터(시험용 Supabase)로 신규 학생 등록. 화면에서 막는 것은 편의이고, 권한은 DB가 확인 (is_admin = aal2)

import { useCallback, useEffect, useMemo, useState } from 'react';
import { planActions } from '@/lms/admin/confirm-live';
import { loadRegTutors, saveRegistration, studentsWithEmail } from '@/lms/admin/registration-live';
import type { RegTutor } from '@/lms/admin/registration';
import { supabaseBrowser } from '@/lms/auth/client';
import NewStudent from './NewStudent';

type State = { kind: 'loading' } | { kind: 'error'; message: string } | { kind: 'ready'; nowIso: string; tutors: RegTutor[] };

export default function NewStudentLive() {
  const [state, setState] = useState<State>({ kind: 'loading' });
  const sb = supabaseBrowser();

  useEffect(() => {
    if (!sb) return setState({ kind: 'error', message: '시험용 Supabase 설정이 없어요 (환경 변수).' });
    (async () => {
      const { data: session } = await sb.auth.getSession();
      if (!session.session) return window.location.replace('/lms/login');
      const [{ data: aal }, { data: admin }] = await Promise.all([sb.auth.mfa.getAuthenticatorAssuranceLevel(), sb.rpc('is_admin')]);
      if (aal?.currentLevel !== 'aal2' || admin !== true) return window.location.replace('/lms/login');
      const now = new Date();
      try {
        setState({ kind: 'ready', nowIso: now.toISOString(), tutors: await loadRegTutors(sb, now) });
      } catch (e) {
        setState({ kind: 'error', message: e instanceof Error ? e.message : '데이터를 읽지 못했어요.' });
      }
    })();
  }, [sb]);

  const actions = useMemo(() => (sb ? planActions(sb) : undefined), [sb]);
  const sameEmail = useCallback((email: string) => (sb ? studentsWithEmail(sb, email) : Promise.resolve([])), [sb]);

  if (state.kind === 'loading') return <p className="px-6 py-16 text-center text-[15px] text-[#6b6880]">불러오는 중…</p>;
  if (state.kind === 'error') return <p className="px-6 py-16 text-center text-[15px] text-[#b3261e]">{state.message}</p>;
  return (
    <NewStudent
      nowIso={state.nowIso}
      demo={false}
      applications={[]}
      applicationsNote="신청서(구글폼 응답) 연결 전이라 직접 입력만 돼요. 연결 방식은 승인 후 붙여요."
      tutors={state.tutors}
      save={(id, payload) => saveRegistration(sb!, id, payload)}
      sameEmail={sameEmail}
      planActions={actions}
    />
  );
}
