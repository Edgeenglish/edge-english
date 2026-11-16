// 네이버 로그인 (H26(150)): Supabase 직접 연결(custom:naver)은 네이버 회원 정보가 응답의 'response' 안에 들어 있어
// 이메일·아이디를 읽지 못한다(11/12 로컬 시험: 'Error getting user email from external provider', attribute_mapping 경로도 안 됨).
// 그래서 Supabase 의 userinfo 주소를 우리 사이트 /api/auth/naver-userinfo 로 두고, 여기서 네이버 응답을 펴서 돌려준다.
// 네이버 이메일은 인증됐는지 Supabase 가 알 수 없다 → 로그인 이메일(email)로 넘기지 않는다 (H26(150) 미인증 = 자동 연결 금지).
//   · email 로 넘기면: 같은 이메일 기존 계정이 있으면 Supabase 가 거절, 없으면 '이메일 확인 필요'로 새 회원도 로그인 못 함 (11/12 로컬 시험)
//   · 그래서 email 없이(Supabase 'email_optional') 넘기고, 네이버 이메일은 naver_email 로만 남긴다(회원 정보 참고용)
//   → 네이버 첫 로그인은 항상 '처음이에요 / 이미 회원이에요', 이미 회원이면 기존 계정으로 로그인한 뒤 연결

export type NaverMe = { resultcode?: string; message?: string; response?: { id?: string; email?: string; name?: string; nickname?: string } };
export type FlatUser = { sub: string; name?: string; naver_email?: string };

export function flattenNaver(me: NaverMe): FlatUser | null {
  const r = me?.response;
  if (me?.resultcode !== '00' || !r?.id) return null;
  return { sub: r.id, ...(r.name || r.nickname ? { name: r.name || r.nickname } : {}), ...(r.email ? { naver_email: r.email } : {}) };
}
