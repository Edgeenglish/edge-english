'use client';

// 강사 화면 미리보기 (?demo=1): 가짜 데이터, 저장은 이 화면 안에서만
import { useMemo, useState } from 'react';
import { fakeTutorScreen } from '@/lms/tutor/fake';
import { savedStatus, type TutorScreen } from '@/lms/tutor/screen';
import TutorHome, { type TutorActions } from './TutorHome';

export default function TutorDemo({ nowIso }: { nowIso: string }) {
  const [data] = useState<{ s: TutorScreen }>(() => ({ s: fakeTutorScreen(new Date(nowIso)) }));
  const actions = useMemo<TutorActions>(() => ({
    load: async () => ({ ...data.s }),
    record: async (id, r, topics, remarks, late) => {
      const s = data.s;
      s.lessons = s.lessons.map((l) => (l.id === id ? { ...l, state: 'done', classStatus: savedStatus(l, r), topics: topics || null, remarks: remarks || null, studentLate: r === 'held' && late } : l));
      s.toRecord = s.toRecord.filter((x) => x !== id);
    },
    answer: async (id, yes, note) => {
      data.s.makeups = data.s.makeups.map((m) => (m.id === id
        ? { ...m, note: note || null, answeredAt: new Date(), slots: m.slots.map((x) => ({ ...x, answer: yes.includes(x.id) ? 'yes' as const : 'no' as const })) } : m));
    },
    answerCover: async (items) => {
      data.s.covers = data.s.covers.filter((c) => !items.includes(c.id));
    },
  }), [data]);
  return <TutorHome initial={data.s} nowIso={nowIso} actions={actions} />;
}
