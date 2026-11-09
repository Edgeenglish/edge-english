'use client';

// 운영자 화면 공통: 로그인·추가 인증(aal2)·운영자 확인 뒤 Supabase 를 돌려줌. 아니면 로그인 화면으로
import { useEffect, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';
import { supabaseBrowser } from '@/lms/auth/client';

export function useAdminSb(): { sb: SupabaseClient | null; error: string | null } {
  const [ready, setReady] = useState<SupabaseClient | null>(null);
  const [error, setError] = useState<string | null>(null);
  const sb = supabaseBrowser();
  useEffect(() => {
    if (!sb) return setError('Supabase 설정이 없어요 (환경 변수).');
    (async () => {
      const { data: session } = await sb.auth.getSession();
      if (!session.session) return window.location.replace('/lms/login');
      const [{ data: aal }, { data: admin }] = await Promise.all([sb.auth.mfa.getAuthenticatorAssuranceLevel(), sb.rpc('is_admin')]);
      if (aal?.currentLevel !== 'aal2' || admin !== true) return window.location.replace('/lms/login');
      setReady(sb);
    })();
  }, [sb]);
  return { sb: ready, error };
}
