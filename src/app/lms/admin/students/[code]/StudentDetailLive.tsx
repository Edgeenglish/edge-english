'use client';

// 학생 상세 실제 데이터 (migration 4300). 쓰기는 모두 DB 함수(운영자 aal2 확인·검사·기록은 DB)
import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  extendEnrollment, findStudentId, loadStudentDetail, markRegularChangeSent, previewRegularChange, saveRegularChange, updateStudent,
} from '@/lms/admin/students-live';
import type { StudentDetailData } from '@/lms/admin/students';
import { supabaseBrowser } from '@/lms/auth/client';
import StudentDetail, { type DetailActions } from './StudentDetail';

type State = { kind: 'loading' } | { kind: 'error'; message: string } | { kind: 'ready'; nowIso: string; id: string; data: StudentDetailData };

export default function StudentDetailLive({ code }: { code: string }) {
  const [state, setState] = useState<State>({ kind: 'loading' });
  const sb = supabaseBrowser();

  const load = useCallback(async (id: string) => {
    if (!sb) return;
    const data = await loadStudentDetail(sb, id);
    setState({ kind: 'ready', nowIso: new Date().toISOString(), id, data });
  }, [sb]);

  useEffect(() => {
    if (!sb) return setState({ kind: 'error', message: 'Supabase 설정이 없어요 (환경 변수).' });
    (async () => {
      const { data: session } = await sb.auth.getSession();
      if (!session.session) return window.location.replace('/lms/login');
      const [{ data: aal }, { data: admin }] = await Promise.all([sb.auth.mfa.getAuthenticatorAssuranceLevel(), sb.rpc('is_admin')]);
      if (aal?.currentLevel !== 'aal2' || admin !== true) return window.location.replace('/lms/login');
      try {
        const id = await findStudentId(sb, code);
        if (!id) return setState({ kind: 'error', message: `${code} 학생을 찾을 수 없어요.` });
        await load(id);
      } catch (e) {
        setState({ kind: 'error', message: e instanceof Error ? e.message : '데이터를 읽지 못했어요.' });
      }
    })();
  }, [sb, code, load]);

  const id = state.kind === 'ready' ? state.id : null;
  const actions = useMemo<DetailActions | null>(() => sb && id ? {
    reload: () => load(id),
    update: (fields) => updateStudent(sb, id, fields),
    preview: (slots, from) => previewRegularChange(sb, id, slots, from),
    save: (slots, from, reason) => saveRegularChange(sb, id, slots, from, reason),
    sent: (changeId, who, undo) => markRegularChangeSent(sb, changeId, who, undo),
    extend: (enrollmentId, newEnd, kind, note) => extendEnrollment(sb, enrollmentId, newEnd, kind, note),
  } : null, [sb, id, load]);

  if (state.kind === 'loading') return <p className="px-6 py-16 text-center text-[15px] text-[#6b6880]">불러오는 중…</p>;
  if (state.kind === 'error' || !actions) return <p className="px-6 py-16 text-center text-[15px] text-[#b3261e]">{state.kind === 'error' ? state.message : ''}</p>;
  return <StudentDetail data={state.data} nowIso={state.nowIso} actions={actions} />;
}
