// 학생 본인 화면 자료 미리 불러 두기 (11/17 대표: [내 수업] 눌렀을 때 '불러오는 중'도 안 보이게)
// 홈페이지 머리글이 학생 로그인을 확인하면 미리 불러 두고, 학생 화면은 이것을 바로 보여 준 뒤 새로 불러 바꿈.
// 이 브라우저 탭 안에서만 (새로고침·로그아웃하면 사라짐). 실제 권한은 DB 함수가 다시 확인한다.

import type { SupabaseClient } from '@supabase/supabase-js';
import { loadStudentBundle, type StudentBundle } from './live';

type Entry = { userId: string; view?: StudentBundle; pending?: Promise<StudentBundle> };
let entry: Entry | null = null;

/** 학생 로그인을 확인한 뒤 부름. 이미 불러 두었거나 불러오는 중이면 다시 안 부름 */
export function prefetchOwnView(sb: SupabaseClient, userId: string): void {
  if (entry?.userId === userId && (entry.view || entry.pending)) return;
  const pending = loadStudentBundle(sb, null);
  entry = { userId, pending };
  pending.then(
    (view) => { if (entry?.pending === pending) entry = { userId, view }; },
    () => { if (entry?.pending === pending) entry = null; },
  );
}

/** 미리 불러 둔 자료 (사용자 확인 전 첫 화면용) */
export const ownViewCache = (): Entry | null => entry;

export function rememberOwnView(userId: string, view: StudentBundle): void {
  entry = { userId, view };
}

export function forgetOwnView(): void {
  entry = null;
}
