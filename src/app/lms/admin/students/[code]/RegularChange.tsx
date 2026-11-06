'use client';

// ① 정규 일정 수정 (H26(44) ①·②): 요일·시작 시간(한국 시간)·적용 시작일 → 바뀌는 수업 전체 미리 보기 → 검사 → 사유 → 저장
// 주 횟수·수업 길이·강사는 여기서 바꾸지 않음. 종료일은 연장하지 않음(넘치면 저장 차단). 검사·저장은 DB 함수가 다시 함
// A-03 (20261107): '지금 적용 중' 과 '○○부터 적용 예정'(data.nextSlots) 을 구분. 적용 예정 변경은 적용일 전에 취소([예정 변경 취소] = 원래 일정을
// 적용 예정일부터 다시 저장)·수정(새 시간 고르기)할 수 있음. '같은 일정' 판정은 고른 적용 시작일에 유효한 일정 기준, 그 뒤 예정 변경이 있으면 같다고 보지 않음
import { useEffect, useMemo, useState } from 'react';
import { formatInZone, kstToInstant, type KstDate } from '@/lms/rules/dates';
import {
  dateOptions, KEPT_WHY, KIND_KO, koZone, kstWithZones, mdw, problemText, slotsInZone, slotsText, WD_KO, zoneLabel,
  type RegularPreview, type Slot, type SlotFull, type StudentDetailData,
} from '@/lms/admin/students';
import TimeInput from '../../TimeInput';
import { btnMain, btnSub, input, label, Sheet } from './parts';

