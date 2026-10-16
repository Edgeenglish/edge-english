// 계약 판본 판별·적용 검사 (docs/lms/policy/contract-version-check.md)
// - classifyContract: 계약서 본문에 있는 '조항 문구'만 보고 판본을 판별 (이름·연락처는 읽지도 돌려주지도 않음)
// - assessTerms: 한 사람의 계약 기록(발송·동의·서명)을 보고 지금 적용되는 판본과 확실한 정도를 판정
// 판정은 운영자 확인용 참고 자료이며 법률 판단이 아니다.

import { addDays, diffDays, type KstDate } from './dates';

export type TermsCode =
  | 'SC0A' | 'SC0B' | 'SC0C' | 'SC1' | 'SC2' | 'SC3'
  | 'TC0' | 'TC0B' | 'TC1' | 'TC2' | 'TC3';

type TermsMeta = {
  audience: 'student' | 'tutor';
  label: string;
  /** 재등록·기간 만료 후에도 효력이 이어지는 근거 */
  continuation: 'clause9' | 'none_stated' | 'auto_renew' | 'written_consent' | 'fixed_term';
  /** 계약 기간(강사, 일). 없으면 기간 제한 없음 */
  termDays?: number;
};

export const TERMS: Record<TermsCode, TermsMeta> = {
  SC0A: { audience: 'student', label: '학생 계약 2024-09 이전 판 (12시간 기준)', continuation: 'none_stated' },
  SC0B: { audience: 'student', label: '학생 계약 2024-11 판 (6시간·30일, 효력 조항 없음)', continuation: 'none_stated' },
  SC0C: { audience: 'student', label: '학생 계약 2025-05 판 (30일, 효력 조항 있음)', continuation: 'clause9' },
  SC1: { audience: 'student', label: '학생 계약 1판 2025-10~12 (30일)', continuation: 'clause9' },
  SC2: { audience: 'student', label: '학생 계약 2판 2026-01~ (28일)', continuation: 'clause9' },
  SC3: { audience: 'student', label: '학생 계약 3판 초안 2026-10', continuation: 'clause9' },
  TC0: { audience: 'tutor', label: '강사 계약 2024-08 국내판 (원화 시급)', continuation: 'fixed_term' },
  TC0B: { audience: 'tutor', label: '강사 계약 2025-11-04 판 ($14 + 최대 $2, 자동 갱신)', continuation: 'auto_renew', termDays: 365 },
  TC1: { audience: 'tutor', label: '강사 계약 1판 2025-11-27 ($14 + 최대 $3, 갱신은 서면 동의)', continuation: 'written_consent', termDays: 365 },
  TC2: { audience: 'tutor', label: '강사 계약 2판 2026-01 ($11, 최대 $17)', continuation: 'auto_renew', termDays: 365 },
  TC3: { audience: 'tutor', label: '강사 계약 3판 2026-08 ($11, 최대 $17)', continuation: 'auto_renew', termDays: 365 },
};

// 판본마다 고유한 조항 문구. 공백을 모두 지운 뒤 비교 (PDF 추출 시 줄바꿈·띄어쓰기가 달라져도 판별되게)
// 위에서부터 차례로 검사 — 더 새로운 판을 먼저 확인
const FINGERPRINTS: { code: TermsCode; all: string[]; none?: string[] }[] = [
  { code: 'SC3', all: ['6개월등록시만'] },
  { code: 'SC2', all: ['한달(28일)'] },
  { code: 'SC1', all: ['한달(30일)', '30일(수강권기준)내1회'] },
  { code: 'SC0C', all: ['한달(30일)', '계약서의유효기간'] },
  { code: 'SC0B', all: ['한달(30일)'], none: ['계약서의유효기간'] },
  { code: 'SC0A', all: ['12시간이전까지'] },
  { code: 'TC3', all: ['inadditiontothemake-upclass'] },
  { code: 'TC2', all: ['USD11', 'compensationclass'] },
  { code: 'TC1', all: ['$14perhour', 'upto$3'] },
  { code: 'TC0B', all: ['$14perhour', 'upto$2'] },
  { code: 'TC0', all: ['시급31,000'] },
];

const squash = (text: string) => text.replace(/\s+/g, '');

