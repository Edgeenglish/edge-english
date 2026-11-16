'use client';

// 브라우저용 Supabase 연결 (공개 키만 사용 — 서버 비밀키는 절대 여기 두지 않음)
// 세션은 이 기기 브라우저에 저장되어 로그아웃하거나 만료될 때까지 유지 (D-29)

import { createClient, type SupabaseClient } from '@supabase/supabase-js';

let client: SupabaseClient | null = null;

export function supabaseBrowser(): SupabaseClient | null {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) return null;
  client ??= createClient(url, key, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false } });
  return client;
}
