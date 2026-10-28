import StudentDemo from './StudentDemo';
import StudentLive from './StudentLive';

// 학생 화면 (③ 학생 LMS, migration 2800): 수업 확인 · 직접 취소 · 보강 신청 · 강사 휴무 안내 답하기 (휴대폰 우선)
// 학생 본인 로그인, 또는 운영자(TOTP 완료)가 ?student=학생id 로 그대로 보기·대신 입력. ?demo=1 은 가상 데이터 미리보기
export const dynamic = 'force-dynamic';

export default async function StudentPage({ searchParams }: { searchParams: Promise<{ demo?: string; student?: string }> }) {
  const { demo, student } = await searchParams;
  if (demo === '1') return <StudentDemo nowIso={new Date().toISOString()} />;
  return <StudentLive studentParam={student} />;
}
