'use client';

import { useMemo } from 'react';
import { fakeDirectory } from '@/lms/admin/fake-directory';
import { fakeApplications, fakeRegTutors } from '@/lms/admin/fake-registration';
import NewStudent from './NewStudent';

// 가상 데이터 미리보기: 저장 버튼은 검사만 하고 실제로 저장하지 않음
export default function NewStudentDemo({ nowIso }: { nowIso: string }) {
  const now = useMemo(() => new Date(nowIso), [nowIso]);
  const applications = useMemo(() => fakeApplications(now), [now]);
  const tutors = useMemo(() => fakeRegTutors(now), [now]);
  const emails = useMemo(() => fakeDirectory(now).students.map((s) => ({ code: s.code, name_ko: s.name, email: s.email })), [now]);
  return (
    <NewStudent
      nowIso={nowIso}
      demo
      applications={applications}
      tutors={tutors}
      save={async () => ({ kind: 'preview' })}
      sameEmail={async (email) => emails.filter((s) => s.email === email.toLowerCase())}
    />
  );
}
