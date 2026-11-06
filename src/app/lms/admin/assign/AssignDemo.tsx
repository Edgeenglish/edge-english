'use client';

import { useMemo } from 'react';
import { addDays, instantToKstDate } from '@/lms/rules/dates';
import { fakeRegTutors } from '@/lms/admin/fake-registration';
import AssignSchedule from './AssignSchedule';

// 가상 미리보기: 대시보드의 가상학생삼(결제 확인, 강사 미정)
export default function AssignDemo({ nowIso }: { nowIso: string }) {
  const now = useMemo(() => new Date(nowIso), [nowIso]);
  const tutors = useMemo(() => fakeRegTutors(now), [now]);
  const info = {
    enrollmentId: 'demo',
    studentCode: 'STU-9003',
    studentName: '가상학생삼',
    nameEn: 'Fake Three',
    place: '미국 뉴욕',
    timezone: 'America/New_York',
    weeks: 12 as const,
    weeklyCount: 1,
    durationMin: 50,
    startWish: addDays(instantToKstDate(now), 5),
  };
  return <AssignSchedule nowIso={nowIso} demo info={info} tutors={tutors} propose={null} />;
}
