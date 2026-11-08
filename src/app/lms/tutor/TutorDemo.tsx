'use client';

// 강사 화면 미리보기 (?demo=1): 가짜 데이터, 저장은 이 화면 안에서만
import { useMemo, useState } from 'react';
import { fakeHours, fakeScheduleStore, fakeStudentProfile, fakeTutorScreen } from '@/lms/tutor/fake';
import type { HoursData } from '@/lms/tutor/hours';
import { lateToSave, savedStatus, type TutorScreen } from '@/lms/tutor/screen';
import TutorHome, { type TutorActions } from './TutorHome';

export default function TutorDemo({ nowIso }: { nowIso: string }) {
  const [data] = useState<{ s: TutorScreen; h: HoursData }>(() => ({ s: fakeTutorScreen(new Date(nowIso)), h: fakeHours(new Date(nowIso)) }));
  const [sched] = useState(() => fakeScheduleStore(new Date(nowIso), data.h, data.s.lessons));
  const actions = useMemo<TutorActions>(() => ({
    load: async () => ({ ...data.s }),
    record: async (id, r, topics, remarks, late) => {
      const s = data.s;
      const lt = lateToSave(r, late);
      s.lessons = s.lessons.map((l) => (l.id === id ? { ...l, state: 'done', classStatus: savedStatus(l, r, lt.tutor), topics: topics || null, remarks: remarks || null, studentLate: lt.student, late: lt } : l));
      s.toRecord = s.toRecord.filter((x) => x !== id);
    },
    answer: async (id, yes, note) => {
      data.s.makeups = data.s.makeups.map((m) => (m.id === id
        ? { ...m, note: note || null, answeredAt: new Date(), slots: m.slots.map((x) => ({ ...x, answer: yes.includes(x.id) ? 'yes' as const : 'no' as const })) } : m));
    },
    confirm: async (id) => {
      data.s.makeups = data.s.makeups.filter((m) => m.id !== id);
    },
    answerCover: async (items) => {
      data.s.covers = data.s.covers.filter((c) => !items.includes(c.id));
    },
    hours: {
      load: async () => ({ ...data.h, cells: { ...data.h.cells } }),
      save: async (weekly, close, open) => {
        const h = data.h;
        if (weekly) h.weeklyOpen = weekly;
        close.forEach((k) => { h.cells[k] = 'b'; });
        open.forEach((k) => { delete h.cells[k]; });
      },
    },
    schedule: { load: sched.load, save: sched.save },
    profile: {
      load: async (id) => fakeStudentProfile(id, new Date(nowIso)),
      save: async () => {},
    },
    followups: async () => [{ studentId: 'demo-hajun', student: 'Hajun Kim', firstLessonAt: new Date(+new Date(nowIso) - 86400000 * 2), pending: 4, done: { level: false, improve: false, style: false, docs: false } }],
    canceled: async () => [
      ['demo-cx1', 'Hajun Kim', 'demo-hajun', 1.4, 'Student canceled in advance'],
      ['demo-cx2', 'Yuna Park', 'demo-yuna', 1.9, 'Student canceled late'],
      ['demo-cx3', 'Minho Choi', 'demo-minho', 2.3, 'Student canceled in advance'],
      ['demo-cx4', 'Sora Han', 'demo-sora', 3.1, 'Student canceled in advance'],
    ].map(([id, student, studentId, d, classStatus]) => ({ id: id as string, startsAt: new Date(+new Date(nowIso) + 86400000 * (d as number)), endsAt: new Date(+new Date(nowIso) + 86400000 * (d as number) + 3000000), kind: 'regular' as const, classStatus: classStatus as 'Student canceled late', student: student as string, studentId: studentId as string })),
    followupSave: async () => ({ firstLesson: { id: 'd1', startsAt: new Date(+new Date(nowIso) - 86400000 * 2), status: 'Normal', topics: 'Travel plans, airports', recordedAt: new Date() }, done: { level: true, improve: true, style: true, docs: true }, pending: 0 }),
    students: async () => [
      { id: 'demo-hajun', name: 'Hajun Kim', level: 'Intermediate', classType: 'Free talking', timezone: 'Asia/Seoul', noteUrl: 'https://docs.google.com/' },
      { id: 'demo-seoyeon', name: 'Seoyeon Park (Sarah)', level: 'Pre-Intermediate', classType: 'Textbook', timezone: 'Australia/Melbourne', noteUrl: null },
    ],
  }), [data, nowIso, sched]);
  return <TutorHome initial={data.s} nowIso={nowIso} actions={actions} />;
}
