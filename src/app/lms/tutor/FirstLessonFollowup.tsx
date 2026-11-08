'use client';

// 첫 수업 후 강사 To-do · First Lesson Follow-up (2026-11-06 대표 시안 PC·휴대폰 v2 그대로, 정책 원본 H26(67)·(68)·(71), migration 4600)
// - 왼쪽(PC)/아래(휴대폰, 펼쳐 보기): 학생 기본 정보 + ABOUT & PREFERENCES(운영진 사전 입력, 읽기만)
// - 오른쪽/위: 1 English Level · 2 Wants to Improve · 3 Class Style(교재는 조건부) · 4 Class Record(첫 수업 기록과 자동 연결)
// - 완료는 체크박스가 아니라 저장된 값으로 (DB lms_first_lesson_todo). 항목마다 저장 → 바로 상태 갱신, 아래 [Save all] 은 채운 항목을 한 번에
// - 학생의 원래 답(class_style 등)은 절대 덮어쓰지 않음 — 강사가 확인한 실제 방식은 따로 저장 (tutor_class_style)
// - 강사는 영어 고정. 운영자 보기에서만 한국어 라벨 (useT)
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { enZone } from '@/lms/admin/students';
import { bold, enBoth } from '@/lms/admin/time-text';
import { Rich } from '@/app/lms/Rich';
import { formatInZone } from '@/lms/rules/dates';
import { CLASS_STYLE_EN, CORRECTION_EN, enDate, nextLesson, RUBRIC, slotsIn, todayKst, type TutorStudentProfile } from '@/lms/tutor/profile';
import { CLASS_STYLE_TEXT, CLASS_STYLES, initialStyleFromWish, MIX_OPTIONS, MIX_TEXT, needsMaterials, needsTextbook, OTHER_TEXTBOOK, TEXTBOOKS, type Followup, type MixOption, type TutorClassStyle } from '@/lms/tutor/followup';
import { useLang, useT } from '@/lms/tutor/lang';
import type { ProfileActions } from './StudentProfile';

export type FollowupSave = (studentId: string, fields: Record<string, string | string[] | null>) => Promise<Followup | null>;

const field = 'w-full min-w-0 rounded-[10px] border border-[#dcd8ea] bg-white px-3 py-2.5 text-[16px] text-[#1d1b2b] focus:border-[#5b3fe0] focus:outline-none';
const label = 'mb-1.5 block text-[13px] font-bold text-[#1d1b2b]';
const hint = 'mt-1.5 text-[12.5px] leading-relaxed text-[#6b6880]';
const btnMain = 'min-h-[44px] rounded-[10px] bg-[#5b3fe0] px-4 text-[14.5px] font-bold text-white disabled:opacity-40';
const btnLine = 'min-h-[44px] rounded-[10px] border border-[#d9d2fa] bg-white px-4 text-[14.5px] font-bold text-[#5b3fe0] disabled:opacity-40';
const NA = <i className="text-[#b9b6c8]">No answer yet</i>;

function Step({ n, done, title, sub, status, children, id }: { n: number; done: boolean; title: string; sub: string; status: string; children: ReactNode; id: string }) {
  return (
    <section id={id} aria-label={`${n}. ${title}`} className={`scroll-mt-4 overflow-hidden rounded-[15px] border bg-white ${done ? 'border-[#cfead9]' : 'border-[#e6e3ef]'}`}>
      <div className={`flex items-center gap-3 px-4 py-3.5 ${done ? 'bg-[#f5fcf7]' : 'bg-[#fbfaff]'}`}>
        <span aria-hidden className={`grid h-[33px] w-[33px] shrink-0 place-items-center rounded-full text-[14px] font-extrabold text-white ${done ? 'bg-[#16864c]' : 'bg-[#5b3fe0]'}`}>{done ? '✓' : n}</span>
        <span className="min-w-0 flex-1">
          <b className="block text-[15px] text-[#1d1b2b]">{title}</b>
          <small className="block text-[12px] text-[#6b6880]">{sub}</small>
        </span>
        <span className={`whitespace-nowrap text-[12px] font-extrabold ${done ? 'text-[#16864c]' : 'text-[#a66a09]'}`}>{status}</span>
      </div>
      <div className="px-4 pb-4 pt-3">{children}</div>
    </section>
  );
}

