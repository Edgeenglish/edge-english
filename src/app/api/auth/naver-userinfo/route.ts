import { flattenNaver } from '@/lms/auth/naver';

// Supabase(네이버 직접 연결)가 사용자 정보를 물을 때 부르는 주소. 받은 네이버 토큰으로 네이버에 그대로 묻고 펴서 돌려준다.
// 비밀 값은 없음 — 토큰은 Supabase 가 방금 네이버에서 받은 사용자 본인 것. 아무것도 저장하지 않는다.
const NAVER_ME = process.env.NAVER_USERINFO_URL || 'https://openapi.naver.com/v1/nid/me';

export async function GET(req: Request) {
  const auth = req.headers.get('authorization');
  if (!auth?.toLowerCase().startsWith('bearer ')) return Response.json({ error: 'missing token' }, { status: 401 });
  let me: unknown;
  try {
    const r = await fetch(NAVER_ME, { headers: { authorization: auth }, cache: 'no-store' });
    if (!r.ok) return Response.json({ error: 'naver error' }, { status: 502 });
    me = await r.json();
  } catch {
    return Response.json({ error: 'naver unreachable' }, { status: 502 });
  }
  const user = flattenNaver(me as Parameters<typeof flattenNaver>[0]);
  return user ? Response.json(user) : Response.json({ error: 'no user' }, { status: 502 });
}
