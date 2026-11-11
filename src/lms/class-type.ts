// 수업 종류 이름 (H26(138), 2026-11-11 대표): 판정은 DB class_type(lessons) 하나, 화면은 이름만 붙임
// 강사 화면 = 강사 시트 Class Type 영어 그대로, 운영진·학생 화면 = 한국어

export type ClassType = 'regular' | 'makeup' | 'compensation' | 'cover' | 'carry_in' | 'carry_out';

export const CLASS_TYPE_EN: Record<ClassType, string> = {
  regular: 'Regular',
  makeup: 'Makeup',
  compensation: 'Compensation',
  cover: 'Cover class',
  carry_in: 'Carryover from previous period',
  carry_out: 'Carryover to next period',
};

export const CLASS_TYPE_KO: Record<ClassType, string> = {
  regular: '정규',
  makeup: '보강',
  compensation: '무료 보상수업',
  cover: '대체',
  carry_in: '지난 수강기간에서 이월된 수업',
  carry_out: '다음 수강기간으로 이월되는 수업',
};

/** DB 가 type 을 아직 안 주는 옛 응답·미리보기용: lessons.kind 만으로 가장 가까운 종류 */
export function typeFromKind(kind: string | null | undefined, cover = false): ClassType {
  if (cover) return 'cover';
  if (kind === 'makeup' || kind === 'migrated_makeup') return 'makeup';
  if (kind === 'compensation') return 'compensation';
  if (kind === 'carryover') return 'carry_in';
  return 'regular';
}

export const asClassType = (v: unknown, kind?: string | null, cover = false): ClassType =>
  typeof v === 'string' && v in CLASS_TYPE_EN ? (v as ClassType) : typeFromKind(kind, cover);

/** 한국어 이름 + '수업' (문장 속: '정규 수업'·'무료 보상수업'·'지난 수강기간에서 이월된 수업') */
export const typeKoLong = (type: unknown, kind?: string | null, cover = false): string => {
  const t = typeKo(type, kind, cover);
  return t.endsWith('수업') ? t : `${t} 수업`;
};

/** 한국어 이름 (kind 만 있을 때도) */
export const typeKo = (type: unknown, kind?: string | null, cover = false): string => CLASS_TYPE_KO[asClassType(type, kind, cover)];
