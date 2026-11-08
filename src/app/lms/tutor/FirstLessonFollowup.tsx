'use client';

// 첫 수업 후 강사 To-do · First Lesson Follow-up (2026-11-08 대표 승인 시안 v3, migration 4600·4602)
// - 한 화면 4칸: English Level · Wants to Improve · Class Style · Class Notes(Google Docs) + [Save] 하나
// - [Save] 는 채운 칸만 저장. 4칸이 모두 저장돼야 To-do 에서 빠짐 (완료 판정은 DB lms_first_lesson_todo)
// - Class Record 는 To-do 가 첫 수업 기록 뒤에만 생기므로 칸에서 뺌
// - 수강생의 원래 답(class_style 등)은 덮어쓰지 않음 — 강사가 확인한 실제 방식은 따로 저장 (tutor_class_style)
// - [Level guide]: PC 는 옆 팝오버, 휴대폰은 바텀시트. 글은 대표 원본 Rubric 그대로 (LEVEL_RUBRIC)
// - 강사는 영어 고정. 운영자 보기에서만 한국어 라벨 (useT)
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { enZone } from '@/lms/admin/students';
import { bold } from '@/lms/admin/time-text';
import { Rich } from '@/app/lms/Rich';
import { CLASS_STYLE_EN, RUBRIC, slotsIn, todayKst, type TutorStudentProfile } from '@/lms/tutor/profile';
import {
  CLASS_STYLE_TEXT, CLASS_STYLES, initialStyleFromWish, isGoogleDocUrl, LEVEL_RUBRIC, MIX_OPTIONS, MIX_TEXT, needsMaterials, needsTextbook, OTHER_TEXTBOOK, TEXTBOOKS,
  type Followup, type MixOption, type TutorClassStyle,
} from '@/lms/tutor/followup';
import { useLang, useT } from '@/lms/tutor/lang';
import type { ProfileActions } from './StudentProfile';

export type FollowupSave = (studentId: string, fields: Record<string, string | string[] | null>) => Promise<Followup | null>;

const field = 'w-full min-w-0 rounded-[10px] border border-[#dcd8ea] bg-white px-3 py-2.5 text-[16px] text-[#1d1b2b] focus:border-[#5b3fe0] focus:outline-none';
const btnMain = 'min-h-[46px] rounded-[10px] bg-[#5b3fe0] px-6 text-[15px] font-bold text-white disabled:opacity-40';
const btnLine = 'min-h-[46px] rounded-[10px] border border-[#d9d2fa] bg-white px-5 text-[15px] font-bold text-[#5b3fe0] disabled:opacity-40';
const errText = 'mt-1.5 text-[13.5px] text-[#b3261e]';

function Row({ label, htmlFor, children }: { label: string; htmlFor?: string; children: ReactNode }) {
  return (
    <div className="grid gap-2 border-t border-[#efedf4] py-4 first:border-0 lg:grid-cols-[215px_minmax(0,1fr)] lg:gap-4">
      <label htmlFor={htmlFor} className="text-[15px] font-bold text-[#1d1b2b] lg:pt-2.5">{label} <span aria-hidden className="text-[#b3261e]">*</span></label>
      <div className="relative grid min-w-0 gap-2">{children}</div>
    </div>
  );
}

