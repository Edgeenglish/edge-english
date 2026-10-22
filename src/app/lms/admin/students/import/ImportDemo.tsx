'use client';

import { useMemo } from 'react';
import { fakeRegTutors } from '@/lms/admin/fake-registration';
import ImportStudent from './ImportStudent';

// 가상 데이터 미리보기: 저장 버튼은 검사만 하고 실제로 저장하지 않음
export default function ImportDemo({ nowIso }: { nowIso: string }) {
  const tutors = useMemo(() => fakeRegTutors(new Date(nowIso)), [nowIso]);
  return <ImportStudent nowIso={nowIso} demo tutors={tutors} save={async () => ({ kind: 'preview' })} />;
}
