import { DB_ENV_LABEL, dbEnv } from '@/lms/auth/db-env';

// 운영 DB 표시는 운영진에게만 (2026-11-17 대표: 학생·강사에게 보이면 안 됨, 운영진은 보여야 함)
// 운영자 화면 머리글에서만 쓴다(운영자 보기 막대의 빨간 표시는 11/17 대표 요청으로 뺌). src/components 에 둬야 Tailwind 가 bg-red-600 을 만든다(src/lms 는 Tailwind content 밖 — 11/17 운영 화면 띠 색이 빠진 원인). 시험 사이트는 lms/layout 의 회색 띠가 모두에게 보임
const isProd = () => dbEnv(process.env.NEXT_PUBLIC_SUPABASE_URL) === 'prod';

/** 운영자 화면 맨 위 빨간 띠 */
export function ProdBand() {
  if (!isProd()) return null;
  return (
    <div className="bg-red-600 px-4 py-2 text-center text-white">
      <p className="text-sm font-bold text-white">{DB_ENV_LABEL.prod.title}</p>
      <p className="text-xs text-white/90">{DB_ENV_LABEL.prod.note}</p>
    </div>
  );
}
