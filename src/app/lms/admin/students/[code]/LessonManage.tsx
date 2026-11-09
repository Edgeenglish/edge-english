'use client';

// 학생 상세 '보강·보상수업' 카드 (H26(103), 대표 승인 11/9 2차 시안, migration 20261109040000)
// [+ 수업 추가]: 보강권(취소·노쇼·휴무 수업, 시트 이관) 또는 무료 보상권 하나로 고른 강사·시간에 바로 확정. 기본값 없음(강사만 담당 강사)
// [수정]: 확정된 보강·보상수업의 날짜·시간·강사만 바꿈(같은 수업, 변경권·보강권 그대로). 시간 입력은 TimeInput(오전·오후+시+분)
// 검사(강사 휴무·다른 수업·열린 시간·종료일·중복)는 DB 함수가 하고, 걸리면 시간 칸 바로 아래 빨간 글
import { useCallback, useEffect, useMemo, useState } from 'react';
import { instantToKstDate, kstToInstant, type KstDate } from '@/lms/rules/dates';
import { koZone, mdw, zoneLabel } from '@/lms/admin/students';
import { makeupRights, STATUS_PLAIN, type ChLesson, type MakeupLog, type MakeupRight } from '@/lms/admin/lesson-change';
import type { StudentLessonData, TutorPick } from '@/lms/admin/lesson-change-live';
import DateInput from '../../DateInput';
import TimeInput from '../../TimeInput';
import { Box, btnMain, btnSmall, btnSub, input, label, Sheet } from './parts';

export type LessonManageData = { lessons: StudentLessonData; logs: MakeupLog[]; tutors: TutorPick[] };
export type LessonManageActions = {
  load: () => Promise<LessonManageData>;
  add: (source: { lessonId?: string; itemId?: string; compId?: string }, tutorId: string, at: Date, note: string) => Promise<void>;
  edit: (lessonId: string, tutorId: string, at: Date, note: string) => Promise<void>;
};
type Student = { timezone: string };

const kst = (at: Date) => `${zoneLabel(at, 'Asia/Seoul')} 한국 시간`;
const kstDay = (at: Date) => mdw(instantToKstDate(at));
/** 한국 시간이 아닌 쪽만: '11/16(월) 오후 8:00 시드니 시간 (수강생) / 11/16(월) 오후 6:00 멜버른 시간 (강사)' */
function otherZones(at: Date, studentTz: string, tutorTz: string): string {
  const parts: string[] = [];
  if (studentTz && studentTz !== 'Asia/Seoul') parts.push(`${zoneLabel(at, studentTz)} ${koZone(studentTz)} (수강생)`);
  if (tutorTz && tutorTz !== 'Asia/Seoul') parts.push(`${zoneLabel(at, tutorTz)} ${koZone(tutorTz)} (강사)`);
  return parts.join(' / ');
}
const isComp = (l: ChLesson) => l.kind === 'compensation';
const KIND = (comp: boolean) => (comp ? '무료 보상수업' : '정규수업 보강');

function rightLabel(r: MakeupRight): string {
  if (r.kind === 'lesson') return `${kst(r.source.startsAt)} 수업${r.source.classStatus ? ` · ${STATUS_PLAIN[r.source.classStatus] ?? r.source.classStatus}` : ''}`;
  if (r.kind === 'migrated') return `시트 이관 보강${r.item.originalDate ? ` (원래 ${mdw(r.item.originalDate)})` : ''}`;
  return r.source ? `${kst(r.source.startsAt)} 수업 · 강사 노쇼` : '무료 보상수업';
}
const sourceOf = (r: MakeupRight) => (r.kind === 'lesson' ? { lessonId: r.source.id } : r.kind === 'compensation' ? { compId: r.comp.id } : { itemId: r.item.id });

type Form = { mode: 'add' } | { mode: 'edit'; lesson: ChLesson };

