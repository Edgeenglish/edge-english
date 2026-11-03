'use client';

// 운영진 학생 목록 실제 데이터 (migration 4300). 운영자(TOTP까지, aal2)만 — 화면은 편의이고 DB 함수가 다시 확인
import { useEffect, useState } from 'react';
import { loadStudents } from '@/lms/admin/students-live';
import type { StudentRow } from '@/lms/admin/students';
import { supabaseBrowser } from '@/lms/auth/client';
import StudentList from './StudentList';

type State = { kind: 'loading' } | { kind: 'error'; message: string } | { kind: 'ready'; nowIso: string; rows: StudentRow[] };

export default function StudentsLive({ initialQuery, initialTab }: { initialQuery: string; initialTab?: string }) {
  const [state, setState] = useState<State>({ kind: 'loading' });
  const sb = supabaseBrowser();
  useEffect(() => {
    if (!sb) return setState({ kind: 'error', message: 'Supabase 설정이 없어요 (환경 변수).' });
    (async () => {
      const { data: session } = await sb.auth.getSession();
      if (!session.session) return window.location.replace('/lms/login');
      const [{ data: aal }, { data: admin }] = await Promise.all([sb.auth.mfa.getAuthenticatorAssuranceLevel(), sb.rpc('is_admin')]);
      if (aal?.currentLevel !== 'aal2' || admin !== true) return window.location.replace('/lms/login');
      try {
        setState({ kind: 'ready', nowIso: new Date().toISOString(), rows: await loadStudents(sb) });
      } catch (e) {
        setState({ kind: 'error', message: e instanceof Error ? e.message : '데이터를 읽지 못했어요.' });
      }
    })();
  }, [sb]);
  if (state.kind === 'loading') return <p className="px-6 py-16 text-center text-[15px] text-[#6b6880]">불러오는 중…</p>;
  if (state.kind === 'error') return <p className="px-6 py-16 text-center text-[15px] text-[#b3261e]">{state.message}</p>;
  return <StudentList rows={state.rows} nowIso={state.nowIso} initialQuery={initialQuery} initialTab={initialTab} />;
}
