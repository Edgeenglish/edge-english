// 로그인돼 있으면 로그인 화면을 거치지 않고 바로 갈 '내 수업' 주소 (11/17 대표: 로그인 화면 → '이동하는 중' → 홈 두 번 거치는 것 없앰)
// 역할별로 바로 (대표 11/17 '1번'): 학생 → 학생 홈, 강사 → 강사 홈, 운영자 → 인증 앱 확인을 끝낸 상태면 운영자 화면, 아니면 로그인 화면(6자리)
// 실제 권한은 각 화면·DB 함수가 다시 확인한다 (세션이 풀려 있으면 학생 화면이 로그인 화면으로 보냄).

import type { SupabaseClient } from '@supabase/supabase-js';

export const LOGIN_PATH = '/lms/login';

/** 이 기기에 로그인 세션이 있으면 역할별 홈, 없거나 바로 갈 곳이 없으면 null */
export async function myLmsHome(sb: SupabaseClient): Promise<string | null> {
  const { data } = await sb.auth.getSession();
  if (!data.session) return null;
  const [{ data: role }, { data: aal }] = await Promise.all([sb.rpc('my_role'), sb.auth.mfa.getAuthenticatorAssuranceLevel()]);
  return homeForRole(role, aal?.currentLevel === 'aal2');
}

export function homeForRole(role: unknown, adminVerified = false): string | null {
  if (role === 'student') return '/lms/student';
  if (role === 'tutor') return '/lms/tutor';
  if (role === 'admin' && adminVerified) return '/lms/admin';
  return null;
}
