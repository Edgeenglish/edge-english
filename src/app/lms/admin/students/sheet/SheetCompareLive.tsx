'use client';

// ⑤ 시트 비교 실제 데이터 (migration 4310). 운영자(TOTP까지)만 — 쓰기는 DB 함수(admin_student_update·admin_sheet_row_*)
import { useCallback, useEffect, useMemo, useState } from 'react';
import { doneSheetRow, loadSheetRows, loadStudentDetail, loadStudents, matchSheetRow, updateStudent } from '@/lms/admin/students-live';
import type { SheetRow } from '@/lms/admin/sheet-compare';
import type { StudentRow } from '@/lms/admin/students';
import { supabaseBrowser } from '@/lms/auth/client';
import SheetCompare, { type SheetActions } from './SheetCompare';

type State = { kind: 'loading' } | { kind: 'error'; message: string } | { kind: 'ready'; rows: SheetRow[]; students: StudentRow[] };

export default function SheetCompareLive({ studentParam }: { studentParam?: string }) {
  const [state, setState] = useState<State>({ kind: 'loading' });
  const sb = supabaseBrowser();
  const load = useCallback(async () => {
    if (!sb) return;
    const [rows, students] = await Promise.all([loadSheetRows(sb), loadStudents(sb)]);
    setState({ kind: 'ready', rows, students });
  }, [sb]);
  useEffect(() => {
    if (!sb) return setState({ kind: 'error', message: 'Supabase 설정이 없어요 (환경 변수).' });
    (async () => {
      const { data: session } = await sb.auth.getSession();
      if (!session.session) return window.location.replace('/lms/login');
      const [{ data: aal }, { data: admin }] = await Promise.all([sb.auth.mfa.getAuthenticatorAssuranceLevel(), sb.rpc('is_admin')]);
      if (aal?.currentLevel !== 'aal2' || admin !== true) return window.location.replace('/lms/login');
      try { await load(); } catch (e) { setState({ kind: 'error', message: e instanceof Error ? e.message : '데이터를 읽지 못했어요.' }); }
    })();
  }, [sb, load]);
  const actions = useMemo<SheetActions | null>(() => sb && {
    reload: load,
    detail: (id) => loadStudentDetail(sb, id),
    match: (rowId, studentId) => matchSheetRow(sb, rowId, studentId),
    update: (studentId, fields) => updateStudent(sb, studentId, fields),
    done: (rowId, note, undo) => doneSheetRow(sb, rowId, note, undo),
  }, [sb, load]);
  if (state.kind === 'loading') return <p className="px-6 py-16 text-center text-[15px] text-[#6b6880]">불러오는 중…</p>;
  if (state.kind === 'error' || !actions) return <p className="px-6 py-16 text-center text-[15px] text-[#b3261e]">{state.kind === 'error' ? state.message : ''}</p>;
  const studentId = studentParam ? (state.students.find((s) => s.id === studentParam || s.code === studentParam)?.id ?? null) : null;
  return <SheetCompare rows={state.rows} students={state.students} actions={actions} studentFilter={studentId} />;
}
