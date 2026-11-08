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
// admin: 운영자 보기 모습(시간 전환 버튼) 확인용 — 가상 데이터만
export default function StudentDemo({ nowIso, tz, admin }: { nowIso: string; tz?: string; admin?: boolean }) {
  const store = useMemo(() => fakeStore(new Date(nowIso)), [nowIso]);
  const view = tz && isZone(tz) ? { ...store.view, timezone: tz } : store.view;
  const adminBar = admin ? <div className="mb-3 rounded-[12px] bg-[#1d1b2b] px-3 py-2 text-[13px] font-semibold text-white">운영자 보기 (미리보기)</div> : undefined;
  return <StudentHome nowIso={nowIso} initial={view} actions={store.actions} extras={store.extras} preview adminBar={adminBar} />;
}