/** 계약서 본문 → 판본 (모르면 null). 결과에는 판별에 쓴 조항 문구만 들어감 */
export function classifyContract(text: string): { code: TermsCode | null; matched: string[] } {
  const t = squash(text);
  for (const fp of FINGERPRINTS) {
    if (fp.all.every((m) => t.includes(m)) && !(fp.none ?? []).some((m) => t.includes(m))) {
      return { code: fp.code, matched: fp.all };
    }
  }
  return { code: null, matched: [] };
}

// ---------------------------------------------------------------------
// 한 사람에게 지금 적용되는 판본 판정
// ---------------------------------------------------------------------

export type ContractRecord = {
  code: TermsCode;
  /** 계약서 문서에 적힌 날짜 또는 파일 작성일 */
  documentDate: KstDate;
  /** 학생·강사에게 실제로 보냈다는 기록 (카톡·메일·전자서명 발송) */
  delivered?: { on: KstDate; proof: 'kakao' | 'email' | 'esign' | 'in_person' };
  /** 동의 기록: 학생은 '발송 후 결제', 강사는 서명 */
  consent?: { on: KstDate; kind: 'payment_after_delivery' | 'signature' | 'esign_completed' };
};

export type TermsAssessment = {
  code: TermsCode | null;
  level: 'confirmed' | 'presumed' | 'unknown';
  flags: string[];
};

function consentIsValid(r: ContractRecord): boolean {
  if (!r.consent) return false;
  if (r.consent.kind === 'payment_after_delivery') {
    // 결제로 동의한 것으로 보려면 결제가 계약서를 받은 뒤여야 함
    return !!r.delivered && diffDays(r.delivered.on, r.consent.on) >= 0;
  }
  return true; // 서명·전자서명 완료는 그 자체가 동의
}

/**
 * - confirmed: 발송·동의(또는 서명) 기록까지 있음
 * - presumed: 계약서 파일만 있고 발송·동의 기록은 없음
 * - unknown: 기록 없음
 * flags: 운영자가 따로 확인해야 할 점 (법률 판단 아님)
 */
export function assessTerms(records: ContractRecord[], today: KstDate): TermsAssessment {
  if (records.length === 0) return { code: null, level: 'unknown', flags: ['계약서 기록 없음'] };
  const audiences = new Set(records.map((r) => TERMS[r.code].audience));
  if (audiences.size > 1) throw new Error('학생 계약과 강사 계약을 한 사람 기록에 섞을 수 없습니다.');

  const byDate = (a: ContractRecord, b: ContractRecord) => diffDays(b.documentDate, a.documentDate);
  const sorted = [...records].sort(byDate);
  const confirmed = sorted.filter(consentIsValid);
  const flags: string[] = [];

  const chosen = confirmed.at(-1) ?? sorted.at(-1)!;
  const level: TermsAssessment['level'] = confirmed.length > 0 ? 'confirmed' : 'presumed';

  // 더 새 판본을 보냈지만 동의가 확인되지 않음 → 이전 판본이 계속 적용될 수 있음
  for (const r of sorted) {
    if (diffDays(chosen.documentDate, r.documentDate) > 0 && !consentIsValid(r)) {
      flags.push(`${r.code}: 더 새 판본 기록이 있지만 발송 후 동의(결제·서명)가 확인되지 않음`);
    }
  }
  for (const r of sorted) {
    if (r.consent?.kind === 'payment_after_delivery' && !consentIsValid(r)) {
      flags.push(`${r.code}: 결제일이 계약서 발송일보다 앞서거나 발송 기록이 없음`);
    }
  }

  const meta = TERMS[chosen.code];
  if (meta.continuation === 'none_stated') {
    flags.push(`${chosen.code}: 계약서에 재등록 시 효력 조항이 없음 — 재등록 때 적용 판본 확인 필요`);
  }
  if (meta.continuation === 'fixed_term') {
    flags.push(`${chosen.code}: 기간이 정해진 계약 — 만료 후 연장 합의 여부 확인 필요`);
  }
  if (meta.termDays && meta.continuation === 'written_consent') {
    const start = chosen.consent?.on ?? chosen.documentDate;
    if (diffDays(addDays(start, meta.termDays), today) > 0) {
      flags.push(`${chosen.code}: 계약 기간(1년)이 지났고 이 판본은 서면 동의로만 갱신됨 — 갱신 서면 확인 필요`);
    }
  }
  if (level === 'presumed') flags.push('계약서 파일만 있고 발송·동의 기록 없음');

  return { code: chosen.code, level, flags };
}
