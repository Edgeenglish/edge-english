import DemoOnly from '../DemoOnly';
import StudentList from './StudentList';

// 학생 찾기 · 목록 (이름·번호·강사로 검색, 누르면 학생 한 명 정보)
export const dynamic = 'force-dynamic';

export default async function StudentsPage({ searchParams }: { searchParams: Promise<{ demo?: string; q?: string }> }) {
  const { demo, q } = await searchParams;
  if (demo !== '1') return <DemoOnly href="/lms/admin/students" title="학생" />;
  return <StudentList nowIso={new Date().toISOString()} initialQuery={q ?? ''} />;
}
