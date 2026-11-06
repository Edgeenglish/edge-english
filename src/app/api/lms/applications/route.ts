import { createClient } from '@supabase/supabase-js';
import { applicationFromGoogle, type GoogleApplication } from '@/lms/admin/form-applications';

export const dynamic = 'force-dynamic';
const headers = { 'Cache-Control': 'private, no-store', Vary: 'Authorization' };

export async function POST(request: Request) {
  const token = request.headers.get('Authorization')?.match(/^Bearer (.+)$/)?.[1];
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!token) return Response.json({ error: '로그인이 필요합니다.' }, { status: 401, headers });
  if (!url || !key) return Response.json({ error: 'LMS 연결 설정을 확인해 주세요.' }, { status: 503, headers });
  const sb = createClient(url, key, { global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false, autoRefreshToken: false } });
  const { data: admin, error } = await sb.rpc('is_admin');
  if (error || admin !== true) return Response.json({ error: '운영자 인증이 필요합니다.' }, { status: 403, headers });
  const feed = process.env.LMS_FORM_RESPONSES_URL;
  if (!feed || !/^https:\/\/script\.google\.com\/(?:a\/macros\/edgeenglish\.kr\/s|macros\/s)\/[A-Za-z0-9_-]+\/exec$/.test(feed)) {
    return Response.json({ error: '구글폼 연결 설정이 아직 완료되지 않았습니다. 직접 입력은 가능합니다.' }, { status: 503, headers });
  }
  try {
    const upstream = await fetch(feed, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ supabaseUrl: url, anonKey: key, accessToken: token }),
      cache: 'no-store', signal: AbortSignal.timeout(60_000),
    });
    const payload = await upstream.json();
    if (!upstream.ok || !Array.isArray(payload.applications)) throw new Error('Form read failed');
    const applications = (payload.applications as GoogleApplication[]).map(applicationFromGoogle)
      .sort((a, b) => b.submittedAt.localeCompare(a.submittedAt));
    return Response.json({ applications }, { headers });
  } catch {
    return Response.json({ error: '구글폼 응답을 불러오지 못했습니다. 잠시 후 다시 열어 주세요. 직접 입력은 가능합니다.' }, { status: 502, headers });
  }
}
