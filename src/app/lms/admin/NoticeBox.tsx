'use client';

// 대시보드 공지 (5차 시안): 목록(게시 중·예정 위, 종료 아래) · [+ 새 공지]/[수정] 창 · [게시 종료](되돌리기) · [홈에 보이는 공지]
// 날짜는 한국 날짜. 창은 바깥을 눌러도 닫히지 않음 (입력 보존). 저장 실패만 창 안에 짧게
import { useCallback, useEffect, useState } from 'react';
import { AUDIENCE_TEXT, mdw, NOTICE_BODY_MAX, NOTICE_STATE_TEXT, NOTICE_TITLE_MAX, noticeError, noticeState, sortNotices, type Audience, type Notice } from '@/lms/admin/dashboard';
import type { KstDate } from '@/lms/rules/dates';
import DateInput from './DateInput';

export type NoticeApi = {
  load: () => Promise<Notice[]>;
  save: (n: { id: string | null; audience: Audience; title: string; body: string; startsOn: string; endsOn: string }) => Promise<void>;
  end: (id: string, end: boolean) => Promise<void>;
};

type Form = { id: string | null; audience: Audience; title: string; body: string; startsOn: KstDate | ''; endsOn: KstDate | '' };
const STATE_STYLE = { live: 'text-[#13804b]', wait: 'text-[#5b3fe0]', end: 'text-[#6b6880]' } as const;
const smBtn = 'inline-flex min-h-[32px] items-center rounded-[10px] border px-2.5 text-[12.5px] font-semibold';