export default function RegularChange({ data, today, preview, save, onClose, onSaved }: {
  data: StudentDetailData; today: KstDate;
  preview: (slots: Slot[], from: KstDate) => Promise<RegularPreview>;
  save: (slots: Slot[], from: KstDate, reason: string) => Promise<{ changeId: string; moved: number }>;
  onClose: () => void; onSaved: (changeId: string) => Promise<void>;
}) {
  const cur: SlotFull[] = data.slots;
  const e = data.enrollment;
  const n = cur.length;
  const tutor = cur[0];
  const stTz = data.student.timezone;
  const minFrom = e && e.startDate > today ? e.startDate : today;
  const dates = useMemo(() => (e ? dateOptions(minFrom, e.finalEndDate) : []), [e, minFrom]);
  const [from, setFrom] = useState<KstDate>(dates[0] ?? today);
  // 아직 적용 전인 변경 (가장 가까운 것). 적용 시작일이 그 날 이후면 그 일정이 '그때 유효한 일정'
  const pending: Slot[] = data.nextSlots.map((s) => ({ weekday: s.weekday, time: s.time }));
  const pendingFrom: KstDate | null = data.nextSlots[0]?.from ?? null;
  // 고른 요일 → 시간 (처음엔 지금 일정 그대로)
  const [times, setTimes] = useState<Record<number, string>>(() => Object.fromEntries(cur.map((s) => [s.weekday, s.time])));
  const [order, setOrder] = useState<number[]>(() => cur.map((s) => s.weekday));
  // 바뀌는 수업·그대로 두는 수업은 기본 6·8회만 보이고 [전체 보기]로 모두 펼침 (QA-04: 정책 '변경될 향후 수업 전체 확인')
  const [showAllMoved, setShowAllMoved] = useState(false);
  const [showAllKept, setShowAllKept] = useState(false);
  const [reason, setReason] = useState('');
  const [pv, setPv] = useState<RegularPreview | null>(null);
  const [pvErr, setPvErr] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');

  const slots: Slot[] = order.map((w) => ({ weekday: w, time: times[w] ?? '' })).sort((a, b) => a.weekday - b.weekday);
  const complete = order.length === n && slots.every((s) => /^\d\d:\d\d$/.test(s.time) && ['00', '30'].includes(s.time.slice(3)));
  const plain = (xs: Slot[]) => JSON.stringify([...xs].map((s) => ({ weekday: s.weekday, time: s.time })).sort((a, b) => a.weekday - b.weekday));
  const effectiveAtFrom: Slot[] = pendingFrom && from >= pendingFrom ? pending : cur;
  const cancelsPending = !!pendingFrom && from < pendingFrom;   // 저장하면 그 뒤 예정 변경은 취소됨 (DB 도 같은 기준)
  const same = complete && plain(slots) === plain(effectiveAtFrom) && !cancelsPending;
  const key = complete ? `${from}|${JSON.stringify(slots)}` : '';

  /** [예정 변경 취소]: 원래(지금 적용 중) 일정을 적용 예정일부터 다시 저장 → 옮겨 둔 수업이 원래 시각으로 돌아오고 예정 줄은 치워짐. 변경권·수업 수 변화 없음 */
  function cancelPending() {
    if (!pendingFrom) return;
    setOrder(cur.map((s) => s.weekday));
    setTimes(Object.fromEntries(cur.map((s) => [s.weekday, s.time])));
    setFrom(dates.includes(pendingFrom) ? pendingFrom : dates[0] ?? today);
    if (!reason.trim()) setReason('예정 변경 취소');
  }

  function toggle(w: number) {
    if (order.includes(w)) return setOrder(order.filter((x) => x !== w));
    if (order.length >= n) return;   // 주 횟수만큼만
    setOrder([...order, w]);
    if (!times[w]) setTimes({ ...times, [w]: cur[order.length]?.time ?? cur[0]?.time ?? '' });
  }

  // 조건이 갖춰지면 미리 보기 자동 (짧게 기다렸다가)
  useEffect(() => {
    setPv(null);
    setPvErr('');
    if (!key || same) return;
    const t = setTimeout(async () => {
      try {
        setPv(await preview(slots, from));
      } catch (x) {
        setPvErr(x instanceof Error ? x.message : '미리 보기를 못 불러왔어요.');
      }
    }, 350);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- key 가 slots·from 을 대표
  }, [key, same]);

  async function onSave() {
    if (!pv?.ok || !reason.trim()) return;
    setBusy(true);
    setErr('');
    try {
      const r = await save(slots, from, reason.trim());
      await onSaved(r.changeId);
    } catch (x) {
      setErr(x instanceof Error ? x.message : '저장하지 못했어요.');
      setBusy(false);
    }
  }

  if (!e || n === 0) {
    return (
      <Sheet title="정규 일정 수정" onClose={onClose}>
        <p className="text-[14px] text-[#6b6880]">{!e ? '수강 중이거나 시작 예정인 수강권이 없어요.' : '이 학생의 정규 일정이 없어요 (등록·이관 때 정규 일정이 만들어져요).'}</p>
      </Sheet>
    );
  }
  const zones = [{ label: '학생', tz: stTz }, { label: '강사', tz: tutor.tutorTz }];
  const shown = pv ? (showAllMoved ? pv.moved : pv.moved.slice(0, 6)) : [];
  const keptShown = pv ? (showAllKept ? pv.kept : pv.kept.slice(0, 8)) : [];
  // 강사 현지 예시: 첫 수업의 실제 시점을 날짜·요일·시각 함께 변환 (QA-09: 한국 날짜 + 현지 시각을 붙이면 틀림)
  const firstMovedTo = pv && pv.moved.length > 0 ? pv.moved[0].to : complete ? kstToInstant(from, slots[0]?.time || cur[0].time) : null;
  const tutorLocalNew = slotsInZone(slots.length === n && complete ? slots : [], tutor.tutorTz, from);
  return (
    <Sheet title="정규 일정 수정" onClose={onClose} wide>
      <p className="mb-1 text-[13px] text-[#6b6880]">
        지금 적용 중: {slotsText(cur)} (한국 시간) · {e.durationMin}분 · {tutor.tutor} 강사. 요일·시작 시간만 바꿔요. 주 {n}회·수업 길이·강사는 그대로예요.
      </p>
      {pendingFrom && (
        <div className="mb-3 flex flex-wrap items-center gap-2 rounded-[10px] border border-[#d9d2f5] bg-[#f3f0fd] px-3 py-2 text-[13.5px] text-[#1d1b2b]">
          <span><b>{mdw(pendingFrom)}부터 적용 예정:</b> {slotsText(pending)} (한국 시간)</span>
          <button type="button" className={`${btnSub} !min-h-[36px] !py-1 text-[13px]`} onClick={cancelPending} disabled={busy}>예정 변경 취소</button>
        </div>
      )}
      {!pendingFrom && <div className="mb-2" />}
      <div className="grid gap-3 lg:grid-cols-[1fr_1.2fr]">
        <div className="grid gap-3">
          <div>
            <span className={label}>요일 (한국 시간 기준) · {n}개 고르기</span>
            <div className="flex flex-wrap gap-1.5">
              {WD_KO.map((d, w) => {
                const on = order.includes(w);
                return (
                  <button key={d} type="button" aria-pressed={on} onClick={() => toggle(w)} disabled={!on && order.length >= n}
                    className={`min-h-[44px] min-w-[44px] rounded-[10px] px-3 text-[15px] font-semibold ${on ? 'bg-[#5b3fe0] text-white' : 'border border-[#e6e3ef] bg-white text-[#1d1b2b] disabled:opacity-40'}`}>
                    {d}
                  </button>
                );
              })}
            </div>
          </div>
          {slots.map((s) => (
            <div key={s.weekday} className="grid grid-cols-[minmax(0,1fr)_120px] items-center gap-2">
              <label htmlFor={`t-${s.weekday}`} className="text-[14px] text-[#1d1b2b]">
                {WD_KO[s.weekday]}요일 시작 시간 <span className="block text-[12px] text-[#6b6880]">한국 시간 · 30분 단위</span>
              </label>
              <TimeInput id={`t-${s.weekday}`} value={times[s.weekday] ?? ''} onChange={(v) => setTimes({ ...times, [s.weekday]: v })} className={`${input.replace('w-full', 'w-[120px]')} text-center`} />
            </div>
          ))}
          <div>
            <label htmlFor="rc-from" className={label}>적용 시작일 (한국 날짜)</label>
            <select id="rc-from" value={from} onChange={(e2) => setFrom(e2.target.value)} className={input}>
              {dates.map((d) => <option key={d} value={d}>{mdw(d)}부터</option>)}
            </select>
          </div>
          {complete && (
            <div className="rounded-[10px] bg-white px-3 py-2 text-[13.5px] text-[#1d1b2b]">
              <p><b>한국 시간</b> {slotsText(slots)} · {e.durationMin}분</p>
              {stTz !== 'Asia/Seoul' && <p><b>학생 — {koZone(stTz)}</b> {slotsInZone(slots, stTz, from)} <span className="text-[#6b6880]">({mdw(from)} 수업 기준)</span></p>}
              {tutor.tutorTz !== 'Asia/Seoul' && <p><b>강사 {tutor.tutor} — {koZone(tutor.tutorTz)}</b> {tutorLocalNew}</p>}
            </div>
          )}
          <div>
            <label htmlFor="rc-reason" className={label}>사유 (필수)</label>
            <input id="rc-reason" value={reason} onChange={(e2) => setReason(e2.target.value)} placeholder="예: 학생 요청 (11/3 카톡)" className={input} />
          </div>
        </div>

        <div className="grid content-start gap-2">
          {same && <p className="rounded-[10px] bg-white px-3 py-2 text-[13.5px] text-[#6b6880]">{pendingFrom && from >= pendingFrom ? `${mdw(pendingFrom)}부터 적용 예정인 일정과 같아요.` : '지금 정규 일정과 같아요.'} 바꿀 요일·시간을 골라 주세요.</p>}
          {!complete && !same && <p className="rounded-[10px] bg-white px-3 py-2 text-[13.5px] text-[#6b6880]">요일 {n}개와 시작 시간을 고르면 바뀌는 수업을 미리 보여 드려요.</p>}
          {pvErr && <p className="rounded-[10px] bg-[#fdecea] px-3 py-2 text-[13.5px] text-[#b3261e]">{pvErr}</p>}
          {complete && !same && !pv && !pvErr && <p className="text-[13px] text-[#6b6880]">미리 보기 계산 중…</p>}
          {pv && (
            <>
              {(pv.cancelsPending || cancelsPending) && pendingFrom && (
                <p className="rounded-[10px] bg-[#f3f0fd] px-3 py-2 text-[13.5px] text-[#1d1b2b]">
                  저장하면 <b>{mdw(pendingFrom)}부터 적용 예정</b>이던 변경({slotsText(pending)})은 취소되고, {mdw(from)}부터 아래 일정이 적용돼요.
                </p>
              )}
              <section className="rounded-[12px] border border-[#e6e3ef] bg-white px-3 py-2">
                <h3 className="text-[13px] font-extrabold text-[#6b6880]">바뀌는 수업 {pv.moved.length}회</h3>
                <ul className="mt-1 grid gap-1.5 text-[13.5px]">
                  {shown.map((m) => {
                    const p = pv.problems.find((x) => x.lessonId === m.lessonId);
                    return (
                      <li key={m.lessonId} className={`rounded-[8px] px-2 py-1 ${p ? 'bg-[#fdecea]' : 'bg-[#f7f6fb]'}`}>
                        <span className="text-[#6b6880]">{m.seq ? `정규 ${m.seq}회 · ` : ''}{zoneLabel(m.from, 'Asia/Seoul')} →</span>{' '}
                        <b>{kstWithZones(m.to, zones)}</b>
                        {p && <span className="block text-[12.5px] font-semibold text-[#b3261e]">✕ {problemText(p, pv.tutor)}</span>}
                      </li>
                    );
                  })}
                  {pv.moved.length > shown.length && (
                    <li className="text-[12.5px] text-[#6b6880]">
                      … {mdw(formatInZone(pv.moved[pv.moved.length - 1].to, 'Asia/Seoul').date)}까지 {pv.moved.length - shown.length}회 더 (같은 요일·시각){' '}
                      <button type="button" className="font-semibold text-[#5b3fe0] underline" onClick={() => setShowAllMoved(true)}>전체 {pv.moved.length}회 보기</button>
                    </li>
                  )}
                  {showAllMoved && pv.moved.length > 6 && <li className="text-[12.5px]"><button type="button" className="font-semibold text-[#5b3fe0] underline" onClick={() => setShowAllMoved(false)}>접기</button></li>}
                </ul>
                {pv.skipped.length > 0 && (
                  <p className="mt-1 text-[12.5px] text-[#6b6880]">건너뛴 날: {pv.skipped.map((s) => `${mdw(s.date)} ${s.time}`).join(', ')} — 그날 학생의 다른 수업(보강·대체 등)이 있어 다음 회차로</p>
                )}
              </section>
              {pv.kept.length > 0 && (
                <section className="rounded-[12px] border border-[#e6e3ef] bg-white px-3 py-2">
                  <h3 className="text-[13px] font-extrabold text-[#6b6880]">그대로 두는 수업 {pv.kept.length}회</h3>
                  <ul className="mt-1 grid gap-1 text-[13px] text-[#1d1b2b]">
                    {keptShown.map((k) => (
                      <li key={k.lessonId}>{zoneLabel(k.startsAt, 'Asia/Seoul')} (한국 시간) · {KIND_KO[k.kind] ?? k.kind}{k.why === 'substitute' ? ` · 대체 ${k.tutor}` : ''} <span className="text-[#6b6880]">— {KEPT_WHY[k.why] ?? k.why}</span></li>
                    ))}
                    {pv.kept.length > keptShown.length && (
                      <li className="text-[12.5px] text-[#6b6880]">… {pv.kept.length - keptShown.length}회 더 <button type="button" className="font-semibold text-[#5b3fe0] underline" onClick={() => setShowAllKept(true)}>전체 {pv.kept.length}회 보기</button></li>
                    )}
                    {showAllKept && pv.kept.length > 8 && <li className="text-[12.5px]"><button type="button" className="font-semibold text-[#5b3fe0] underline" onClick={() => setShowAllKept(false)}>접기</button></li>}
                  </ul>
                </section>
              )}
              <section className="rounded-[12px] border border-[#e6e3ef] bg-white px-3 py-2">
                <h3 className="text-[13px] font-extrabold text-[#6b6880]">검사</h3>
                <ul className="mt-1 grid gap-1 text-[13.5px]">
                  {([
                    [['tutor_hours_range'], `강사 시작 시각이 ${koZone(pv.tutor.timezone)} 06:00~22:30 안`],
                    [['tutor_unavailable'], `${pv.tutor.name} 가능 시간(My hours) 안`],
                    [['tutor_busy', 'tutor_time_off', 'tutor_hold'], '다른 수업·휴무·재등록 대기 자리와 겹치지 않음 (휴식 10분 포함)'],
                    [['after_end'], `마지막 수업 ${pv.lastDate ? mdw(pv.lastDate) : '—'} ≤ 최종 종료일 ${mdw(pv.enrollment.finalEndDate)} (종료일은 연장하지 않음)`],
                  ] as [string[], string][]).map(([whys, label2]) => {
                    const bad = pv.problems.some((p) => whys.includes(p.why));
                    // 한 수업에 문제가 있으면 그 뒤 검사는 하지 않음 → ✓ 대신 '앞 문제 고친 뒤 검사'
                    const state = bad ? 'bad' : pv.problems.length > 0 ? 'skip' : 'ok';
                    return <Check key={label2} state={state} text={label2} />;
                  })}
                </ul>
                {pv.problems.length > 0 && (
                  <ul className="mt-2 grid gap-1 text-[13px] text-[#b3261e]">
                    {pv.problems.map((p) => <li key={`${p.lessonId}-${p.why}`}>✕ {problemText(p, pv.tutor)}</li>)}
                  </ul>
                )}
              </section>
            </>
          )}
        </div>
      </div>
      {err && <p className="mt-3 rounded-[10px] bg-[#fdecea] px-3 py-2 text-[14px] text-[#b3261e]">{err}</p>}
      <div className="mt-4 flex gap-2">
        <button type="button" className={btnSub} onClick={onClose} disabled={busy}>취소</button>
        <button type="button" className={`${btnMain} flex-1`} disabled={!pv?.ok || !reason.trim() || busy} onClick={onSave}>
          {busy ? '저장 중…' : pv ? pv.moved.length === 0 && (pv.cancelsPending || cancelsPending) ? '예정 변경 취소하고 저장' : `${pv.moved.length}회 바꾸고 저장${pv.kept.filter((k) => k.why === 'same').length ? ` · ${pv.kept.filter((k) => k.why === 'same').length}회 유지` : ''}` : '저장'}
        </button>
      </div>
      <p className="mt-2 text-[12px] text-[#6b6880]">
        저장하면 학생·강사·운영진 화면에 바로 반영돼요. 저장 뒤 학생(카카오톡)·강사(WhatsApp) 안내 문구를 복사해 보내고 [발송 완료]를 눌러 주세요. 지난 수업과 이미 확정된 보강·대체 수업은 바뀌지 않아요.
        {tutor.tutorTz !== 'Asia/Seoul' && firstMovedTo && ` 강사 현지 시각은 수업 날짜마다 다시 계산해요 (예: 한국 ${zoneLabel(firstMovedTo, 'Asia/Seoul')} = ${koZone(tutor.tutorTz)} ${zoneLabel(firstMovedTo, tutor.tutorTz)}).`}
      </p>
    </Sheet>
  );
}

function Check({ state, text }: { state: 'ok' | 'bad' | 'skip'; text: string }) {
  if (state === 'skip') return <li className="text-[#6b6880]">· {text} <span className="text-[12px]">(위 문제를 고친 뒤 검사)</span></li>;
  return <li className={state === 'ok' ? 'text-[#13623a]' : 'text-[#b3261e]'}>{state === 'ok' ? '✓' : '✕'} {text}</li>;
}