export default function LessonManage({ student, regularTutorId, finalEnd, actions }: {
  student: Student; regularTutorId: string | null; finalEnd: KstDate | null; actions: LessonManageActions;
}) {
  const [data, setData] = useState<LessonManageData | null>(null);
  const [loadErr, setLoadErr] = useState('');
  const [form, setForm] = useState<Form | null>(null);
  const [toast, setToast] = useState('');
  const reload = useCallback(async () => {
    try {
      setData(await actions.load());
      setLoadErr('');
    } catch (e) {
      setLoadErr(e instanceof Error ? e.message : '보강·보상수업을 읽지 못했어요.');
    }
  }, [actions]);
  useEffect(() => { void reload(); }, [reload]);
  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(''), 2600);
    return () => clearTimeout(t);
  }, [toast]);

  const now = useMemo(() => new Date(), [data]); // eslint-disable-line react-hooks/exhaustive-deps
  const d = data?.lessons;
  const byId = useMemo(() => new Map((d?.lessons ?? []).map((l) => [l.id, l])), [d]);
  const rights = useMemo(() => (d ? makeupRights(d.lessons, d.migrated, d.makeupRequests, d.compensations ?? []) : []), [d]);
  const makeupRightsList = rights.filter((r) => r.kind !== 'compensation');
  const compRights = rights.filter((r) => r.kind === 'compensation');
  const list = (d?.lessons ?? [])
    .filter((l) => ['makeup', 'migrated_makeup', 'compensation'].includes(l.kind) && l.state === 'scheduled' && !l.voided && +l.startsAt > +now)
    .sort((a, b) => +a.startsAt - +b.startsAt);
  const confirmedReq = (l: ChLesson) => d?.makeupRequests.find((r) => r.confirmedLessonId === l.id && r.status === 'confirmed') ?? null;
  const fromText = (l: ChLesson) => {
    const req = confirmedReq(l);
    const comp = req?.compensationId ? d?.compensations?.find((c) => c.id === req.compensationId) : undefined;
    const src = l.makeupOf ? byId.get(l.makeupOf) : comp ? byId.get(comp.sourceLessonId) : undefined;
    if (src) return `${kstDay(src.startsAt)} 수업분 ${isComp(l) ? '무료 보상수업' : '보강'}`;
    return l.kind === 'migrated_makeup' ? '시트 이관 보강' : KIND(isComp(l));
  };
  const logsFor = (l: ChLesson) => (data?.logs ?? []).filter((g) => g.lessonId === l.id);
  const logText = (g: MakeupLog) => {
    const parts: string[] = [];
    if (g.action === 'confirm') parts.push(`추가${g.newTutor ? ` (${g.newTutor})` : ''}`);
    else {
      if (!g.oldAt || +g.oldAt !== +g.newAt) parts.push(`시간 ${g.oldAt ? zoneLabel(g.oldAt, 'Asia/Seoul') : ''} → ${zoneLabel(g.newAt, 'Asia/Seoul')} 한국 시간`);
      if (g.oldTutor && g.newTutor && g.oldTutor !== g.newTutor) parts.push(`강사 ${g.oldTutor} → ${g.newTutor}`);
    }
    return `${zoneLabel(g.createdAt, 'Asia/Seoul')} 한국 시간 · 운영진 · ${parts.join(' · ')}${g.note ? ` · 메모: ${g.note}` : ''}`;
  };

  return (
    <Box title="보강·보상수업" action={
      <button type="button" className={btnSmall} disabled={!data || rights.length === 0} onClick={() => setForm({ mode: 'add' })}>+ 수업 추가</button>
    }>
      {loadErr && <p className="py-2 text-[13px] text-[#b3261e]">{loadErr}</p>}
      {data && (
        <p className="pb-1 text-[12.5px] text-[#6b6880]">남은 보강 {makeupRightsList.length}개 · 남은 무료 보상수업 {compRights.length}개</p>
      )}
      {data && list.length === 0 && <p className="py-2 text-[13px] text-[#6b6880]">예정된 보강·보상수업이 없어요.</p>}
      {list.map((l) => {
        const logs = logsFor(l);
        const editable = !!confirmedReq(l);
        return (
          <div key={l.id} className="mt-2 grid gap-1 rounded-[12px] border border-[#e6e3ef] px-3 py-2.5">
            <div className="flex flex-wrap items-center gap-2">
              <b className="text-[14px] text-[#1d1b2b]">{KIND(isComp(l))}</b>
              <span className="rounded-[7px] bg-[#e3f5ea] px-1.5 py-0.5 text-[12px] font-bold text-[#13623a]">확정</span>
            </div>
            <p className="text-[17px] font-extrabold text-[#1d1b2b]">{zoneLabel(l.startsAt, 'Asia/Seoul')} <span className="text-[13px] font-semibold text-[#6b6880]">한국 시간</span></p>
            <p className="text-[13.5px] font-semibold text-[#1d1b2b]">{l.tutorName} · {d?.enrollment?.durationMin ?? 40}분</p>
            {otherZones(l.startsAt, student.timezone, l.tutorTz) && <p className="text-[12.5px] text-[#6b6880]">{otherZones(l.startsAt, student.timezone, l.tutorTz)}</p>}
            <div className="mt-1 flex flex-wrap items-center justify-between gap-2 border-t border-[#f0eef6] pt-2">
              <span className="text-[12.5px] text-[#6b6880]">{fromText(l)}</span>
              {editable && <button type="button" className={btnSmall} onClick={() => setForm({ mode: 'edit', lesson: l })}>수정</button>}
            </div>
            {logs.length > 0 && (
              <details className="text-[12.5px] text-[#6b6880]">
                <summary className="cursor-pointer font-semibold">변경 기록 {logs.length}건</summary>
                <ul className="mt-1 grid gap-0.5 pl-4">{logs.map((g) => <li key={g.id} className="list-disc">{logText(g)}</li>)}</ul>
              </details>
            )}
          </div>
        );
      })}
      {toast && <p role="status" className="fixed bottom-24 left-1/2 z-50 -translate-x-1/2 rounded-[10px] bg-[#252039] px-4 py-2.5 text-[14px] text-white lg:bottom-8">{toast}</p>}
      {form && data && (
        <LessonForm form={form} data={data} rights={rights} studentTz={student.timezone} regularTutorId={regularTutorId} finalEnd={finalEnd}
          actions={actions} onClose={() => setForm(null)}
          onSaved={async (msg) => { setForm(null); setToast(msg); await reload(); }} />
      )}
    </Box>
  );
}

