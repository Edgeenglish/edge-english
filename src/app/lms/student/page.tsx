import StudentHome from './StudentHome';

// 학생 마이페이지 (3차 시안 A-1 최종, 2026-10-17 대표 확정 — docs/lms/07-decisions.md D-34·D-35)
// 지금은 가상 데이터 미리보기. 학생 로그인·실제 데이터 연결은 시험용 Supabase 검증(5-4) 후
export const dynamic = 'force-dynamic';

export default function StudentPage() {
  return <StudentHome nowIso={new Date().toISOString()} preview />;
}
