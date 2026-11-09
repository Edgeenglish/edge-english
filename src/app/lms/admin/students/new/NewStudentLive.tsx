'use client';

// 실제 데이터(시험용 Supabase)로 신규 수강생 등록. 화면에서 막는 것은 편의이고, 권한은 DB가 확인 (is_admin = aal2)

import { useCallback, useEffect, useMemo, useState } from 'react';
import { planActions } from '@/lms/admin/confirm-live';
import { loadRegTutors, saveRegistration, studentsWithEmail } from '@/lms/admin/registration-live';
import type { FormResponse, RegTutor } from '@/lms/admin/registration';
import { supabaseBrowser } from '@/lms/auth/client';
import NewStudent from './NewStudent';

type State = { kind: 'loading' } | { kind: 'error'; message: string } | { kind: 'ready'; nowIso: string; tutors: RegTutor[] };

export default function NewStudentLive() {
  const [state, setState] = useState<State>({ kind: 'loading' });
  const sb = supabaseBrowser();
  const [applications, setApplications] = useState<FormResponse[]>([]);
  const [applicationsNote, setApplicationsNote] = useState('구글폼 신청서를 불러오는 중…');

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
        try {
          const { data } = await sb.auth.getSession();
          const response = await fetch('/api/lms/applications', { method: 'POST', headers: { Authorization: `Bearer ${data.session?.access_token ?? ''}` }, cache: 'no-store' });
          const payload = await response.json();
          if (!response.ok) throw new Error(payload.error);
          setApplications(payload.applications);
          setApplicationsNote('제출일은 한국 시간 기준입니다. 신청서를 고르면 정보가 자동으로 채워집니다.');
        } catch (e) { setApplicationsNote(e instanceof Error ? e.message : '신청서를 불러오지 못했습니다. 직접 입력은 가능합니다.'); }
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
      applications={applications}
      applicationsNote={applicationsNote}
      tutors={state.tutors}
      save={(id, payload) => saveRegistration(sb!, id, payload)}
      sameEmail={sameEmail}
      planActions={actions}
    />
  );
}
