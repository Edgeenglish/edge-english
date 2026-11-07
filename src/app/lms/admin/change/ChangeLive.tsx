'use client';

// 실제 데이터로 수업 변경·보강 (migration 1700). 화면은 편의이고 권한·판정·중복 방지는 DB 함수가 다시 확인 (is_admin = aal2)

import { useEffect, useMemo, useState } from 'react';
import {
  adjustCredit, changeLesson, confirmMakeup, recordPastMakeup, loadChangeStudents, loadCredits, loadStudentLessons, markLessonNoticeSent, requestMakeup, revertChange, voidMakeup, withdrawMakeup,
} from '@/lms/admin/lesson-change-live';
import type { ChStudent } from '@/lms/admin/lesson-change';
import { pendingHref, trackSave } from '@/lms/admin/pending-saves';
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
        // 저장은 '저장 중 기록'으로 감싸서 화면을 떠나도 결과가 남게 (R-20). 미리 보기(dry)는 기록 안 함
        change: (rid, lid, who, at, dry) => dry ? changeLesson(sb, rid, lid, who, at, dry)
          : trackSave({ label: `수업 취소 저장 (${who === 'student' ? '학생' : '강사'} 사정)`, href: pendingHref(), verify: { kind: 'cancel', lessonId: lid } }, () => changeLesson(sb, rid, lid, who, at, dry)),
        revert: (id, note) => trackSave({ label: '취소 되돌리기', href: pendingHref(), verify: { kind: 'revert', changeId: id } }, () => revertChange(sb, id, note)),
        requestMakeup: (src, slots) => trackSave({ label: '보강 신청', href: pendingHref(), verify: { kind: 'request_makeup', lessonId: src.lessonId ?? null, itemId: src.itemId ?? null, compId: src.compId ?? null } }, () => requestMakeup(sb, src, slots)),
        recordPastMakeup: (src, at, note) => trackSave({ label: '이미 진행한 보강 기록', href: pendingHref(), verify: { kind: 'request_makeup', lessonId: src.lessonId ?? null, itemId: src.itemId ?? null, compId: null } }, () => recordPastMakeup(sb, src, at, note)),
        confirmMakeup: (id, at) => trackSave({ label: '보강 확정', href: pendingHref(), verify: { kind: 'confirm_makeup', requestId: id } }, () => confirmMakeup(sb, id, at)),
        withdrawMakeup: (id) => trackSave({ label: '보강 신청 닫기', href: pendingHref(), verify: { kind: 'withdraw_makeup', requestId: id } }, () => withdrawMakeup(sb, id)),
        voidMakeup: (id, note) => trackSave({ label: '보강 삭제', href: pendingHref(), verify: { kind: 'void_makeup', lessonId: id } }, () => voidMakeup(sb, id, note)),
        markSent: (id) => trackSave({ label: '안내 보냄 기록', href: pendingHref(), verify: { kind: 'mark_sent', noticeId: id } }, () => markLessonNoticeSent(sb, id)),
        loadCredits: (id) => loadCredits(sb, id),
        adjustCredit: (id, delta, reason) => trackSave({ label: `변경권 ${delta > 0 ? '+1' : '−1'}`, href: pendingHref(), verify: { kind: 'adjust_credit', studentId: id, delta, reason: reason.trim() } }, () => adjustCredit(sb, id, delta, reason)),
      },
    [sb],
  );

  if (state.kind === 'loading') return <p className="px-6 py-16 text-center text-[15px] text-[#6b6880]">불러오는 중…</p>;
  if (state.kind === 'error' || !actions) return <p className="px-6 py-16 text-center text-[15px] text-[#b3261e]">{state.kind === 'error' ? state.message : ''}</p>;
  return <LessonChange students={state.students} actions={actions} nowIso={state.nowIso} initialCode={code} />;
}
