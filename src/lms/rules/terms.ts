// 계약 판본 판별·적용 검사 (docs/lms/policy/contract-version-check.md)
// - classifyContract: 계약서 본문에 있는 '조항 문구'만 보고 판본을 판별 (이름·연락처는 읽지도 돌려주지도 않음)
// - assessTerms: 한 사람의 계약 기록(발송·동의·서명)을 보고 지금 적용되는 판본과 확실한 정도를 판정
// - assessStudentDocs: 학생의 등록별 문서(계약서·필독안내서)를 보고 3가지 유형으로 구분 (POL-OP-09~11)
// 판정은 운영자 확인용 참고 자료이며 법률 판단이 아니다.
// 계약서를 받지 않은 학생에게는 계약 판본을 절대 만들어 넣지 않는다 (contractCode = null).

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

// ---------------------------------------------------------------------
// 필독안내서 (계약서가 아님) — POL-OP-09
// ---------------------------------------------------------------------

export type GuideCode = 'G20260709';

export const GUIDES: Record<GuideCode, { label: string; pages: number; firstSeen: KstDate }> = {
  // 이전 판은 파일로 찾지 못함. 이미지에 날짜·판 표시가 없어 Drive 파일 날짜로만 구분
  G20260709: { label: '수업 전 필독안내서 2026-07-09 판 (이미지 2장 세트)', pages: 2, firstSeen: '2026-07-09' },
};

export type GuideRecord = {
  code: GuideCode;
  /** 결제와의 선후. 매칭 중 전달은 결제 후에 해당 */
  timing: 'before_payment' | 'after_payment' | 'at_matching' | 'unknown';
  /** 카카오톡 채널 개별 발송 · 학생 수강현황 시트에 이미지로 게시 */
  exposure: ('kakao' | 'student_sheet')[];
  on?: KstDate;
};

export type EnrollmentDocs = {
  /** 몇 번째 등록인지 (1 = 신규) */
  seq: number;
  contract?: ContractRecord;
  guides?: GuideRecord[];
};

export type DocCategory =
  | 'contract' // 1. 계약서를 전달한 학생 (가장 최근 등록까지 계약서 있음)
  | 'guide_only' // 2. 계약서 없이 안내서만 받은 학생
  | 'contract_then_guide' // 3. 예전 등록에는 계약서, 이후 재등록에는 안내서만
  | 'unknown'; // 문서 기록 없음

export type StudentDocsAssessment = {
  category: DocCategory;
  /** 실제로 전달된 계약서가 있을 때만 값이 있음 */
  contractCode: TermsCode | null;
  contractLevel: TermsAssessment['level'] | null;
  guideCodes: GuideCode[];
  /** 운영자·전문가 확인 항목. '미확인(법률)'은 Claude가 판단하지 않는 항목 */
  flags: string[];
};

// 안내서(G20260709)와 조건이 다르다고 확인된 계약 판본 항목 (guide-2026-07-09-review.md)
const GUIDE_DIFFS: Partial<Record<TermsCode, string[]>> = {
  SC0A: ['정상 변경 기준 12시간↔6시간', '변경권 개수'],
  SC0B: ['변경권 개수 (CF-03)', '기간 길이 30일↔4주 (CF-04)'],
  SC0C: ['변경권 개수 (CF-03)', '기간 길이 30일↔4주 (CF-04)'],
  SC1: ['변경권 개수 (CF-03)', '기간 길이 30일↔4주 (CF-04)', '이월 기한 1주일↔당일 (CF-01)', '장기 연기 (안내서에 없음)'],
  SC2: ['이월 기한 1주일↔당일 (CF-01)', '고정 시간 변경 4주·4일 전↔월 1회', '장기 연기 (안내서에 없음)'],
};

function guideFlags(e: EnrollmentDocs): string[] {
  const flags: string[] = [];
  for (const g of e.guides ?? []) {
    const where = `${e.seq}회차 ${g.code}`;
    if (g.timing === 'after_payment' || g.timing === 'at_matching') {
      flags.push(`${where}: 결제 후 전달 — 이 등록의 수강조건으로 볼 수 있는지 미확인(법률)`);
    } else if (g.timing === 'unknown') {
      flags.push(`${where}: 결제 전후 전달 시점 미상`);
    }
    if (!g.exposure.includes('kakao')) {
      flags.push(`${where}: 개별 발송 기록 없음 (시트 게시만 확인)`);
    }
  }
  return flags;
}

/**
 * 학생 한 명의 등록별 문서를 보고 유형을 구분한다.
 * - 안내서만 받은 등록에 계약 판본을 채우지 않는다.
 * - 예전 계약이 이후 등록에 이어지는지, 안내서가 수강조건이 되는지는 판단하지 않고 '미확인(법률)'로 표시한다.
 */
export function assessStudentDocs(enrollments: EnrollmentDocs[], today: KstDate): StudentDocsAssessment {
  for (const e of enrollments) {
    if (e.contract && TERMS[e.contract.code].audience !== 'student') throw new Error('학생 등록에 강사 계약을 넣을 수 없습니다.');
  }
  const sorted = [...enrollments].sort((a, b) => a.seq - b.seq);
  const withContract = sorted.filter((e) => e.contract);
  const guideCodes = [...new Set(sorted.flatMap((e) => (e.guides ?? []).map((g) => g.code)))];
  const flags = sorted.flatMap(guideFlags);

  if (withContract.length === 0) {
    if (guideCodes.length === 0) {
      return { category: 'unknown', contractCode: null, contractLevel: null, guideCodes, flags: ['계약서·안내서 전달 기록 없음'] };
    }
    flags.unshift('계약서 없음 — 계약 판본을 정하지 않음', '안내서 규정이 수강조건으로 적용되는지·범위 미확인(법률)');
    return { category: 'guide_only', contractCode: null, contractLevel: null, guideCodes, flags };
  }

  const terms = assessTerms(withContract.map((e) => e.contract!), today);
  const lastContractSeq = withContract.at(-1)!.seq;
  const later = sorted.filter((e) => e.seq > lastContractSeq);
  const laterGuideOnly = later.filter((e) => (e.guides ?? []).length > 0);
  const laterNothing = later.filter((e) => (e.guides ?? []).length === 0);

  for (const e of laterNothing) flags.push(`${e.seq}회차: 계약서·안내서 전달 기록 없음`);

  if (laterGuideOnly.length === 0) {
    return { category: 'contract', contractCode: terms.code, contractLevel: terms.level, guideCodes, flags: [...terms.flags, ...flags] };
  }

  const code = terms.code!;
  const clause = TERMS[code].continuation === 'clause9' ? '재등록 효력 조항(9조) 있음' : '재등록 효력 조항 없음';
  flags.unshift(
    `${laterGuideOnly.map((e) => e.seq).join('·')}회차는 안내서만 받음 — ${code} 계약이 이 등록에도 이어지는지 미확인(법률). 사실: ${clause}`,
  );
  const diffs = GUIDE_DIFFS[code];
  if (diffs) flags.push(`${code}와 안내서 조건이 다른 항목: ${diffs.join(', ')}`);
  return { category: 'contract_then_guide', contractCode: code, contractLevel: terms.level, guideCodes, flags: [...flags, ...terms.flags] };
}
