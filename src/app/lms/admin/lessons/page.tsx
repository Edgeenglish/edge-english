import LessonList from './LessonList';

// 기간별 수업 목록 (대시보드 5차 시안): 오늘 · 내일 · 이번 주 · 다음 주 · 기간 선택. 한국 시간
export const dynamic = 'force-dynamic';

export default function LessonsPage() {
  return <LessonList />;
}
