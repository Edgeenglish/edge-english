'use client';

// 강사 화면 실제 데이터: 강사 본인(이메일 코드 로그인) 또는 운영자(TOTP 완료)가 강사를 골라 그대로 보기·대신 입력
// 화면에서 막는 것은 편의일 뿐, 실제로는 DB 함수가 막는다 (migration 2000)

import { useEffect, useMemo, useState } from 'react';
import { supabaseBrowser } from '@/lms/auth/client';
import { saveLocation, saveLocationHours, scheduleMulti, answerCover, answerMakeup, confirmMakeup, loadSuggestOptions, suggestMakeup, createTutorLogin, loadCanceledClasses, loadNewRequests, loadTutorUpdates, answerNewRequest, loadFollowupTodos, loadHours, loadMyStudents, loadSchedule, loadStudentProfile, loadTutorAccounts, loadTutorScreen, recordClass, saveFollowup, saveHours, saveSchedule, updateStudentProfile, type TutorAccount } from '@/lms/tutor/live';
import { LANGS, type Lang } from '@/lms/tutor/lang';
import { useSavedValue } from './useSaved';
import { weekOf, type StudentCancelDecision, type TutorScreen } from '@/lms/tutor/screen';
import { loadScreenPrefs, saveScreenPref } from '@/lms/screen-prefs';
import TutorHome, { type TutorActions } from './TutorHome';
import { timeOffActions } from '@/lms/tutor/time-off';

type State =
  | { kind: 'loading' }
  | { kind: 'error'; message: string }
  | { kind: 'ready'; nowIso: string; screen: TutorScreen; admin: { tutors: TutorAccount[]; tutorId: string } | null };

