'use client';

import { useMemo } from 'react';
import { fakeStore } from '@/lms/student/fake-data';
import StudentHome from './StudentHome';

const isZone = (z: string) => {
  try {
    new Intl.DateTimeFormat('en', { timeZone: z });
    return true;
  } catch {
    return false;
  }
};

// 가상 데이터 미리보기 (저장·발송 없음)
export default function StudentDemo({ nowIso, tz, makeup }: { nowIso: string; tz?: string; makeup?: string }) {
  const store = useMemo(() => fakeStore(new Date(nowIso)), [nowIso]);
  const view = tz && isZone(tz) ? { ...store.view, timezone: tz } : store.view;
  return <StudentHome nowIso={nowIso} initial={view} actions={store.actions} extras={store.extras} preview openMakeup={makeup} />;
}
