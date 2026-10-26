'use client';

// 실제 데이터로 수업 변경·보강 (migration 1700). 화면은 편의이고 권한·판정·중복 방지는 DB 함수가 다시 확인 (is_admin = aal2)

import { useEffect, useMemo, useState } from 'react';
import {
  changeLesson, confirmMakeup, loadChangeStudents, loadStudentLessons, markLessonNoticeSent, requestMakeup, revertChange, voidMakeup, withdrawMakeup,
} from '@/lms/admin/lesson-change-live';
import type { ChStudent } from '@/lms/admin/lesson-change';
import { supabaseBrowser } from '@/lms/auth/client';
import LessonChange, { type ChangeActions } from './LessonChange';

type State = { kind: 'loading' } | { kind: 'error'; message: string } | { kind: 'ready'; nowIso: string; students: ChStudent[] };

export default function ChangeLive({ code }: { code?: string }) {
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
        setState({ kind: 'ready', nowIso: new Date().toISOString(), students: await loadChangeStudents(sb) });
      } catch (e) {
        setState({ kind: 'error', message: e instanceof Error ? e.message : '데이터를 읽지 못했어요.' });
      }
    })();
  }, [sb]);

  const actions = useMemo<ChangeActions | null>(
    () =>
      sb && {
        load: (id) => loadStudentLessons(sb, id),
        change: (rid, lid, who, at, dry) => changeLesson(sb, rid, lid, who, at, dry),
        revert: (id, note) => revertChange(sb, id, note),
        requestMakeup: (src, slots) => requestMakeup(sb, src, slots),
        confirmMakeup: (id, at) => confirmMakeup(sb, id, at),
        withdrawMakeup: (id) => withdrawMakeup(sb, id),
        voidMakeup: (id, note) => voidMakeup(sb, id, note),
        markSent: (id) => markLessonNoticeSent(sb, id),
      },
    [sb],
  );

  if (state.kind === 'loading') return <p className="px-6 py-16 text-center text-[15px] text-[#6b6880]">불러오는 중…</p>;
  if (state.kind === 'error' || !actions) return <p className="px-6 py-16 text-center text-[15px] text-[#b3261e]">{state.kind === 'error' ? state.message : ''}</p>;
  return <LessonChange students={state.students} actions={actions} nowIso={state.nowIso} initialCode={code} />;
}
