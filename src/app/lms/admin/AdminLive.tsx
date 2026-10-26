'use client';

// 운영자 확인 후 실제 데이터로 대시보드 표시
// 화면에서 막는 것은 편의일 뿐, 실제로는 DB가 막는다 (is_admin 은 aal2 에서만 참 — migration 800)

import { useEffect, useMemo, useState } from 'react';
import type { TaskSource } from '@/lms/admin/board';
import type { FakeLesson, OpsStats } from '@/lms/admin/fake-data';
import { planActions } from '@/lms/admin/confirm-live';
import { loadAdminBoard, loadOpsStats } from '@/lms/admin/live';
import { markImportChecked, setImportEndReason, setImportOrigin } from '@/lms/admin/import-live';
import { supabaseBrowser } from '@/lms/auth/client';
import AdminDashboard from './AdminDashboard';

type State = { kind: 'loading' } | { kind: 'error'; message: string } | { kind: 'ready'; nowIso: string; tasks: TaskSource[]; today: FakeLesson[]; stats: OpsStats | null };

export default function AdminLive() {
  const [state, setState] = useState<State>({ kind: 'loading' });
  const sb = supabaseBrowser();
  const actions = useMemo(() => (sb ? planActions(sb) : undefined), [sb]);
  const imports = useMemo(
    () =>
      sb
        ? {
            markChecked: (id: string) => markImportChecked(sb, id),
            setOrigin: (id: string, date: string | null) => setImportOrigin(sb, id, date),
            setEndReason: (id: string, reason: string, note: string) => setImportEndReason(sb, id, reason, note),
          }
        : undefined,
    [sb],
  );

  // 처리 뒤 다시 읽기 (화면 깜빡임 없이 목록만 바꿈)
  async function reload() {
    if (!sb) return;
    const now = new Date();
    const board = await loadAdminBoard(sb, now);
    setState((s) => (s.kind === 'ready' ? { ...s, nowIso: now.toISOString(), ...board } : s));
  }

  useEffect(() => {
    if (!sb) {
      setState({ kind: 'error', message: '시험용 Supabase 설정이 없어요 (환경 변수).' });
      return;
    }
    (async () => {
      const { data: session } = await sb.auth.getSession();
      if (!session.session) return window.location.replace('/lms/login');
      const [{ data: aal }, { data: admin }] = await Promise.all([sb.auth.mfa.getAuthenticatorAssuranceLevel(), sb.rpc('is_admin')]);
      // TOTP 전이거나 운영자가 아니면 로그인 화면으로 (거기서 인증 앱 코드 또는 역할별 화면으로 안내)
      if (aal?.currentLevel !== 'aal2' || admin !== true) return window.location.replace('/lms/login');
      const now = new Date();
      try {
        const [board, stats] = await Promise.all([loadAdminBoard(sb, now), loadOpsStats(sb, now)]);
        setState({ kind: 'ready', nowIso: now.toISOString(), ...board, stats });
      } catch (e) {
        setState({ kind: 'error', message: e instanceof Error ? e.message : '데이터를 읽지 못했어요.' });
      }
    })();
  }, [sb]);

  async function logout() {
    await sb?.auth.signOut();
    window.location.replace('/lms/login');
  }

  if (state.kind === 'loading') return <p className="px-6 py-16 text-center text-[15px] text-[#6b6880]">불러오는 중…</p>;
  if (state.kind === 'error')
    return (
      <div className="px-6 py-16 text-center">
        <p className="text-[15px] text-[#b3261e]">{state.message}</p>
        <button type="button" onClick={logout} className="mt-4 min-h-[44px] rounded-[10px] border border-[#e6e3ef] px-4 text-[14px] text-[#1d1b2b]">
          로그아웃
        </button>
      </div>
    );
  return (
    <AdminDashboard
      nowIso={state.nowIso}
      today={state.today}
      tasks={state.tasks}
      stats={state.stats}
      preview={false}
      onLogout={logout}
      planActions={actions}
      importActions={imports}
      onReload={reload}
    />
  );
}
