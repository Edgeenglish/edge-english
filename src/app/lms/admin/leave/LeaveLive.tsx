'use client';

// 실제 데이터로 강사 휴무 처리 (migration 1800). 화면은 편의이고 권한·검사·중복 방지는 DB 함수가 다시 확인 (is_admin = aal2)

import { useEffect, useMemo, useState } from 'react';
import { markLessonNoticeSent, requestMakeup } from '@/lms/admin/lesson-change-live';
import { chooseLeave, createLeave, leaveBack, loadRenewals, loadLeaveItems, loadLeaves, loadTutors, makeupOptions, studentOk, subOptions, subTutorOk, type LvTutor } from '@/lms/admin/tutor-leave-live';
import { supabaseBrowser } from '@/lms/auth/client';
import TutorLeave, { type LeaveActions } from './TutorLeave';

type State = { kind: 'loading' } | { kind: 'error'; message: string } | { kind: 'ready'; nowIso: string; tutors: LvTutor[] };

export default function LeaveLive({ offId }: { offId?: string }) {
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
        setState({ kind: 'ready', nowIso: new Date().toISOString(), tutors: await loadTutors(sb) });
      } catch (e) {
        setState({ kind: 'error', message: e instanceof Error ? e.message : '데이터를 읽지 못했어요.' });
      }
    })();
  }, [sb]);

  const actions = useMemo<LeaveActions | null>(
    () =>
      sb && {
        leaves: (now) => loadLeaves(sb, now),
        items: (id) => loadLeaveItems(sb, id),
        create: (t, f, to, r, dry) => createLeave(sb, t, f, to, r, dry),
        choose: (ids, c, sub) => chooseLeave(sb, ids, c, sub),
        subOk: (ids) => subTutorOk(sb, ids),
        studentOk: (ids) => studentOk(sb, ids),
        back: (ids, to) => leaveBack(sb, ids, to),
        renewals: (id) => loadRenewals(sb, id),
        subOptions: (ids) => subOptions(sb, ids),
        makeupOptions: (ids) => makeupOptions(sb, ids),
        requestMakeup: (src, slots) => requestMakeup(sb, src, slots),
        markSent: async (ids) => {
          for (const id of ids) await markLessonNoticeSent(sb, id);
        },
      },
    [sb],
  );

  if (state.kind === 'loading') return <p className="px-6 py-16 text-center text-[15px] text-[#6b6880]">불러오는 중…</p>;
  if (state.kind === 'error' || !actions) return <p className="px-6 py-16 text-center text-[15px] text-[#b3261e]">{state.kind === 'error' ? state.message : ''}</p>;
  return <TutorLeave tutors={state.tutors} actions={actions} nowIso={state.nowIso} initialOff={offId} />;
}
