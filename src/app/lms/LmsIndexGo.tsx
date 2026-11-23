'use client';

import { useRouter } from 'next/navigation';
import { useEffect, useState } from 'react';
import { supabaseBrowser } from '@/lms/auth/client';
import { LOGIN_PATH, myLmsHome } from '@/lms/auth/home';
import { ownViewCache, prefetchOwnView } from '@/lms/student/prefetch';
import { StudentHomeSkeleton } from './student/StudentHome';

/** /lms (메일 링크): 세션은 이 기기 브라우저에만 있어 서버가 모름 → 브라우저에서 확인해 넘김.
 *  학생이면 학생 홈 빈 틀을 보여 주며 자료를 다 받은 뒤 한 번에 넘김 (11/17 대표: 화면이 여러 번 바뀌지 않게) */
export default function LmsIndexGo() {
  const router = useRouter();
  const [student, setStudent] = useState(false);
  useEffect(() => {
    const sb = supabaseBrowser();
    if (!sb) return router.replace(LOGIN_PATH);
    (async () => {
      const { data } = await sb.auth.getSession();
      const uid = data.session?.user.id;
      if (!uid) return router.replace(LOGIN_PATH);
      prefetchOwnView(sb, uid);
      const to = await myLmsHome(sb);
      if (to !== '/lms/student') return router.replace(to ?? LOGIN_PATH);
      setStudent(true);
      await ownViewCache()?.pending?.catch(() => undefined);
      router.replace(to);
    })().catch(() => router.replace(LOGIN_PATH));
  }, [router]);
  return student ? <StudentHomeSkeleton /> : <div className="min-h-[60vh]" />;
}