export default function TutorLive({ tutorParam }: { tutorParam?: string }) {
  const [state, setState] = useState<State>({ kind: 'loading' });
  // 운영자 보기 전용 언어 (H26(73) 수정판): 강사 본인은 늘 영어, 운영진만 한국어/English 전환 — 이 기기에 기억
  const [adminLang, setAdminLang] = useSavedValue<Lang>('lms_tutor_lang_admin', 'ko', LANGS);   // H26(73): 운영자 보기 초기 한국어 권장
  const sb = supabaseBrowser();
  const adminTutor = state.kind === 'ready' && state.admin ? state.admin.tutorId : null;

  useEffect(() => {
    if (!sb) return setState({ kind: 'error', message: 'Supabase settings are missing.' });
    (async () => {
      const { data: session } = await sb.auth.getSession();
      if (!session.session) return window.location.replace('/lms/login');
      const { data: role } = await sb.rpc('my_role');
      try {
        const now = new Date();
        if (role === 'tutor') {
          const first = await loadTutorScreen(sb, null, '2000-01-01', '2000-01-01');
          const w = weekOf(now, first.tutor.timezone, 0);
          return setState({ kind: 'ready', nowIso: now.toISOString(), screen: await loadTutorScreen(sb, null, w.kstFrom, w.kstTo), admin: null });
        }
        const [{ data: aal }, { data: admin }] = await Promise.all([sb.auth.mfa.getAuthenticatorAssuranceLevel(), sb.rpc('is_admin')]);
        if (role !== 'admin' || aal?.currentLevel !== 'aal2' || admin !== true) return window.location.replace('/lms/login');
        const tutors = await loadTutorAccounts(sb);
        const pick = tutors.find((t) => t.id === tutorParam) ?? tutors.find((t) => t.active) ?? tutors[0];
        if (!pick) return setState({ kind: 'error', message: '등록된 강사가 없어요.' });
        const w = weekOf(now, pick.timezone, 0);
        setState({ kind: 'ready', nowIso: now.toISOString(), screen: await loadTutorScreen(sb, pick.id, w.kstFrom, w.kstTo), admin: { tutors, tutorId: pick.id } });
      } catch (e) {
        setState({ kind: 'error', message: e instanceof Error ? e.message : 'Could not load.' });
      }
    })();
  }, [sb, tutorParam]);

  const actions = useMemo<TutorActions | null>(
    () =>
      sb && {
        load: (from, to) => loadTutorScreen(sb, adminTutor, from, to),
        // 보기 설정: 강사가 저장한 값 읽기 · 저장은 강사 본인만 (운영자 보기는 저장 안 함, 대표 11/13 A안)
        prefs: () => loadScreenPrefs(sb, { tutor: adminTutor }),
        savePref: adminTutor ? null : (key, value) => saveScreenPref(sb, key, value),
        cancel: async (lessonId, requestId, reason, dryRun) => {
          const { data, error } = await sb.rpc('tutor_cancel_class', { p_lesson: lessonId, p_request_id: requestId, p_reason: reason, p_dry_run: dryRun });
          if (error) throw new Error(error.message);
          return data as { status: string };
        },
        studentCancel: async (lessonId, requestId, toldAt, dryRun) => {
          const { data, error } = await sb.rpc('tutor_student_cancel', { p_lesson: lessonId, p_request_id: requestId, p_told_at: toldAt.toISOString(), p_dry_run: dryRun });
          if (error) throw new Error(error.message);
          return data as StudentCancelDecision;
        },
        record: (id, r, t, rm, late) => recordClass(sb, id, r, t, rm, late),
        answer: (id, yes, note) => answerMakeup(sb, id, yes, note),
        confirm: (id, slot) => confirmMakeup(sb, id, slot),
        suggestOptions: (id) => loadSuggestOptions(sb, id),
        suggest: (id, times) => suggestMakeup(sb, id, times),
        answerCover: (items, yes) => answerCover(sb, items, yes),
        hours: {
          load: () => loadHours(sb, adminTutor),
          save: (weekly, close, open) => saveHours(sb, adminTutor, weekly, close, open),
          saveLocation: (id, city, country, timezone, from, to) => saveLocation(sb, adminTutor, id, city, country, timezone, from, to),
          saveLocationHours: (id, weekly) => saveLocationHours(sb, adminTutor, id, weekly),
        },
        schedule: {
          load: (from, to, cells) => loadSchedule(sb, adminTutor, from, to, cells),
          save: (action, cells, note, blockId) => saveSchedule(sb, adminTutor, action, cells, note, blockId),
          multi: (from, to, start, end, apply) => scheduleMulti(sb, adminTutor, from, to, start, end, apply),
        },
        profile: {
          load: (studentId) => loadStudentProfile(sb, studentId, adminTutor),
          save: (studentId, fields) => updateStudentProfile(sb, studentId, fields),
        },
        students: () => loadMyStudents(sb, adminTutor),
        followups: () => loadFollowupTodos(sb, adminTutor),
        canceled: () => loadCanceledClasses(sb, adminTutor),
        updates: () => loadTutorUpdates(sb, adminTutor),
        requests: () => loadNewRequests(sb, adminTutor),
        answerRequest: (planId, yes) => answerNewRequest(sb, planId, yes, adminTutor),
        followupSave: (studentId, fields) => saveFollowup(sb, studentId, fields, adminTutor),
        timeOff: timeOffActions(sb, adminTutor),
      },
    [sb, adminTutor],
  );

  async function logout() {
    await sb?.auth.signOut();
    window.location.replace('/lms/login');
  }

  if (state.kind === 'loading') return <p className="px-6 py-16 text-center text-[15px] text-[#6b6880]">Loading…</p>;
  if (state.kind === 'error' || !actions)
    return (
      <div className="px-6 py-16 text-center">
        <p className="text-[15px] text-[#b3261e]">{state.kind === 'error' ? state.message : ''}</p>
        <button type="button" onClick={logout} className="mt-4 min-h-[44px] rounded-[10px] border border-[#e6e3ef] px-4 text-[14px] text-[#1d1b2b]">Sign out</button>
      </div>
    );
  const adminBar = state.admin && (
    <div className="mb-4 flex flex-wrap items-center gap-2 rounded-[12px] bg-[#1d1b2b] px-3 py-2">
      <span className="text-[13px] font-semibold text-white">운영자 보기</span>
      <select aria-label="강사" value={state.admin.tutorId} onChange={(e) => window.location.assign(`/lms/tutor?tutor=${e.target.value}`)}
        className="min-h-[38px] flex-1 rounded-[8px] bg-white px-2 text-[15px] text-[#1d1b2b]">
        {state.admin.tutors.map((t) => (
          <option key={t.id} value={t.id}>{t.name}{t.hasLogin ? '' : ' · 강사 계정 없음'}{t.active ? '' : ' · 쉬는 중'}</option>
        ))}
      </select>
      <span role="group" aria-label="강사 화면 언어 (운영자 보기 전용)" className="inline-flex overflow-hidden rounded-[8px] border border-white/30">
        {LANGS.map((l) => (
          <button key={l} type="button" aria-pressed={adminLang === l} onClick={() => setAdminLang(l)}
            className={`min-h-[38px] px-2.5 text-[13px] font-semibold ${adminLang === l ? 'bg-white text-[#1d1b2b]' : 'text-white'}`}>
            {l === 'ko' ? '한국어' : 'English'}
          </button>
        ))}
      </span>
      <a href="/lms/admin" className="min-h-[38px] rounded-[8px] bg-white/15 px-3 py-2 text-[13px] font-semibold text-white">← 운영자 화면</a>
      {sb && !state.admin.tutors.find((t) => t.id === state.admin?.tutorId)?.hasLogin && (
        <TutorLoginForm onCreate={(email) => createTutorLogin(sb, state.admin!.tutorId, email)} />
      )}
    </div>
  );
  return <TutorHome key={state.screen.tutor.id} initial={state.screen} nowIso={state.nowIso} actions={actions} adminBar={adminBar} onLogout={state.admin ? undefined : logout} lang={state.admin ? adminLang : 'en'} />;
}

// 대표: 이 강사의 로그인 계정 만들기 (이메일만 넣으면 계정 + 강사 연결, 비밀번호 없음 — 강사는 이메일 코드로 로그인)
function TutorLoginForm({ onCreate }: { onCreate: (email: string) => Promise<{ created: boolean }> }) {
  const [email, setEmail] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  async function submit() {
    setBusy(true);
    setMsg(null);
    try {
      await onCreate(email);
      setMsg({ ok: true, text: '강사 로그인 계정을 만들었어요. 지금부터 시작하는 수업이 기록할 수업에 나와요.' });
      setTimeout(() => window.location.reload(), 1500);
    } catch (e) {
      setMsg({ ok: false, text: e instanceof Error ? e.message : '만들지 못했어요.' });
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="flex w-full flex-wrap items-center gap-2">
      <input type="email" inputMode="email" autoComplete="off" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="강사 로그인 이메일"
        aria-label="강사 로그인 이메일" className="min-h-[38px] min-w-0 flex-1 rounded-[8px] bg-white px-2 text-[15px] text-[#1d1b2b]" />
      <button type="button" disabled={busy || !email.trim()} onClick={submit}
        className="min-h-[38px] rounded-[8px] bg-[#6d4aff] px-3 text-[13px] font-semibold text-white disabled:opacity-50">
        {busy ? '만드는 중…' : '로그인 만들기'}
      </button>
      {msg && <p role={msg.ok ? 'status' : 'alert'} className={`w-full text-[13px] ${msg.ok ? 'text-[#b9f5cf]' : 'text-[#ffb4ab]'}`}>{msg.text}</p>}
    </div>
  );
}
