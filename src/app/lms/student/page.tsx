import StudentDemo from './StudentDemo';
import StudentLive from './StudentLive';

// 수강생 화면 (③ 수강생 LMS, migration 2800): 수업 확인 · 직접 취소 · 보강 신청 · 강사 휴무 안내 답하기 (휴대폰 우선)
// ?makeup=수업(또는 보상권)id: 톡으로 보낸 바로가기 — 그 수업 '보강 날짜 고르기'를 바로 엶 (11/8 대표 시안). 수강생 본인 로그인, 또는 운영자(TOTP 완료)가 ?student=수강생id 로 그대로 보기·대신 입력. ?demo=1 은 가상 데이터 미리보기
export const dynamic = 'force-dynamic';

export default async function StudentPage({ searchParams }: { searchParams: Promise<{ demo?: string; student?: string; tz?: string; makeup?: string }> }) {
  const { demo, student, tz, makeup } = await searchParams;
  // ?demo=1&tz=Australia/Sydney: 해외 수강생 시간 표시 확인용 (가상 데이터만)
  if (demo === '1') return <StudentDemo nowIso={new Date().toISOString()} tz={tz} makeup={makeup} />;
  return <StudentLive studentParam={student} makeup={makeup} />;
}
