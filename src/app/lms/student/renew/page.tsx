import StudentLive from '../StudentLive';

// 재등록 신청 (재등록 안내 메일 링크, 대표 11/21): 수강생 홈 위에 재등록 신청 창을 바로 엶. 로그인 안 했으면 로그인 뒤 이 주소로 돌아옴.
// 운영자(TOTP 완료)는 ?student=수강생id 로 그대로 보기·대신 입력
export const dynamic = 'force-dynamic';

export default async function StudentRenewPage({ searchParams }: { searchParams: Promise<{ student?: string }> }) {
  const { student } = await searchParams;
  return <StudentLive studentParam={student} renew />;
}
