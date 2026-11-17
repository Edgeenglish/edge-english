// 로그인돼 있으면 로그인 화면을 거치지 않고 바로 갈 '내 수업' 주소 (11/17 대표: 로그인 화면 → '이동하는 중' → 홈 두 번 거치는 것 없앰)
// 학생만 바로 감. 강사·운영자는 대표 결정 전까지 지금처럼 로그인 화면이 넘김(null).
// 실제 권한은 각 화면·DB 함수가 다시 확인한다 (세션이 풀려 있으면 학생 화면이 로그인 화면으로 보냄).

import type { SupabaseClient } from '@supabase/supabase-js';

export const LOGIN_PATH = '/lms/login';

/** 이 기기에 로그인 세션이 있으면 역할별 홈, 없거나 바로 갈 곳이 없으면 null */
export async function myLmsHome(sb: SupabaseClient): Promise<string | null> {
  const { data } = await sb.auth.getSession();
  if (!data.session) return null;
  const { data: role } = await sb.rpc('my_role');
  return homeForRole(role);
}

export function homeForRole(role: unknown): string | null {
  if (role === 'student') return '/lms/student';
  return null;
}