/** 레벨 기준: PC(넓은 화면 xl) = 옆 팝오버, 휴대폰·좁은 창 = 바텀시트. 본문 15px · 레벨 이름 굵게 */
function LevelGuide({ onClose }: { onClose: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);
  return (
    <>
      <div className="fixed inset-0 z-[60] bg-black/30 xl:hidden" onClick={onClose} aria-hidden />
      <div role="dialog" aria-label="English Speaking Level Rubric"
        className="fixed inset-x-0 bottom-0 z-[61] max-h-[85vh] overflow-y-auto rounded-t-[20px] bg-white px-5 pb-[max(20px,env(safe-area-inset-bottom))] pt-4 shadow-[0_-8px_30px_rgba(0,0,0,0.18)]
          lg:mx-auto lg:max-w-[640px] xl:absolute xl:inset-x-auto xl:bottom-auto xl:left-[calc(100%+14px)] xl:top-0 xl:max-h-[520px] xl:w-[360px] xl:rounded-[16px] xl:border xl:border-[#e6e3ef] xl:pb-5 xl:shadow-[0_12px_32px_rgba(0,0,0,0.16)]">
        <div aria-hidden className="mx-auto mb-3 h-[5px] w-[44px] rounded-full bg-[#dcd8ea] xl:hidden" />
        <div className="mb-2 flex items-center justify-between gap-2">
          <h3 className="text-[17px] font-bold text-[#1d1b2b]">English Speaking Level Rubric</h3>
          <button type="button" aria-label="Close" onClick={onClose} className="grid h-[40px] w-[40px] shrink-0 place-items-center rounded-full text-[18px] text-[#1d1b2b] hover:bg-[#f2f0f8]">✕</button>
        </div>
        <div className="grid gap-3">
          {LEVEL_RUBRIC.map((r) => (
            <section key={r.level} className="border-t border-[#efedf4] pt-3 first:border-0 first:pt-0">
              <b className="block text-[16px] font-extrabold text-[#5b3fe0]">{r.level}</b>
              <ul className="mt-1 list-disc space-y-1 pl-5 text-[15px] leading-relaxed text-[#1d1b2b]">
                {r.lines.map((l) => <li key={l}>{l}</li>)}
              </ul>
            </section>
          ))}
        </div>
      </div>
    </>
  );
}

export default function FirstLessonFollowup({ studentId, actions, save, now, onClose, onChanged }: {
  studentId: string; actions: ProfileActions; save: FollowupSave; now: Date; onClose: () => void; onChanged?: () => void; backLabel?: string;
}) {
  const t = useT();
  const lang = useLang();
  const [p, setP] = useState<TutorStudentProfile | null>(null);
  const [err, setErr] = useState('');
  const [level, setLevel] = useState('');
  const [improve, setImprove] = useState('');
  const [style, setStyle] = useState<TutorClassStyle | ''>('');
  const [mix, setMix] = useState<MixOption[]>([]);
  const [book, setBook] = useState('');
  const [bookOther, setBookOther] = useState('');
  const [materials, setMaterials] = useState('');
  const [doc, setDoc] = useState('');
  const [guide, setGuide] = useState(false);
  const [busy, setBusy] = useState(false);
  const [tried, setTried] = useState(false);
  const [saveErr, setSaveErr] = useState('');
  const [savedLeft, setSavedLeft] = useState<number | null>(null);

  useEffect(() => {
    let alive = true;
    setP(null);
    setErr('');
    actions.load(studentId).then((x) => {
      if (!alive) return;
      setP(x);
      const s = x.student;
      setLevel(s.level ?? '');
      // 운영진 사전 메모는 복사하지 않음 — 강사가 적은 글(확인 시각 있음)만 미리 채움
      setImprove(s.improveTutorAt ? (s.improve ?? '') : '');
      setStyle((s.tutorClassStyle as TutorClassStyle | null) ?? initialStyleFromWish(s.classStyle));
      setMix((s.tutorClassStyleMix as MixOption[]).filter((m) => (MIX_OPTIONS as readonly string[]).includes(m)));
      if (s.textbook && TEXTBOOKS.includes(s.textbook)) { setBook(s.textbook); setBookOther(''); }
      else if (s.textbook) { setBook(OTHER_TEXTBOOK); setBookOther(s.textbook); }
      else { setBook(''); setBookOther(''); }
      setMaterials(s.tutorMaterialsNote ?? '');
      setDoc(s.classNoteUrl ?? '');
    }).catch((e) => { if (alive) setErr(e instanceof Error ? e.message : 'Could not load.'); });
    return () => { alive = false; };
  }, [studentId, actions]);

  // 뒤로가기로도 닫히게 (휴대폰)
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
  const styleErr = !style ? '' : style === 'mixed' && mix.length === 0 ? t('Pick what the mixed class includes.', 'Mixed 구성을 골라 주세요.') : withBook && !bookValue ? t('Choose the textbook.', '교재를 골라 주세요.') : '';
  const docErr = doc.trim() && !isGoogleDocUrl(doc) ? t('Paste a Google Docs link.', 'Google Docs 문서 링크를 붙여 넣어 주세요.') : '';

  function fields(): Record<string, string | string[] | null> {
    const f: Record<string, string | string[] | null> = {};
    if (level) f.level = level;
    if (improve.trim()) f.improve = improve.trim();
    if (style) Object.assign(f, { class_style: style, class_style_mix: style === 'mixed' ? mix : [], ...(withBook ? { textbook: bookValue } : {}), ...(withMaterials ? { materials_note: materials.trim() || null } : {}) });
    if (doc.trim()) f.class_note_url = doc.trim();
    return f;
  }
  const anyFilled = Object.keys(fields()).length > 0;

  async function onSave() {
    if (busy) return;
    setTried(true);
    setSaveErr('');
    if (styleErr || docErr) return;
    setBusy(true);
    try {
      const r = await save(studentId, fields());
      onChanged?.();
      const left = r?.pending ?? null;
      if (left === 0) { close(); return; }
      setSavedLeft(left);
    } catch (e) {
      setSaveErr(e instanceof Error ? e.message : t('Could not save.', '저장하지 못했어요.'));
    } finally {
      setBusy(false);
    }
  }

  const body = (() => {
    if (err) return <p className="rounded-[10px] bg-[#fdecea] px-3 py-2 text-[14px] text-[#b3261e]">{err}</p>;
    if (!p) return <p className="py-8 text-center text-[15px] text-[#6b6880]">{t('Loading…', '불러오는 중…')}</p>;
    const s = p.student;
    const tz = p.me.timezone;
    const today = todayKst(now);
    const kst = slotsIn(p.slots, 'Asia/Seoul', today);
    const mine = slotsIn(p.slots, tz, today);
    const e = p.enrollment;
    return (
      <>
        <h2 className="pr-10 text-[21px] font-bold text-[#1d1b2b]">First Lesson Follow-up</h2>
        <p className="mb-2 text-[14px] text-[#6b6880]">
          {s.label}
          {p.slots.length > 0 && <> · {kst.text} <Rich text={bold('KST')} />{tz !== 'Asia/Seoul' && <> / {mine.text} <Rich text={bold(enZone(tz))} /></>}</>}
          {e ? ` · ${e.durationMin} min` : ''}
        </p>

        <div className="max-w-[640px]">
          <Row label="English Level" htmlFor="fl-level">
            <div className="flex items-center gap-3">
              <select id="fl-level" className={field} value={level} onChange={(x) => setLevel(x.target.value)}>
                <option value="">{t('Choose', '선택')}</option>
                {RUBRIC.map((l) => <option key={l} value={l}>{l}</option>)}
              </select>
              <button type="button" aria-expanded={guide} onClick={() => setGuide((g) => !g)} className="min-h-[44px] shrink-0 whitespace-nowrap px-1 text-[15px] font-bold text-[#5b3fe0] underline underline-offset-2">Level guide</button>
            </div>
            {guide && <LevelGuide onClose={() => setGuide(false)} />}
          </Row>

          <Row label="Wants to Improve" htmlFor="fl-improve">
            <textarea id="fl-improve" className={`${field} min-h-[80px]`} value={improve} onChange={(x) => setImprove(x.target.value)} placeholder="e.g. Speaking at work, fluency" />
          </Row>

          <Row label="Class Style" htmlFor="fl-style">
            <select id="fl-style" className={field} value={style} onChange={(x) => setStyle(x.target.value as TutorClassStyle | '')}>
              <option value="">{t('Choose', '선택')}</option>
              {CLASS_STYLES.map((c) => <option key={c} value={c}>{CLASS_STYLE_TEXT[c][lang]}</option>)}
            </select>
            {style === 'mixed' && (
              <div className="flex flex-wrap gap-2" role="group" aria-label="Mixed">
                {MIX_OPTIONS.map((m) => {
                  const on = mix.includes(m);
                  return (
                    <button key={m} type="button" aria-pressed={on} onClick={() => setMix(on ? mix.filter((x) => x !== m) : [...mix, m])}
                      className={`min-h-[42px] rounded-[9px] border px-3 text-[14px] ${on ? 'border-[#8e7aff] bg-[#f2efff] font-bold text-[#5b3fe0]' : 'border-[#dedaf0] bg-white text-[#53556c]'}`}>
                      {MIX_TEXT[m][lang]}{on ? ' ✓' : ''}
                    </button>
                  );
                })}
              </div>
            )}
            {withBook && (
              <>
                <select aria-label={t('Textbook', '교재')} className={field} value={book} onChange={(x) => setBook(x.target.value)}>
                  <option value="">{t('Choose a textbook', '교재 선택')}</option>
                  {TEXTBOOKS.map((b) => <option key={b} value={b}>{b}</option>)}
                  <option value={OTHER_TEXTBOOK}>{t('Other textbook', '다른 교재')}</option>
                </select>
                {book === OTHER_TEXTBOOK && <input className={field} value={bookOther} onChange={(x) => setBookOther(x.target.value)} placeholder={t('Textbook title', '교재 이름')} aria-label={t('Other textbook title', '다른 교재 이름')} />}
              </>
            )}
            {withMaterials && <input aria-label={t('Student-provided materials', '수강생 제공 자료')} className={field} value={materials} onChange={(x) => setMaterials(x.target.value)} placeholder={t('Materials (optional), e.g. work emails', '자료 (선택), 예: work emails')} />}
            {tried && styleErr && <p className={errText}>{styleErr}</p>}
            <p className="text-[13.5px] text-[#6b6880]">{t("Student's wish", '수강생 희망')}: {s.classStyle ? CLASS_STYLE_EN[s.classStyle] : t('No answer', '미응답')}{s.classStyleNote ? ` (${s.classStyleNote})` : ''}</p>
          </Row>

          <Row label="Class Notes (Google Docs)" htmlFor="fl-doc">
            <input id="fl-doc" type="url" inputMode="url" className={field} value={doc} onChange={(x) => setDoc(x.target.value)} placeholder="https://docs.google.com/document/…" />
            {docErr && (tried || doc.trim().length > 12) && <p className={errText}>{docErr}</p>}
            <a href="https://docs.new" target="_blank" rel="noreferrer" className={`${btnLine} inline-flex items-center justify-center justify-self-start text-[14.5px]`}>Create a new Google Doc ↗</a>
          </Row>
        </div>

        <div className="sticky bottom-0 -mx-4 mt-2 flex flex-wrap items-center justify-end gap-3 border-t border-[#e6e3ef] bg-[#f6f5fa]/95 px-4 py-3 backdrop-blur lg:static lg:mx-0 lg:max-w-[640px] lg:bg-transparent lg:px-0">
          {saveErr && <p className="mr-auto text-[14px] text-[#b3261e]">{saveErr}</p>}
          {!saveErr && savedLeft !== null && <p role="status" className="mr-auto text-[14px] font-bold text-[#16864c]">Saved · {savedLeft} {savedLeft === 1 ? 'item' : 'items'} left</p>}
          <button type="button" className={btnLine} onClick={close}>{savedLeft !== null ? t('Close', '닫기') : t('Cancel', '취소')}</button>
          <button type="button" className={btnMain} disabled={!anyFilled || busy} onClick={onSave}>{busy ? t('Saving…', '저장 중…') : t('Save', '저장')}</button>
        </div>
      </>
    );
  })();

  return (
    <div className="fixed inset-0 z-40 flex items-end justify-center bg-black/40 lg:items-center" onClick={close}>
      <div role="dialog" aria-modal="true" aria-label="First Lesson Follow-up" onClick={(x) => x.stopPropagation()}
        className="relative max-h-[94vh] w-full max-w-[1120px] overflow-y-auto rounded-t-[20px] bg-[#f6f5fa] p-4 pb-0 lg:rounded-[20px] lg:p-7">
        <button type="button" aria-label="Close" onClick={close} className="absolute right-3 top-3 flex h-[40px] w-[40px] items-center justify-center rounded-full bg-white text-[18px] text-[#1d1b2b]">✕</button>
        <div className="rounded-[16px] bg-white p-4 lg:p-6">{body}</div>
        <div className="h-4" />
      </div>
    </div>
  );
}
