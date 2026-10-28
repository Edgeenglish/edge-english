'use client';

// 학생 화면 실제 데이터: 학생 본인(이메일 코드 로그인) 또는 운영자(TOTP 완료)가 학생을 골라 그대로 보기·대신 입력
// 화면에서 막는 것은 편의일 뿐, 실제로는 DB 함수가 막는다 (migration 2800)

import { useEffect, useMemo, useState } from 'react';
import { supabaseBrowser } from '@/lms/auth/client';
import { createStudentLogin, loadStudentAccounts, loadStudentView, studentActions, type StudentAccount, type StudentView } from '@/lms/student/live';
import StudentHome from './StudentHome';

type State =
  | { kind: 'loading' }
  | { kind: 'error'; message: string }
  | { kind: 'ready'; nowIso: string; view: StudentView; admin: { students: StudentAccount[]; studentId: string } | null };

export default function StudentLive({ studentParam }: { studentParam?: string }) {
  const [state, setState] = useState<State>({ kind: 'loading' });
  const sb = supabaseBrowser();
  const adminStudent = state.kind === 'ready' && state.admin ? state.admin.studentId : null;

  useEffect(() => {
    if (!sb) return setState({ kind: 'error', message: 'Supabase 설정이 없어요.' });
    (async () => {
      const { data: session } = await sb.auth.getSession();
      if (!session.session) return window.location.replace('/lms/login');
      const { data: role } = await sb.rpc('my_role');
      try {
        const nowIso = new Date().toISOString();
        if (role === 'student') return setState({ kind: 'ready', nowIso, view: await loadStudentView(sb, null), admin: null });
        const [{ data: aal }, { data: admin }] = await Promise.all([sb.auth.mfa.getAuthenticatorAssuranceLevel(), sb.rpc('is_admin')]);
        if (role !== 'admin' || aal?.currentLevel !== 'aal2' || admin !== true) return window.location.replace('/lms/login');
        const students = await loadStudentAccounts(sb);
        const pick = students.find((x) => x.id === studentParam || x.code === studentParam) ?? students[0];
        if (!pick) return setState({ kind: 'error', message: '등록된 학생이 없어요.' });
        setState({ kind: 'ready', nowIso, view: await loadStudentView(sb, pick.id), admin: { students, studentId: pick.id } });
      } catch (e) {
        setState({ kind: 'error', message: e instanceof Error ? e.message : '불러오지 못했어요.' });
      }
    })();
  }, [sb, studentParam]);

  const actions = useMemo(() => sb && studentActions(sb, adminStudent), [sb, adminStudent]);

  async function logout() {
    await sb?.auth.signOut();
    window.location.replace('/lms/login');
  }

  if (state.kind === 'loading') return <p className="px-6 py-16 text-center text-[15px] text-[#6b6880]">불러오는 중…</p>;
  if (state.kind === 'error' || !actions)
    return (
      <div className="px-6 py-16 text-center">
        <p className="text-[15px] text-[#b3261e]">{state.kind === 'error' ? state.message : ''}</p>
        <button type="button" onClick={logout} className="mt-4 min-h-[44px] rounded-[10px] border border-[#e6e3ef] px-4 text-[14px] text-[#1d1b2b]">
          로그아웃
        </button>
      </div>
    );
  const current = state.admin?.students.find((x) => x.id === state.admin?.studentId);
  const adminBar = state.admin && (
    <div className="mb-3 flex flex-wrap items-center gap-2 rounded-[12px] bg-[#1d1b2b] px-3 py-2">
      <span className="text-[13px] font-semibold text-white">운영자 보기</span>
      <select aria-label="학생" value={state.admin.studentId} onChange={(e) => window.location.assign(`/lms/student?student=${e.target.value}`)}
        className="min-h-[38px] flex-1 rounded-[8px] bg-white px-2 text-[15px] text-[#1d1b2b]">
        {state.admin.students.map((x) => (
          <option key={x.id} value={x.id}>{x.code} {x.name}{x.hasLogin ? '' : ' · 학생 계정 없음'}</option>
        ))}
      </select>
      <a href="/lms/admin" className="min-h-[38px] rounded-[8px] bg-white/15 px-3 py-2 text-[13px] font-semibold text-white">대시보드</a>
      {sb && current && !current.hasLogin && <StudentLoginForm onCreate={(email) => createStudentLogin(sb, current.id, email)} />}
    </div>
  );
  return (
    <StudentHome
      key={state.view.studentId}
      nowIso={state.nowIso}
      initial={state.view}
      actions={actions}
      preview={false}
      adminBar={adminBar}
      onLogout={state.admin ? undefined : logout}
    />
  );
}

// 대표: 이 학생의 로그인 계정 만들기 (이메일만 넣으면 계정 + 학생 연결, 비밀번호 없음 — 학생은 이메일 코드로 로그인)
function StudentLoginForm({ onCreate }: { onCreate: (email: string) => Promise<{ created: boolean }> }) {
  const [email, setEmail] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  async function submit() {
    setBusy(true);
    setMsg(null);
    try {
      await onCreate(email);
      setMsg({ ok: true, text: '학생 로그인 계정을 만들었어요.' });
      setTimeout(() => window.location.reload(), 1500);
    } catch (e) {
      setMsg({ ok: false, text: e instanceof Error ? e.message : '만들지 못했어요.' });
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="flex w-full flex-wrap items-center gap-2">
      <input type="email" inputMode="email" autoComplete="off" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="학생 로그인 이메일"
        aria-label="학생 로그인 이메일" className="min-h-[38px] min-w-0 flex-1 rounded-[8px] bg-white px-2 text-[15px] text-[#1d1b2b]" />
      <button type="button" disabled={busy || !email.trim()} onClick={submit}
        className="min-h-[38px] rounded-[8px] bg-[#6d4aff] px-3 text-[13px] font-semibold text-white disabled:opacity-50">
        {busy ? '만드는 중…' : '로그인 만들기'}
      </button>
      {msg && <p role={msg.ok ? 'status' : 'alert'} className={`w-full text-[13px] ${msg.ok ? 'text-[#b9f5cf]' : 'text-[#ffb4ab]'}`}>{msg.text}</p>}
    </div>
  );
}
