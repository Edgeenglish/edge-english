'use client';

// 실제 데이터로 기존 학생 입력. 화면 검사는 편의이고, 권한·충돌은 DB가 다시 확인 (is_admin = aal2). 저장 뒤 시트 대조 완료 기록

import { useEffect, useState } from 'react';
import { markImportChecked, saveImport } from '@/lms/admin/import-live';
import { loadRegTutors } from '@/lms/admin/registration-live';
import type { RegTutor } from '@/lms/admin/registration';
import { supabaseBrowser } from '@/lms/auth/client';
import ImportStudent from './ImportStudent';

type State = { kind: 'loading' } | { kind: 'error'; message: string } | { kind: 'ready'; nowIso: string; tutors: RegTutor[] };

export default function ImportLive() {
  const [state, setState] = useState<State>({ kind: 'loading' });
  const sb = supabaseBrowser();

  useEffect(() => {
    if (!sb) return setState({ kind: 'error', message: 'Supabase 설정이 없어요 (환경 변수).' });
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

  if (state.kind === 'loading') return <p className="px-6 py-16 text-center text-[15px] text-[#6b6880]">불러오는 중…</p>;
  if (state.kind === 'error') return <p className="px-6 py-16 text-center text-[15px] text-[#b3261e]">{state.message}</p>;
  const reload = async () => {
    const tutors = await loadRegTutors(sb!, new Date(state.nowIso));
    setState({ ...state, tutors });
  };
  return <ImportStudent nowIso={state.nowIso} demo={false} tutors={state.tutors} save={(id, payload) => saveImport(sb!, id, payload)} reload={reload} markChecked={(id) => markImportChecked(sb!, id)} />;
}