export default function NoticeBox({ api, today }: { api?: NoticeApi; today: KstDate }) {
  const [list, setList] = useState<Notice[]>([]);
  const [loadErr, setLoadErr] = useState<string | null>(null);
  const [form, setForm] = useState<Form | null>(null);
  const [formErr, setFormErr] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [homeFor, setHomeFor] = useState<'student' | 'tutor' | null>(null);
  const [undo, setUndo] = useState<string | null>(null);

  const reload = useCallback(async () => {
    if (!api) return;
    try {
      setList(await api.load());
      setLoadErr(null);
    } catch (e) {
      setLoadErr(e instanceof Error ? e.message : '공지를 읽지 못했어요.');
    }
  }, [api]);
  useEffect(() => { void reload(); }, [reload]);

  async function submit() {
    if (!form) return;
    const e = noticeError({ title: form.title, body: form.body, startsOn: form.startsOn, endsOn: form.endsOn });
    if (e) return setFormErr(e);
    setSaving(true);
    try {
      if (api) {
        await api.save({ ...form, startsOn: form.startsOn, endsOn: form.endsOn });
        await reload();
      } else {
        const n: Notice = { id: form.id ?? `pv-${Date.now()}`, audience: form.audience, title: form.title.trim(), body: form.body.trim(), startsOn: form.startsOn as KstDate, endsOn: form.endsOn as KstDate, endedAt: null };
        setList((l) => (form.id ? l.map((x) => (x.id === form.id ? n : x)) : [...l, n]));
      }
      setForm(null);
    } catch (err) {
      setFormErr(err instanceof Error ? err.message : '저장하지 못했어요.');
    } finally {
      setSaving(false);
    }
  }

  async function setEnded(id: string, end: boolean) {
    try {
      if (api) {
        await api.end(id, end);
        await reload();
      } else setList((l) => l.map((x) => (x.id === id ? { ...x, endedAt: end ? new Date().toISOString() : null } : x)));
      setUndo(end ? id : null);
    } catch (err) {
      setLoadErr(err instanceof Error ? err.message : '저장하지 못했어요.');
    }
  }

  const sorted = sortNotices(list, today);
  const homeList = homeFor ? sorted.filter((n) => noticeState(n, today) === 'live' && (n.audience === 'both' || n.audience === homeFor)) : [];
  const preview = (label: string) => (
    <div className="grid gap-1">
      <span className="text-[11.5px] font-bold text-[#6b6880]">{label}</span>
      <div className="rounded-[10px] bg-[#f6f5fa] px-2.5 py-2 text-[13px] text-[#1d1b2b]">
        <b className="block text-[13.5px]">{form?.title.trim() || '제목'}</b>
        <span className="whitespace-pre-line">{form?.body.trim() || '내용'}</span>
      </div>
    </div>
  );

  return (
    <section aria-label="공지" className="min-w-0 rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-3">
      <div className="mb-1 flex flex-wrap items-center gap-2">
        <h2 className="text-[15px] font-bold text-[#1d1b2b]">공지</h2>
        <div className="ml-auto flex gap-1.5">
          <button type="button" onClick={() => setHomeFor('student')} className={`${smBtn} border-[#e6e3ef] bg-white text-[#1d1b2b]`}>홈에 보이는 공지</button>
          <button type="button" onClick={() => { setForm({ id: null, audience: 'both', title: '', body: '', startsOn: today, endsOn: '' }); setFormErr(null); }} className={`${smBtn} border-[#7d5ffb] bg-[#7d5ffb] text-white`}>+ 새 공지</button>
        </div>
      </div>
      {loadErr && <p className="py-1 text-[13px] text-[#c62b2b]">{loadErr}</p>}
      {sorted.length === 0 && !loadErr && <p className="py-3 text-[13px] text-[#6b6880]">공지가 없어요.</p>}
      <ul>
        {sorted.map((n) => {
          const st = noticeState(n, today);
          return (
            <li key={n.id} className="grid gap-0.5 border-b border-[#e6e3ef] py-2 last:border-0">
              <div className="flex flex-wrap items-center gap-2">
                <span className={`text-[12px] font-bold ${STATE_STYLE[st]}`}>{NOTICE_STATE_TEXT[st]}</span>
                <b className="min-w-0 break-words text-[14px] text-[#1d1b2b]">{n.title}</b>
                {st !== 'end' ? (
                  <span className="ml-auto flex gap-1.5">
                    <button type="button" onClick={() => { setForm({ id: n.id, audience: n.audience, title: n.title, body: n.body, startsOn: n.startsOn, endsOn: n.endsOn }); setFormErr(null); }} className={`${smBtn} border-[#e6e3ef] bg-white text-[#1d1b2b]`}>수정</button>
                    <button type="button" onClick={() => setEnded(n.id, true)} className={`${smBtn} border-[#e6e3ef] bg-white text-[#1d1b2b]`}>게시 종료</button>
                  </span>
                ) : undo === n.id && n.endedAt ? (
                  <button type="button" onClick={() => setEnded(n.id, false)} className={`${smBtn} ml-auto border-[#e6e3ef] bg-white text-[#5b3fe0]`}>되돌리기</button>
                ) : null}
              </div>
              <span className="text-[12.5px] text-[#6b6880]">{AUDIENCE_TEXT[n.audience]} · {mdw(n.startsOn)} ~ {mdw(n.endsOn)}</span>
            </li>
          );
        })}
      </ul>

      {form && (
        <div className="fixed inset-0 z-30 flex items-end justify-center bg-[rgba(20,18,30,.45)] lg:items-start lg:p-10">
          <div role="dialog" aria-modal="true" aria-label={form.id ? '공지 수정' : '새 공지'} className="flex max-h-[88dvh] w-full max-w-[560px] flex-col rounded-t-[18px] bg-white lg:rounded-[16px]">
            <h3 className="border-b border-[#e6e3ef] px-4 pb-2.5 pt-3.5 text-[16px] font-bold text-[#1d1b2b]">{form.id ? '공지 수정' : '새 공지'}</h3>
            <div className="grid min-h-0 flex-1 gap-2.5 overflow-auto px-4 py-3">
              <div className="grid gap-1 text-[12.5px] font-semibold text-[#6b6880]">
                대상
                <div className="flex flex-wrap gap-1.5">
                  {(Object.keys(AUDIENCE_TEXT) as Audience[]).map((a) => (
                    <button key={a} type="button" aria-pressed={form.audience === a} onClick={() => setForm({ ...form, audience: a })}
                      className={`min-h-[36px] rounded-[10px] border px-3 text-[13px] font-semibold ${form.audience === a ? 'border-[#1d1b2b] bg-[#1d1b2b] text-white' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>
                      {AUDIENCE_TEXT[a]}
                    </button>
                  ))}
                </div>
              </div>
              <label className="grid gap-1 text-[12.5px] font-semibold text-[#6b6880]">
                제목
                <input value={form.title} maxLength={NOTICE_TITLE_MAX} onChange={(e) => setForm({ ...form, title: e.target.value })} className="rounded-[10px] border border-[#e6e3ef] px-2.5 py-2 text-[16px] font-normal text-[#1d1b2b] lg:text-[14px]" />
                <span className="text-right text-[11.5px] font-normal">{form.title.length}/{NOTICE_TITLE_MAX}</span>
              </label>
              <label className="grid gap-1 text-[12.5px] font-semibold text-[#6b6880]">
                내용
                <textarea value={form.body} maxLength={NOTICE_BODY_MAX} onChange={(e) => setForm({ ...form, body: e.target.value })} className="min-h-[96px] rounded-[10px] border border-[#e6e3ef] px-2.5 py-2 text-[16px] font-normal text-[#1d1b2b] lg:text-[14px]" />
                <span className="text-right text-[11.5px] font-normal">{form.body.length.toLocaleString()}/2,000</span>
              </label>
              <div className="grid grid-cols-2 gap-2">
                <label className="grid gap-1 text-[12.5px] font-semibold text-[#6b6880]">
                  게시일
                  <DateInput value={form.startsOn} onChange={(v) => setForm({ ...form, startsOn: v })} className="min-h-[40px] rounded-[10px] border border-[#e6e3ef] px-2 text-[15px] font-normal text-[#1d1b2b]" />
                </label>
                <label className="grid gap-1 text-[12.5px] font-semibold text-[#6b6880]">
                  종료일
                  <DateInput value={form.endsOn} onChange={(v) => setForm({ ...form, endsOn: v })} className="min-h-[40px] rounded-[10px] border border-[#e6e3ef] px-2 text-[15px] font-normal text-[#1d1b2b]" />
                </label>
              </div>
              <div className="grid gap-1.5 rounded-[12px] border border-dashed border-[#e6e3ef] p-2.5">
                {form.audience !== 'tutor' && preview('학생 홈')}
                {form.audience !== 'student' && preview('강사 홈 (Notice)')}
              </div>
            </div>
            <div className="grid gap-2 border-t border-[#e6e3ef] px-4 pb-3.5 pt-2.5">
              <p className="rounded-[10px] bg-[#f6f5fa] px-2.5 py-2 text-[13px] text-[#1d1b2b]">
                {form.startsOn && form.endsOn && form.endsOn >= form.startsOn
                  ? <><b>{AUDIENCE_TEXT[form.audience]}</b> 홈에 <b>{mdw(form.startsOn)} ~ {mdw(form.endsOn)}</b> 보여요</>
                  : '게시일과 종료일을 넣어 주세요'}
              </p>
              {formErr && <p role="alert" className="text-[12.5px] font-semibold text-[#c62b2b]">{formErr}</p>}
              <div className="flex justify-end gap-1.5">
                <button type="button" onClick={() => setForm(null)} className="min-h-[40px] rounded-[10px] border border-[#e6e3ef] px-3 text-[13.5px] font-semibold text-[#1d1b2b]">닫기</button>
                <button type="button" disabled={saving} onClick={submit} className="min-h-[40px] rounded-[10px] bg-[#7d5ffb] px-4 text-[13.5px] font-semibold text-white disabled:bg-[#cfc4ff]">{form.id ? '저장' : '게시'}</button>
              </div>
            </div>
          </div>
        </div>
      )}

      {homeFor && (
        <div className="fixed inset-0 z-30 flex items-end justify-center bg-[rgba(20,18,30,.45)] lg:items-start lg:p-10">
          <div role="dialog" aria-modal="true" aria-label="홈에 보이는 공지" className="flex max-h-[88dvh] w-full max-w-[560px] flex-col rounded-t-[18px] bg-white lg:rounded-[16px]">
            <h3 className="border-b border-[#e6e3ef] px-4 pb-2.5 pt-3.5 text-[16px] font-bold text-[#1d1b2b]">홈에 보이는 공지</h3>
            <div className="grid min-h-0 flex-1 gap-2 overflow-auto px-4 py-3">
              <div className="flex gap-1.5">
                {(['student', 'tutor'] as const).map((w) => (
                  <button key={w} type="button" aria-pressed={homeFor === w} onClick={() => setHomeFor(w)}
                    className={`min-h-[36px] rounded-[10px] border px-3 text-[13px] font-semibold ${homeFor === w ? 'border-[#1d1b2b] bg-[#1d1b2b] text-white' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>
                    {w === 'student' ? '학생 홈' : '강사 홈'}
                  </button>
                ))}
              </div>
              {homeList.length === 0 && <p className="py-4 text-center text-[13px] text-[#6b6880]">지금 보이는 공지가 없어요.</p>}
              {homeList.map((n) => (
                <div key={n.id} className="rounded-[10px] bg-[#f6f5fa] px-2.5 py-2 text-[13px] text-[#1d1b2b]">
                  <b className="block text-[13.5px]">{n.title}</b>
                  <span className="whitespace-pre-line">{n.body}</span>
                </div>
              ))}
            </div>
            <div className="flex justify-end border-t border-[#e6e3ef] px-4 pb-3.5 pt-2.5">
              <button type="button" onClick={() => setHomeFor(null)} className="min-h-[40px] rounded-[10px] border border-[#e6e3ef] px-3 text-[13.5px] font-semibold text-[#1d1b2b]">닫기</button>
            </div>
          </div>
        </div>
      )}
    </section>
  );
}
