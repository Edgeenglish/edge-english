import DemoOnly from '../../DemoOnly';
import StudentDetail from './StudentDetail';

// 학생 한 명 정보 (운영자 전용 — 학생 화면과 달리 결제 금액·운영 메모도 보임)
export const dynamic = 'force-dynamic';

export default async function StudentPage({ params, searchParams }: { params: Promise<{ code: string }>; searchParams: Promise<{ demo?: string }> }) {
  const [{ code }, { demo }] = await Promise.all([params, searchParams]);
  if (demo !== '1') return <DemoOnly href={`/lms/admin/students/${code}`} title="학생 정보" />;
  return <StudentDetail code={code} nowIso={new Date().toISOString()} />;
}
