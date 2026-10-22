'use client';

// 실제 데이터(시험용 Supabase)로 강사·시간 고르기. 권한은 DB가 확인 (is_admin = aal2)

import { useEffect, useMemo, useState } from 'react';
import { loadAssignInfo, planActions, proposeSchedule } from '@/lms/admin/confirm-live';
import type { RegTutor } from '@/lms/admin/registration';
import { loadRegTutors } from '@/lms/admin/registration-live';
import { supabaseBrowser } from '@/lms/auth/client';
import AssignSchedule, { type AssignInfo } from './AssignSchedule';

type State = { kind: 'loading' } | { kind: 'error'; message: string } | { kind: 'ready'; nowIso: string; info: AssignInfo; tutors: RegTutor[] };

export default function AssignLive({ enrollmentId }: { enrollmentId: string }) {
  const [state, setState] = useState<State>({ kind: 'loading' });
  const sb = supabaseBrowser();
  const actions = useMemo(() => (sb ? planActions(sb) : undefined), [sb]);

  useEffect(() => {
    if (!sb)
      return setState({
        kind: 'error',
        message: '시험용 Supabase 설정이 없어요 (환경 변수).',
      });
    if (!enrollmentId)
      return setState({
        kind: 'error',
        message: '어느 학생인지 모르겠어요. 처리할 일에서 다시 눌러 주세요.',
      });
    (async () => {
      const { data: session } = await sb.auth.getSession();
      if (!session.session) return window.location.replace('/lms/login');
      const [{ data: aal }, { data: admin }] = await Promise.all([sb.auth.mfa.getAuthenticatorAssuranceLevel(), sb.rpc('is_admin')]);
      if (aal?.currentLevel !== 'aal2' || admin !== true) return window.location.replace('/lms/login');
      const now = new Date();
      try {
        const [info, tutors] = await Promise.all([loadAssignInfo(sb, enrollmentId), loadRegTutors(sb, now)]);
        setState({
          kind: 'ready',
          nowIso: now.toISOString(),
          info: info as AssignInfo,
          tutors,
        });
      } catch (e) {
        setState({
          kind: 'error',
          message: e instanceof Error ? e.message : '데이터를 읽지 못했어요.',
        });
      }
    })();
  }, [sb, enrollmentId]);

  if (state.kind === 'loading') return <p className="px-6 py-16 text-center text-[15px] text-[#6b6880]">불러오는 중…</p>;
  if (state.kind === 'error') return <p className="px-6 py-16 text-center text-[15px] text-[#b3261e]">{state.message}</p>;
  return <AssignSchedule nowIso={state.nowIso} demo={false} info={state.info} tutors={state.tutors} propose={(planId, p) => proposeSchedule(sb!, enrollmentId, planId, p)} planActions={actions} />;
}
