import { redirect } from 'next/navigation';
import LmsIndexGo from './LmsIndexGo';

// edgeenglish.kr/lms (정책 원본 H26(108), 메일 링크): 로그인돼 있는 학생은 학생 홈으로 바로, 그 밖은 로그인 화면으로 (11/17 대표: 로그인 화면을 거쳐 두 번 보이는 것 없앰)
// 물음표 뒤(?next= 등)가 있으면 지금처럼 로그인 화면으로 그대로 넘긴다.
export default async function LmsIndex({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(await searchParams)) for (const x of [v].flat()) if (x !== undefined) q.append(k, x);
  const s = q.toString();
  if (s) redirect(`/lms/login?${s}`);
  return <LmsIndexGo />;
}
