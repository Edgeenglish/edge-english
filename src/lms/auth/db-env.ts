// 지금 화면이 어느 DB에 연결됐는지 (화면 맨 위 표시용, 2026-10-22 대표 확정 문구)
// 운영 프로젝트 주소일 때만 '운영'. 주소가 없으면 표시 안 함(로컬 가상 데이터)

export const PROD_SUPABASE_REF = 'mfamixejxydodclhglbc';

export type DbEnv = 'prod' | 'test' | null;

export function dbEnv(url: string | undefined): DbEnv {
  if (!url) return null;
  let host: string;
  try {
    host = new URL(url).hostname;
  } catch {
    return 'test';
  }
  return host === `${PROD_SUPABASE_REF}.supabase.co` ? 'prod' : 'test';
}

export const DB_ENV_LABEL = {
  prod: { title: '운영 DB · 실제 데이터', note: '실제 학생 등록·수업 일정이 저장되는 환경' },
  test: { title: '시험용 DB · 가상 데이터', note: '기능 테스트 전용 환경' },
} as const;