export default function FirstLessonFollowup({ studentId, actions, save, now, onClose, onChanged, backLabel }: {
  studentId: string; actions: ProfileActions; save: FollowupSave; now: Date; onClose: () => void; onChanged?: () => void; backLabel?: string;
}) {
  const t = useT();
  const lang = useLang();
  const [p, setP] = useState<TutorStudentProfile | null>(null);
  const [fu, setFu] = useState<Followup | null>(null);
  const [err, setErr] = useState('');
  // 입력 칸
  const [level, setLevel] = useState('');
  const [improve, setImprove] = useState('');
  const [style, setStyle] = useState<TutorClassStyle | ''>('');
  const [mix, setMix] = useState<MixOption[]>([]);
  const [book, setBook] = useState('');
  const [bookOther, setBookOther] = useState('');
  const [materials, setMaterials] = useState('');
  const [busy, setBusy] = useState<'' | 'level' | 'improve' | 'style' | 'all'>('');
  const [stepErr, setStepErr] = useState<Record<string, string>>({});
  const [toast, setToast] = useState('');
  const init = useRef(false);

  async function load(reset: boolean) {
    const x = await actions.load(studentId);
    setP(x);
    setFu(x.followup);
    if (reset || !init.current) {
      init.current = true;
      const s = x.student;
      setLevel(s.level ?? '');
      // 운영진이 미리 적어 둔 글은 그대로 복사하지 않고 강사가 직접 물어 적게 — 강사가 적은 글(확인 시각 있음)만 미리 채움
      setImprove(s.improveTutorAt ? (s.improve ?? '') : '');
      const st = (s.tutorClassStyle as TutorClassStyle | null) ?? initialStyleFromWish(s.classStyle);
      setStyle(st);
      setMix((s.tutorClassStyleMix as MixOption[]).filter((m) => (MIX_OPTIONS as readonly string[]).includes(m)));
      if (s.textbook && TEXTBOOKS.includes(s.textbook)) { setBook(s.textbook); setBookOther(''); }
      else if (s.textbook) { setBook(OTHER_TEXTBOOK); setBookOther(s.textbook); }
      else { setBook(''); setBookOther(''); }
      setMaterials(s.tutorMaterialsNote ?? '');
    }
  }
  useEffect(() => {
    let alive = true;
    setP(null);
    setErr('');
    init.current = false;
    actions.load(studentId).then((x) => {
      if (!alive) return;
      setP(x); setFu(x.followup); init.current = true;
      const s = x.student;
      setLevel(s.level ?? '');
      setImprove(s.improveTutorAt ? (s.improve ?? '') : '');
      setStyle((s.tutorClassStyle as TutorClassStyle | null) ?? initialStyleFromWish(s.classStyle));
      setMix((s.tutorClassStyleMix as MixOption[]).filter((m) => (MIX_OPTIONS as readonly string[]).includes(m)));
      if (s.textbook && TEXTBOOKS.includes(s.textbook)) { setBook(s.textbook); setBookOther(''); }
      else if (s.textbook) { setBook(OTHER_TEXTBOOK); setBookOther(s.textbook); }
      else { setBook(''); setBookOther(''); }
      setMaterials(s.tutorMaterialsNote ?? '');
    }).catch((e) => { if (alive) setErr(e instanceof Error ? e.message : 'Could not load.'); });
    return () => { alive = false; };
  }, [studentId, actions]);
  // 뒤로가기로도 닫히게 (휴대폰) — Student profile 창과 같은 방식
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;
  useEffect(() => {
    const onPop = () => onCloseRef.current();
    if (window.history.state?.followup !== studentId) window.history.pushState({ followup: studentId }, '');
    window.addEventListener('popstate', onPop);
    return () => window.removeEventListener('popstate', onPop);
  }, [studentId]);
  const close = () => { if (window.history.state?.followup === studentId) window.history.back(); else onClose(); };

  const bookValue = book === OTHER_TEXTBOOK ? bookOther.trim() : book;
  const withBook = needsTextbook(style, mix);
  const withMaterials = needsMaterials(style, mix);
  const styleValid = !!style && (style !== 'mixed' || mix.length > 0) && (!withBook || !!bookValue);
  const styleFields = (): Record<string, string | string[] | null> => ({
    class_style: style, class_style_mix: style === 'mixed' ? mix : [], ...(withBook ? { textbook: bookValue } : {}), ...(withMaterials ? { materials_note: materials.trim() || null } : {}),
  });

  async function doSave(which: 'level' | 'improve' | 'style' | 'all', fields: Record<string, string | string[] | null>) {
    if (busy) return;
    setBusy(which);
    setStepErr((e) => ({ ...e, [which]: '' }));
    setToast('');
    try {
      const r = await save(studentId, fields);
      if (r) setFu(r);
      await load(false);
      onChanged?.();
      setToast(t('Saved ✓', '저장했어요 ✓'));
      setTimeout(() => setToast(''), 2500);
    } catch (e) {
      setStepErr((x) => ({ ...x, [which]: e instanceof Error ? e.message : t('Could not save.', '저장하지 못했어요.') }));
    } finally {
      setBusy('');
    }
  }
  async function saveAll() {
    const f: Record<string, string | string[] | null> = {};
    if (level) f.level = level;
    if (improve.trim()) f.improve = improve.trim();
    if (styleValid) Object.assign(f, styleFields());
    if (Object.keys(f).length === 0) { setStepErr((x) => ({ ...x, all: t('Fill in at least one item first.', '먼저 한 항목 이상 입력해 주세요.') })); return; }
    await doSave('all', f);
  }

  const body = (() => {
    if (err) return <p className="rounded-[10px] bg-[#fdecea] px-3 py-2 text-[14px] text-[#b3261e]">{err}</p>;
    if (!p) return <p className="py-8 text-center text-[15px] text-[#6b6880]">{t('Loading…', '불러오는 중…')}</p>;
    const s = p.student;
    const e = p.enrollment;
    const tz = p.me.timezone;
    const today = todayKst(now);
    const next = nextLesson(p, now);
    const kst = slotsIn(p.slots, 'Asia/Seoul', today);
    const mine = slotsIn(p.slots, tz, today);
    const done = fu?.done ?? { level: false, improve: false, style: false, record: false };
    const count = [done.level, done.improve, done.style, done.record].filter(Boolean).length;
    const first = fu?.firstLesson ?? null;
    const statusOf = (d: boolean, confirm = false) => (d ? t('Done', '완료') : confirm ? t('Needs confirmation', '확인 필요') : t('Needs input', '입력 필요'));
    const styleUnchanged = done.style && style === s.tutorClassStyle && JSON.stringify([...mix].sort()) === JSON.stringify([...s.tutorClassStyleMix].sort()) && (!withBook || bookValue === s.textbook) && (!withMaterials || (materials.trim() || null) === s.tutorMaterialsNote);

    const infoCards = (
      <>
        <section className="rounded-[16px] border border-[#e6e3ef] bg-white p-4">
          <div className="mb-2 flex items-center justify-between gap-2">
            <h3 className="text-[15px] font-bold text-[#1d1b2b]">{t('Student', '학생 기본 정보')}</h3>
            <span className="text-[12px] text-[#6b6880]">{t('From registration', '등록 정보 · 자동 표시')}</span>
          </div>
          <p className="text-[18px] font-extrabold text-[#1d1b2b]">{s.label}</p>
          <p className="mb-2 text-[13px] text-[#6b6880]">{e ? `${e.durationMin} min` : ''}{p.slots.length ? ` · ${kst.text.split(' ')[0]}` : ''}</p>
          {[
            [t('Lives in', '거주·시간대'), <>{[s.city, s.country].filter(Boolean).join(', ') || '—'} <span className="text-[#6b6880]">· {s.timezone}</span></>],
            [t('Regular class', '정규 수업'), p.slots.length ? <>{kst.text} <Rich text={bold('KST')} />{tz !== 'Asia/Seoul' ? <span className="block text-[12.5px] text-[#6b6880]">{mine.text} <Rich text={bold(enZone(tz))} /></span> : null}</> : '—'],
            [t('Next class', '다음 수업'), next ? <Rich text={enBoth(next.startsAt, tz)} /> : '—'],
            [t('Remaining', '수업 횟수'), e && 'leftAll' in e ? `${e.leftAll + e.leftUnbooked} ${t('classes left', '회 남음')}` : '—'],
          ].map(([k, v], i) => (
            <div key={i} className="grid grid-cols-[105px_1fr] gap-2 border-b border-[#efedf4] py-2 text-[13px] last:border-0">
              <span className="text-[#6b6880]">{k}</span><b className="min-w-0 break-words font-semibold text-[#1d1b2b]">{v}</b>
            </div>
          ))}
        </section>
        <section className="rounded-[16px] border border-[#e6e3ef] bg-white p-4">
          <div className="mb-2 flex items-center justify-between gap-2">
            <h3 className="text-[13px] font-extrabold tracking-wider text-[#1d1b2b]">ABOUT &amp; PREFERENCES</h3>
            <span className="text-[12px] text-[#6b6880]">{t('Entered by Edge English', '운영진 사전 입력')}</span>
          </div>
          <div className="rounded-[13px] border border-[#eeebfe] bg-[#f8f7ff] p-3.5 text-[13px] leading-relaxed text-[#1d1b2b]">
            <div className="font-bold text-[#5b3fe0]">{t("Student's preferred class style", '학생이 희망한 Class Style')}</div>
            <b>{s.classStyle ? CLASS_STYLE_EN[s.classStyle] : NA}</b>{s.classStyleNote && <span className="block text-[12.5px] text-[#6b6880]">{s.classStyleNote}</span>}
            <hr className="my-3 border-[#e6e5ee]" />
            <div className="font-bold text-[#5b3fe0]">{t('Corrections', '교정 방식')}</div>
            {s.correctionStyle ? CORRECTION_EN[s.correctionStyle] : NA}{s.correctionNote && <span className="block text-[12.5px] text-[#6b6880]">{s.correctionNote}</span>}
            <hr className="my-3 border-[#e6e5ee]" />
            <div className="font-bold text-[#5b3fe0]">{t('Job / Hobbies / Interests', '직업 / 취미 / 관심사')}</div>
            <span className="block">{t('Job', '직업')}: {s.job ?? NA}</span>
            <span className="block">{t('Hobbies', '취미')}: {s.hobbies ?? NA}</span>
            <span className="block">{t('Interests', '관심사')}: {s.interests ?? NA}</span>
            <hr className="my-3 border-[#e6e5ee]" />
            <div className="font-bold text-[#5b3fe0]">{t('Hopes for class', '바라는 점')}</div>
            {s.hopes ?? NA}
          </div>
          <p className="mt-2 text-[12px] leading-relaxed text-[#6b6880]">{t("The student's original answers are kept as they are. Only the actual class style you confirm on the right is saved separately.", '학생의 원래 답변은 보존됩니다. 강사가 확인한 실제 수업 방식만 별도로 저장됩니다.')}</p>
        </section>
      </>
    );

    return (
      <>
        <header className="mb-4 flex flex-wrap items-center justify-between gap-2">
          <div className="min-w-0">
            <h2 className="pr-10 text-[20px] font-bold text-[#1d1b2b]">{t('First lesson follow-up', '첫 수업 후 확인')}</h2>
            <p className="text-[13px] text-[#6b6880]">{t('Students', '학생')} / {s.label}</p>
          </div>
          {first && <span className="rounded-full bg-[#e9fbef] px-2.5 py-1 text-[12px] font-bold text-[#167344]">✓ {t('First lesson done', '첫 수업 완료')} · {enDate(formatInZone(first.startsAt, tz).date)}</span>}
        </header>
        <div className="grid gap-4 lg:grid-cols-[minmax(260px,320px)_minmax(0,1fr)]">
          {/* 휴대폰: 번호별 입력이 먼저, 학생 정보는 아래에서 펼쳐 보기. PC: 왼쪽 */}
          <div className="order-2 hidden gap-4 lg:order-1 lg:grid">{infoCards}</div>
          <details className="order-2 rounded-[16px] border border-[#e6e3ef] bg-white lg:hidden">
            <summary className="flex min-h-[48px] cursor-pointer list-none items-center px-4 text-[14.5px] font-bold text-[#5b3fe0]">
              {t("Student info & preferences (tap to open)", '학생 정보 · 사전 답변 (눌러서 펼치기)')}<span className="flex-1" /><span aria-hidden className="text-[#6b6880]">⌄</span>
            </summary>
            <div className="grid gap-3 px-3 pb-3">{infoCards}</div>
          </details>

          <main className="order-1 min-w-0 lg:order-2">
            <section className="rounded-[18px] border border-[#e6e3ef] bg-white p-4 lg:p-5">
              <div className="mb-3 flex items-center justify-between gap-2">
                <h3 className="text-[17px] font-bold text-[#1d1b2b]">First Lesson Follow-up</h3>
                <b className="text-[13px] text-[#5b3fe0]">{count} / 4 {t('done', '완료')}</b>
              </div>
              <div className="mb-3 rounded-[12px] bg-[#f0ebff] px-3.5 py-3 text-[13px] leading-relaxed text-[#42319a]">
                {t('After the first lesson, fill in ', '첫 수업 후 아래 ')}<b>{t('1–3 in order', '1~3번을 순서대로 입력')}</b>{t(' below. ', '해 주세요. ')}<b>{t('4 is linked to Class Record automatically.', '4번은 Class Record와 자동 연결됩니다.')}</b>{t(' Each item has its own input right below it.', ' 번호별 입력칸이 바로 아래에 있어요.')}
              </div>
              <div className="h-[7px] overflow-hidden rounded-[8px] bg-[#eeeaf8]"><i className="block h-full bg-[#5b3fe0] transition-all" style={{ width: `${(count / 4) * 100}%` }} /></div>
              <p className="mb-3 mt-1.5 text-[12px] text-[#6b6880]">{count === 4 ? t('All first-lesson items are done.', '모든 첫 수업 후 확인 항목이 완료됐습니다.') : t('Items turn green automatically once they are saved — nothing to tick.', '저장한 항목은 자동으로 완료 표시됩니다. 체크박스를 직접 누를 필요가 없습니다.')}</p>
              {toast && <p role="status" className="mb-2 text-[13px] font-bold text-[#16864c]">{toast}</p>}

              <div className="grid gap-3">
                <Step id="fl-level" n={1} done={done.level} title="English Level" sub={t('Your assessment after the first lesson', '첫 수업에서 평가한 영어 레벨')} status={statusOf(done.level)}>
                  <label className={label} htmlFor="fl-level-sel">{t('Level', '레벨 선택')}</label>
                  <select id="fl-level-sel" className={field} value={level} onChange={(e) => setLevel(e.target.value)}>
                    <option value="">{t('Choose after assessing', '평가 후 선택하세요')}</option>
                    {RUBRIC.map((l) => <option key={l} value={l}>{l}</option>)}
                  </select>
                  <p className={hint}>{t('Uses the LMS English Speaking Level Rubric.', 'LMS의 기존 레벨 기준(English Speaking Level Rubric)을 사용합니다.')}{s.level && s.levelBy ? ` ${t('Current', '현재')}: ${s.level} (${s.levelBy}${s.levelAt ? ` · ${enDate(formatInZone(s.levelAt, tz).date)}` : ''})` : s.level ? ` ${t('Earlier level (not assessed in LMS yet)', '예전 레벨 (LMS 평가 전)')}: ${s.level}` : ''}</p>
                  {stepErr.level && <p className="mt-1.5 text-[13px] text-[#b3261e]">{stepErr.level}</p>}
                  <div className="mt-3 flex justify-end">
                    <button type="button" className={btnMain} disabled={!level || !!busy} onClick={() => doSave('level', { level })}>{busy === 'level' ? t('Saving…', '저장 중…') : done.level && level === s.level ? t('Saved ✓ · Save again', '저장됨 ✓ · 다시 저장') : t('Save level', '레벨 저장')}</button>
                  </div>
                </Step>

                <Step id="fl-improve" n={2} done={done.improve} title="Wants to Improve" sub={t('What the student told you they want to improve', '첫 수업에서 학생에게 직접 물어본 학습 목표')} status={statusOf(done.improve)}>
                  <label className={label} htmlFor="fl-improve-txt">{t("Student's goal", '학생의 학습 목표')}</label>
                  <textarea id="fl-improve-txt" className={`${field} min-h-[85px]`} value={improve} onChange={(e) => setImprove(e.target.value)} placeholder={t('e.g. Wants to feel more confident speaking at work.', '예: Wants to feel more confident speaking at work.')} />
                  {s.improve && !s.improveTutorAt && (
                    <p className={hint}>{t('Edge English noted before the first lesson', '운영진 사전 메모')}: “{s.improve}” — {t('please ask the student yourself and write what they said, rather than copying this.', '그대로 복사하지 말고, 학생에게 직접 확인해 기록합니다.')}</p>
                  )}
                  {!(s.improve && !s.improveTutorAt) && <p className={hint}>{t('Ask the student directly and write it in your own words.', '운영진의 사전 답변을 그대로 복사하지 말고, 직접 확인해 기록합니다.')}</p>}
                  {stepErr.improve && <p className="mt-1.5 text-[13px] text-[#b3261e]">{stepErr.improve}</p>}
                  <div className="mt-3 flex justify-end">
                    <button type="button" className={btnMain} disabled={!improve.trim() || !!busy} onClick={() => doSave('improve', { improve: improve.trim() })}>{busy === 'improve' ? t('Saving…', '저장 중…') : done.improve && improve.trim() === (s.improve ?? '') ? t('Saved ✓ · Save again', '저장됨 ✓ · 다시 저장') : t('Save', '저장')}</button>
                  </div>
                </Step>

                <Step id="fl-style" n={3} done={done.style} title="Class Style" sub={t("Decide the actual class style from the student's wish and level", '학생의 희망과 레벨을 보고 실제 수업 방식 결정')} status={statusOf(done.style, true)}>
                  <div className="mb-3 rounded-[11px] border border-[#e9e5fd] bg-[#faf9ff] px-3.5 py-3 text-[12.5px] leading-relaxed text-[#1d1b2b]">
                    <b className="text-[#5b3fe0]">{t("Student's wish", '학생 사전 희망')}</b> · {s.classStyle ? CLASS_STYLE_EN[s.classStyle] : t('No answer yet', '미응답')}{s.classStyleNote ? ` (${s.classStyleNote})` : ''}
                    <br />{t('The original answer is kept. Below is the class style you confirm.', '원답은 보존됩니다. 아래는 강사가 최종 확인하는 수업 방식입니다.')}
                  </div>
                  <label className={label} htmlFor="fl-style-sel">{t('Actual class style', '실제 Class Style')}</label>
                  <select id="fl-style-sel" className={field} value={style} onChange={(e) => setStyle(e.target.value as TutorClassStyle | '')}>
                    <option value="">{t('Choose', '선택')}</option>
                    {CLASS_STYLES.map((c) => <option key={c} value={c}>{CLASS_STYLE_TEXT[c][lang]}</option>)}
                  </select>
                  {style === 'mixed' && (
                    <div className="mt-3">
                      <span className={label}>{t('Mixed — what it includes (pick all that apply)', 'Mixed 구성 (복수 선택)')}</span>
                      <div className="flex flex-wrap gap-2" role="group" aria-label="Mixed">
                        {MIX_OPTIONS.map((m) => {
                          const on = mix.includes(m);
                          return (
                            <button key={m} type="button" aria-pressed={on} onClick={() => setMix(on ? mix.filter((x) => x !== m) : [...mix, m])}
                              className={`min-h-[40px] rounded-[9px] border px-3 text-[13.5px] ${on ? 'border-[#8e7aff] bg-[#f2efff] font-bold text-[#5b3fe0]' : 'border-[#dedaf0] bg-white text-[#53556c]'}`}>
                              {MIX_TEXT[m][lang]}{on ? ' ✓' : ''}
                            </button>
                          );
                        })}
                      </div>
                    </div>
                  )}
                  {withBook && (
                    <div className="mt-3">
                      <label className={label} htmlFor="fl-book-sel">{t('Textbook', '교재')} <span className="font-normal text-[#6b6880]">{t('(from the Edge English textbook list)', '(엣지영어 교재 목록)')}</span></label>
                      <select id="fl-book-sel" className={field} value={book} onChange={(e) => setBook(e.target.value)}>
                        <option value="">{t('Choose a textbook', '교재 선택')}</option>
                        {TEXTBOOKS.map((b) => <option key={b} value={b}>{b}</option>)}
                        <option value={OTHER_TEXTBOOK}>{t('Other textbook (type the title)', '다른 교재 (이름 입력)')}</option>
                      </select>
                      {book === OTHER_TEXTBOOK && <input className={`${field} mt-2`} value={bookOther} onChange={(e) => setBookOther(e.target.value)} placeholder={t('Textbook title', '교재 이름')} aria-label={t('Other textbook title', '다른 교재 이름')} />}
                      <p className={hint}>{t('You can change the textbook later at any time.', '교재는 나중에도 바꿀 수 있어요.')}</p>
                    </div>
                  )}
                  {withMaterials && (
                    <div className="mt-3">
                      <label className={label} htmlFor="fl-mat">{t('Student-provided materials (optional)', '학생 제공 자료 (선택)')}</label>
                      <input id="fl-mat" className={field} value={materials} onChange={(e) => setMaterials(e.target.value)} placeholder={t('e.g. Articles, presentation slides', '예: Articles, presentation slides')} />
                    </div>
                  )}
                  {stepErr.style && <p className="mt-1.5 text-[13px] text-[#b3261e]">{stepErr.style}</p>}
                  <div className="mt-3 flex justify-end">
                    <button type="button" className={btnMain} disabled={!styleValid || !!busy} onClick={() => doSave('style', styleFields())}>
                      {busy === 'style' ? t('Saving…', '저장 중…') : styleUnchanged ? t('Confirmed ✓ · Confirm again', '확인 완료 ✓ · 다시 확인') : t('Confirm this class style', '이 수업 방식 확인')}
                    </button>
                  </div>
                  <p className={hint}>{withBook && !bookValue ? t('Choose the textbook before confirming.', '교재를 사용하는 경우 교재를 선택한 뒤 확인하세요.') : style === 'mixed' && mix.length === 0 ? t('Pick what the mixed class includes.', 'Mixed에 사용할 구성을 선택해 주세요.') : t('If the current style is right, just press confirm. Change it first if needed.', '기존 값이 맞으면 버튼만 누르세요. 변경이 필요하면 선택한 뒤 확인하세요.')}</p>
                </Step>

                <Step id="fl-record" n={4} done={done.record} title="Class Record" sub={t('Checked automatically from your saved record', '수업 후 기록 · 기존 저장 내용 자동 확인')} status={statusOf(done.record)}>
                  {first ? (
                    <div className="rounded-[13px] border border-[#dcebdc] bg-[#f7fcf8] p-3 text-[13px] leading-relaxed text-[#1d1b2b]">
                      ✓ <b>{t('First lesson recorded', '첫 수업 기록 완료')}</b><br />
                      <Rich text={enBoth(first.startsAt, tz)} /> · {first.status ?? 'Held'}<br />
                      {first.topics ? <>{t('Topic', 'Topic')}: {first.topics}</> : <span className="text-[#6b6880]">{t('No covered topics written', 'Covered topics 없음')}</span>}
                    </div>
                  ) : <p className="text-[13px] text-[#6b6880]">{t('The first lesson has not been recorded as held yet.', '첫 수업이 아직 Held 로 기록되지 않았어요.')}</p>}
                  <p className={hint}>{t('Linked to Class Record — nothing to re-enter here.', '실제 LMS의 Class Record 저장 여부와 자동 연결됩니다. 이곳에서 중복 기록하지 않습니다.')}</p>
                </Step>
              </div>

              <div className="sticky bottom-0 mt-4 flex items-center justify-between gap-3 rounded-[12px] bg-[#f0ebff]/95 p-3.5 backdrop-blur lg:static">
                <div>
                  <b className="block text-[13px] text-[#1d1b2b]">{count === 4 ? t('All items done', '모든 항목 완료') : `${4 - count} ${t('left to confirm', '개 확인 필요')}`}</b>
                  <span className="block text-[12px] text-[#6b6880]">{t('Only filled-in items are saved.', '입력·확인한 내용만 저장됩니다.')}</span>
                  {stepErr.all && <span className="block text-[12.5px] text-[#b3261e]">{stepErr.all}</span>}
                </div>
                <button type="button" className={`${btnLine} shrink-0`} disabled={!!busy} onClick={saveAll}>{busy === 'all' ? t('Saving…', '저장 중…') : t('Save all', '저장하기')}</button>
              </div>
            </section>
          </main>
        </div>
      </>
    );
  })();

  return (
    <div className="fixed inset-0 z-40 flex items-end justify-center bg-black/40 lg:items-center" onClick={close}>
      <div role="dialog" aria-modal="true" aria-label="First lesson follow-up" onClick={(e) => e.stopPropagation()}
        className="relative max-h-[94vh] w-full max-w-[1100px] overflow-y-auto rounded-t-[20px] bg-[#f6f5fa] p-4 pb-8 lg:rounded-[20px]">
        <button type="button" onClick={close} className="mb-2 min-h-[36px] text-[13.5px] font-semibold text-[#5b3fe0]">‹ {backLabel ?? t('Back', '뒤로')}</button>
        <button type="button" aria-label="Close" onClick={close} className="absolute right-3 top-3 flex h-[40px] w-[40px] items-center justify-center rounded-full bg-white text-[18px] text-[#1d1b2b]">✕</button>
        {body}
      </div>
    </div>
  );
}
