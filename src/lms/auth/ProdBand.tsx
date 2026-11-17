import { DB_ENV_LABEL, dbEnv } from './db-env';

// 운영 DB 표시는 운영진에게만 (2026-11-17 대표: 학생·강사에게 보이면 안 됨, 운영진은 보여야 함)
// 운영자 화면 머리글·운영자 보기 막대에서만 쓴다. 시험 사이트는 lms/layout 의 회색 띠가 모두에게 보임
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

/** 운영자 보기 막대 안 작은 표시 */
export function ProdChip() {
  if (!isProd()) return null;
  return <span className="rounded-[6px] bg-red-600 px-2 py-1 text-[12px] font-bold text-white">{DB_ENV_LABEL.prod.title}</span>;
}
