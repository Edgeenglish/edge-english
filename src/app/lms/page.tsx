import { redirect } from 'next/navigation';

// edgeenglish.kr/lms (정책 원본 H26(108)): 로그인 화면으로. 이미 로그인돼 있으면 로그인 화면이 권한별 홈으로 바로 넘김.
// 물음표 뒤(?next= 등)는 그대로 넘긴다.
export default async function LmsIndex({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(await searchParams)) for (const x of [v].flat()) if (x !== undefined) q.append(k, x);
  const s = q.toString();
  redirect(s ? `/lms/login?${s}` : '/lms/login');
}
