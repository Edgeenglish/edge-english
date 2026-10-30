'use client';

// 강사 휴무 화면 미리보기 (?demo=1): 가짜 데이터, 저장은 이 화면 안에서만. DB 함수(1800·2500)의 안내 기록 규칙을 흉내 냄
// 용도: 로그인 없이 화면 흐름 캡처·검토 (2026-10-30 대표: 흐름 검토용 시안)

import { useMemo, useState } from 'react';
import type { LvItem, LvNotice, LvTimeOff } from '@/lms/admin/tutor-leave';
import type { LvTutor } from '@/lms/admin/tutor-leave-live';
import TutorLeave, { type LeaveActions } from './TutorLeave';

const TUTORS: LvTutor[] = [
  { id: 't-emma', name: 'Emma', timezone: 'Australia/Sydney' },
  { id: 't-james', name: 'James', timezone: 'Asia/Manila' },
  { id: 't-noah', name: 'Noah', timezone: 'Asia/Manila' },
];
const name = (id: string | null) => TUTORS.find((t) => t.id === id)?.name ?? null;
const tz = (id: string | null) => TUTORS.find((t) => t.id === id)?.timezone ?? null;

type Db = { leaves: LvTimeOff[]; items: LvItem[]; notices: LvNotice[]; seq: number };

function seed(now: Date): Db {
  const day = (n: number, h: number) => { const d = new Date(now); d.setUTCHours(h - 9, 0, 0, 0); d.setUTCDate(d.getUTCDate() + n); return d; };
  const kst = (d: Date) => new Date(+d + 9 * 3600000).toISOString().slice(0, 10);
  const students = [
    { id: 's1', name: '김하준', en: 'Hajun Kim', code: 'STU-0101', days: [4, 6, 11], h: 20 },
    { id: 's2', name: '박서연', en: 'Seoyeon Park', code: 'STU-0102', days: [5, 12], h: 12 },
  ];
  const items: LvItem[] = students.flatMap((s) => s.days.map((d, k) => ({
    id: `${s.id}-${k}`, timeOffId: 'off1', studentId: s.id, studentName: s.name, studentNameEn: s.en, studentCode: s.code, studentTz: 'Asia/Seoul',
    durationMin: 40, isLesson: true, startsAt: day(d, s.h), choice: 'undecided' as const, subTutorId: null, subTutorName: null, subTutorTz: null,
    subStage: null, makeupAt: null, makeupRequested: false, lessonId: `l-${s.id}-${k}`, migratedItemId: null,
  })));
  return {
    leaves: [{ id: 'off1', tutorId: 't-emma', tutorName: 'Emma', from: kst(day(4, 12)), to: kst(day(12, 12)), reason: '개인 일정' }],
    items,
    notices: items.map((i) => ({ id: `n-lo-${i.id}`, itemId: i.id, event: 'leave_options' as const, recipientKind: 'student' as const, recipientId: i.studentId, status: 'pending' as const, sentAt: null })),
    seq: 0,
  };
}

export default function LeaveDemo({ nowIso }: { nowIso: string }) {
  const [db] = useState<Db>(() => seed(new Date(nowIso)));
  const actions = useMemo<LeaveActions>(() => {
    const note = (itemId: string, event: LvNotice['event'], kind: 'student' | 'tutor', to: string) =>
      db.notices.push({ id: `n${++db.seq}`, itemId, event, recipientKind: kind, recipientId: to, status: 'pending', sentAt: null });
    const drop = (itemId: string, keep: (n: LvNotice) => boolean) => {
      db.notices = db.notices.map((n) => (n.itemId === itemId && n.status === 'pending' && !keep(n) ? { ...n, status: 'not_needed' } : n));
    };
    const edit = (ids: string[], f: (i: LvItem) => LvItem) => { db.items = db.items.map((i) => (ids.includes(i.id) ? f(i) : i)); };
    return {
      leaves: async () => [...db.leaves],
      items: async (id) => ({ items: db.items.filter((i) => i.timeOffId === id), notices: [...db.notices] }),
      renewals: async () => [],
      create: async (tutorId, from, to, reason, dryRun) => {
        if (dryRun) return { dry_run: true, lessons: 0, items: 0, students: 0 };
        const id = `off${db.leaves.length + 1}`;
        db.leaves.push({ id, tutorId, tutorName: name(tutorId) ?? '', from, to, reason: reason || null });
        return { dry_run: false, time_off_id: id, lessons: 0, items: 0, students: 0 };
      },
      choose: async (ids, choice, sub) => {
        for (const id of ids) drop(id, (n) => n.event === 'leave_options');
        edit(ids, (i) => ({ ...i, choice, subTutorId: sub, subTutorName: name(sub), subTutorTz: tz(sub), subStage: choice === 'substitute' ? 'asked' : null }));
        if (choice === 'substitute' && sub) for (const id of ids) note(id, 'sub_ask', 'tutor', sub);
      },
      subOk: async (ids) => {
        edit(ids, (i) => ({ ...i, subStage: 'tutor_ok' }));
        const at = new Date(); db.notices = db.notices.map((n) => (ids.includes(n.itemId) && n.event === 'sub_ask' && n.status === 'pending' ? { ...n, status: 'sent', sentAt: at } : n));
        for (const id of ids) note(id, 'sub_student', 'student', db.items.find((i) => i.id === id)!.studentId);
      },
      studentOk: async (ids) => {
        edit(ids, (i) => ({ ...i, subStage: 'confirmed' }));
        for (const id of ids) {
          const it = db.items.find((i) => i.id === id)!;
          note(id, 'sub_confirmed', 'tutor', it.subTutorId!);
          note(id, 'sub_confirmed', 'student', it.studentId);
        }
      },
      back: async (ids, to) => {
        for (const id of ids) drop(id, (n) => (to === 'undecided' ? n.event === 'leave_options' : to === 'asked' ? n.event === 'leave_options' || n.event === 'sub_ask' : n.event !== 'sub_confirmed'));
        edit(ids, (i) => (to === 'undecided'
          ? { ...i, choice: 'undecided', subTutorId: null, subTutorName: null, subTutorTz: null, subStage: null }
          : { ...i, subStage: to }));
      },
      unsend: async (ids) => { db.notices = db.notices.map((n) => (ids.includes(n.id) ? { ...n, status: 'pending', sentAt: null } : n)); },
      markSent: async (ids) => { const at = new Date(); db.notices = db.notices.map((n) => (ids.includes(n.id) ? { ...n, status: 'sent', sentAt: at } : n)); },
      subOptions: async (ids) => [
        { tutorId: 't-james', name: 'James', timezone: 'Asia/Manila', free: ids.length, busyDates: [], offHours: [] },
        { tutorId: 't-noah', name: 'Noah', timezone: 'Asia/Manila', free: Math.max(0, ids.length - 1), busyDates: ids.length > 1 ? ['날짜 1개'] : [], offHours: [] },
      ],
      makeupOptions: async () => {
        const base = new Date(nowIso);
        return [14, 15, 16].map((d) => ({ section: 'in_period' as const, startsAt: new Date(+base + d * 86400000) }));
      },
      requestMakeup: async (src) => { edit(db.items.filter((i) => i.id === src.itemId || i.lessonId === src.lessonId).map((i) => i.id), (i) => ({ ...i, makeupRequested: true })); },
    };
  }, [db, nowIso]);
  return <TutorLeave tutors={TUTORS} actions={actions} nowIso={nowIso} />;
}
