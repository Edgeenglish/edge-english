'use client';

import { useMemo } from 'react';
import { fakeStore } from '@/lms/student/fake-data';
import StudentHome from './StudentHome';

// 가상 데이터 미리보기 (저장·발송 없음)
export default function StudentDemo({ nowIso }: { nowIso: string }) {
  const store = useMemo(() => fakeStore(new Date(nowIso)), [nowIso]);
  return <StudentHome nowIso={nowIso} initial={store.view} actions={store.actions} extras={store.extras} preview />;
}
