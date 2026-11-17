'use client';

import { useRouter } from 'next/navigation';
import { useEffect } from 'react';
import { supabaseBrowser } from '@/lms/auth/client';
import { LOGIN_PATH, myLmsHome } from '@/lms/auth/home';

/** /lms: 세션은 이 기기 브라우저에만 있어 서버가 모름 → 브라우저에서 확인해 바로 넘김 (화면은 비워 둠) */
export default function LmsIndexGo() {
  const router = useRouter();
  useEffect(() => {
    const sb = supabaseBrowser();
    const go = (to: string | null) => router.replace(to ?? LOGIN_PATH);
    if (!sb) return go(null);
    myLmsHome(sb).then(go, () => go(null));
  }, [router]);
  return null;
}