function LessonForm({ form, data, rights, studentTz, regularTutorId, finalEnd, actions, onClose, onSaved }: {
  form: Form; data: LessonManageData; rights: MakeupRight[]; studentTz: string; regularTutorId: string | null; finalEnd: KstDate | null;
  actions: LessonManageActions; onClose: () => void; onSaved: (msg: string) => Promise<void>;
}) {
  const edit = form.mode === 'edit' ? form.lesson : null;
  const mk = rights.filter((r) => r.kind !== 'compensation');
  const cp = rights.filter((r) => r.kind === 'compensation');
  const [comp, setComp] = useState(edit ? isComp(edit) : mk.length === 0);
  const pool = comp ? cp : mk;
  const [rightKey, setRightKey] = useState(pool[0]?.key ?? '');
  const right = pool.find((r) => r.key === rightKey) ?? pool[0] ?? null;
  const [tutorId, setTutorId] = useState(edit ? edit.tutorId : regularTutorId ?? '');
  const [date, setDate] = useState<KstDate | ''>(edit ? instantToKstDate(edit.startsAt) : '');
  const [time, setTime] = useState(edit ? zoneTime(edit.startsAt) : '');
  const [note, setNote] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const tutor = data.tutors.find((t) => t.id === tutorId) ?? null;
  // 지금 강사가 목록(활동 중)에 없으면 이름만이라도 보이게
  const tutorOptions = edit && !data.tutors.some((t) => t.id === edit.tutorId)
    ? [{ id: edit.tutorId, name: edit.tutorName, timezone: edit.tutorTz }, ...data.tutors] : data.tutors;
  const at = date && /^\d\d:\d\d$/.test(time) ? kstToInstant(date, time) : null;
  const duration = data.lessons.enrollment?.durationMin ?? 40;
  const unchanged = !!edit && !!at && +at === +edit.startsAt && tutorId === edit.tutorId;
  // 화면에서 바로 알 수 있는 것만 미리 막음. 강사 휴무·다른 수업·열린 시간·사용 기한은 저장할 때 DB 가 확인
  const pre = !at ? '' : +at <= Date.now() ? '지난 시간이에요.'
    : !comp && right?.kind === 'lesson' && right.source.classStatus !== 'Tutor long-term leave' && !edit && finalEnd && instantToKstDate(at) > finalEnd ? `수강 종료일(${mdw(finalEnd)}) 뒤의 날짜예요.`
    : studentClash(data, at, duration, edit?.id);
  const ok = !!at && !!tutor && !pre && !unchanged && (edit ? true : !!right);
  const dirty = !!(date || time || note) && !edit || (!!edit && (!unchanged || !!note));

  async function save() {
    if (!ok || !at || !tutor) return;
    setBusy(true);
    setErr('');
    try {
      if (edit) await actions.edit(edit.id, tutor.id, at, note.trim());
      else await actions.add(sourceOf(right!), tutor.id, at, note.trim());
      await onSaved(edit ? '저장했어요' : '확정했어요');
    } catch (e) {
      setErr(e instanceof Error ? e.message : '저장하지 못했어요.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <Sheet title={edit ? '수업 수정' : '수업 추가'} onClose={onClose} dirty={dirty}>
      <div className="grid gap-3">
        {edit && <p className="-mt-2 text-[13px] text-[#6b6880]">지금: {zoneLabel(edit.startsAt, 'Asia/Seoul')} 한국 시간 · {edit.tutorName}</p>}
        {!edit && (
          <div>
            <span className={label}>수업 종류</span>
            <div role="group" aria-label="수업 종류" className="grid grid-cols-2 gap-2">
              {([false, true] as const).map((c) => {
                const n = (c ? cp : mk).length;
                return (
                  <button key={String(c)} type="button" aria-pressed={comp === c} disabled={n === 0}
                    onClick={() => { setComp(c); setRightKey((c ? cp : mk)[0]?.key ?? ''); setErr(''); }}
                    className={`grid gap-0.5 rounded-[10px] border px-2 py-2.5 text-[14px] font-semibold disabled:opacity-40 ${comp === c ? 'border-2 border-[#5b3fe0] bg-[#f6f3ff] text-[#5b3fe0]' : 'border-[#e6e3ef] bg-white text-[#6b6880]'}`}>
                    {KIND(c)}<small className="text-[11.5px] font-medium">남은 {n}개</small>
                  </button>
                );
              })}
            </div>
          </div>
        )}
        {!edit && pool.length > 1 && (
          <label className="grid">
            <span className={label}>{comp ? '어느 수업의 보상수업인가요?' : '어느 수업의 보강인가요?'}</span>
            <select className={input} value={right?.key ?? ''} onChange={(e) => { setRightKey(e.target.value); setErr(''); }}>
              {pool.map((r) => <option key={r.key} value={r.key}>{rightLabel(r)}</option>)}
            </select>
          </label>
        )}
        {!edit && pool.length === 1 && right && (
          <div><span className={label}>{comp ? '어느 수업의 보상수업인가요?' : '어느 수업의 보강인가요?'}</span><p className="text-[14.5px] text-[#1d1b2b]">{rightLabel(right)}</p></div>
        )}
        <label className="grid">
          <span className={label}>강사</span>
          <select className={input} value={tutorId} onChange={(e) => { setTutorId(e.target.value); setErr(''); }}>
            {!tutorId && <option value="">강사 고르기</option>}
            {tutorOptions.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
          </select>
        </label>
        <label className="grid">
          <span className={label}>날짜 (한국 시간)</span>
          <DateInput aria-label="날짜 (한국 시간)" value={date} onChange={(v) => { setDate(v); setErr(''); }} className={input} />
        </label>
        <div>
          <span className={label}>시간 (한국 시간)</span>
          <TimeInput aria-label="시간 (한국 시간)" value={time} onChange={(v) => { setTime(v); setErr(''); }} className={input} />
          {(pre || err) && <p role="alert" className="mt-1 text-[13px] text-[#b3261e]">{pre || err}</p>}
        </div>
        {at && tutor && (
          <div className="grid gap-0.5 rounded-[10px] bg-[#f6f3ff] px-3 py-2.5 text-[13px] text-[#1d1b2b]">
            <b className="text-[15.5px]">{kst(at)}</b>
            <span>{tutor.name} · {duration}분</span>
            {otherZones(at, studentTz, tutor.timezone) && <span className="text-[#6b6880]">{otherZones(at, studentTz, tutor.timezone)}</span>}
          </div>
        )}
        <label className="grid">
          <span className={label}>운영 메모 <small className="font-normal text-[#6b6880]">선택 · 운영진만 보임</small></span>
          <input className={input} value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} />
        </label>
        {ok && (
          <p className="text-[13px] font-semibold text-[#1f7a4d]">
            {edit ? '변경권·보강권·수업 횟수 그대로' : `${comp ? '보상권' : '보강권'} 1개 사용 · 변경권 차감 없음`}
          </p>
        )}
        <div className="grid grid-cols-2 gap-2">
          <button type="button" className={btnSub} onClick={onClose}>닫기</button>
          <button type="button" className={btnMain} disabled={!ok || busy} onClick={save}>
            {busy ? '저장 중…' : edit ? '변경 저장' : '수업 확정'}
          </button>
        </div>
      </div>
    </Sheet>
  );
}

/** 한국 시각 'HH:MM' */
function zoneTime(at: Date): string {
  const k = new Date(+at + 9 * 3600e3);
  return `${String(k.getUTCHours()).padStart(2, '0')}:${String(k.getUTCMinutes()).padStart(2, '0')}`;
}
/** 학생 다른 수업과 겹침 (화면에서 바로 보이게. DB 도 막음) */
function studentClash(data: LessonManageData, at: Date, durationMin: number, self?: string): string {
  const end = +at + durationMin * 60e3;
  const hit = data.lessons.lessons.find((l) => l.id !== self && l.state !== 'canceled' && +l.startsAt < end && +at < +l.startsAt + durationMin * 60e3);
  return hit ? `학생 다른 수업: ${kst(hit.startsAt)} (${hit.tutorName})` : '';
}
