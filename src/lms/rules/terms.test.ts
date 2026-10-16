// 계약 판본 판별·적용 검사 테스트 — 실제 계약서가 아닌 짧은 가짜 문구만 사용
import { describe, expect, it } from 'vitest';
import { assessTerms, classifyContract } from './terms';

describe('계약서 조항 문구로 판본 판별', () => {
  const cases: [string, string | null][] = [
    ['한 달(28일) 수업 동안 수업 변경 가능 횟수 … ◆장기 연기(6개월등록시만 가능!!!)', 'SC3'],
    ['• 한 달(28일) 수업 동안 수업 취소 가능 횟수는 아래와 같습니다', 'SC2'],
    ['한 달(30일) 수업 동안 … 고정 시간 변경은 30일(수강권 기준) 내 1회 가능', 'SC1'],
    ['한 달(30일) 수업 동안 … 9. 계약서의 유효기간 …', 'SC0C'],
    ['한 달(30일)\n수업 동안 … 25분 수업 …', 'SC0B'],
    ['수업 시작 12시간 이전까지 취소한다면', 'SC0A'],
    ['provide one (1) additional compensation class, in addition to the make-up class, to the affected student', 'TC3'],
    ['The base pay is USD11 per hour … one (1) additional compensation class', 'TC2'],
    ['The base pay is $14 per hour, and Party A may provide additional incentives (up to $3 per hour)', 'TC1'],
    ['The base pay is $14 per hour, and Party A may provide additional incentives (up to $2 per hour)', 'TC0B'],
    ['보수로서 시급 31,000(세전)원을 기준으로 지급한다', 'TC0'],
    ['아무 판본 문구도 없는 문서', null],
  ];
  for (const [text, code] of cases) {
    it(`${code ?? '판별 불가'}`, () => expect(classifyContract(text).code).toBe(code));
  }

  it('줄바꿈·띄어쓰기가 달라도 판별 (PDF 추출 대비)', () => {
    expect(classifyContract('한\n달(30\n일) … 30일 (수강권 기준) 내 1 회').code).toBe('SC1');
  });

  it('결과에는 판별에 쓴 조항 문구만 있고 본문(이름·연락처)은 없음', () => {
    const r = classifyContract('성명: 가나다 연락처: 010-0000-0000 한 달(28일)');
    expect(JSON.stringify(r)).not.toContain('가나다');
    expect(JSON.stringify(r)).not.toContain('010');
  });
});

describe('지금 적용되는 판본 판정 (서명·발송·동의 구분)', () => {
  const today = '2026-10-16';

  it('파일만 있으면 "추정"', () => {
    const r = assessTerms([{ code: 'SC1', documentDate: '2025-11-28' }], today);
    expect(r).toMatchObject({ code: 'SC1', level: 'presumed' });
  });

  it('발송 후 결제가 있으면 "확인됨"', () => {
    const r = assessTerms(
      [{ code: 'SC2', documentDate: '2026-01-14', delivered: { on: '2026-01-14', proof: 'kakao' }, consent: { on: '2026-01-15', kind: 'payment_after_delivery' } }],
      today,
    );
    expect(r).toMatchObject({ code: 'SC2', level: 'confirmed' });
  });

  it('결제가 계약서 발송보다 먼저면 동의로 보지 않음', () => {
    const r = assessTerms(
      [{ code: 'SC2', documentDate: '2026-01-14', delivered: { on: '2026-01-20', proof: 'kakao' }, consent: { on: '2026-01-15', kind: 'payment_after_delivery' } }],
      today,
    );
    expect(r.level).toBe('presumed');
    expect(r.flags.join()).toContain('결제일이 계약서 발송일보다 앞서');
  });

  it('새 판본 파일이 있어도 동의 기록이 없으면 이전 판본을 유지하고 경고', () => {
    const r = assessTerms(
      [
        { code: 'SC1', documentDate: '2025-11-28', delivered: { on: '2025-11-28', proof: 'kakao' }, consent: { on: '2025-11-29', kind: 'payment_after_delivery' } },
        { code: 'SC2', documentDate: '2026-02-01' },
      ],
      today,
    );
    expect(r).toMatchObject({ code: 'SC1', level: 'confirmed' });
    expect(r.flags.join()).toContain('SC2: 더 새 판본 기록이 있지만');
  });

  it('효력 조항이 없는 옛 판본(2024-11)은 재등록 시 확인 필요 표시', () => {
    const r = assessTerms([{ code: 'SC0B', documentDate: '2024-11-16' }], today);
    expect(r.flags.join()).toContain('재등록 시 효력 조항이 없음');
  });

  it('강사 1판(서면 동의로만 갱신)은 1년이 지나면 갱신 확인 필요', () => {
    const r = assessTerms([{ code: 'TC1', documentDate: '2025-11-27', consent: { on: '2025-11-27', kind: 'signature' } }], '2026-12-01');
    expect(r.code).toBe('TC1');
    expect(r.flags.join()).toContain('갱신 서면 확인 필요');
  });

  it('강사 1판도 1년 안이면 경고 없음', () => {
    const r = assessTerms([{ code: 'TC1', documentDate: '2025-11-27', consent: { on: '2025-11-27', kind: 'signature' } }], today);
    expect(r.flags).toEqual([]);
  });

  it('기록이 없으면 "미확인"', () => {
    expect(assessTerms([], today)).toMatchObject({ code: null, level: 'unknown' });
  });

  it('학생 계약과 강사 계약을 섞으면 오류', () => {
    expect(() => assessTerms([{ code: 'SC2', documentDate: '2026-01-01' }, { code: 'TC2', documentDate: '2026-01-01' }], today)).toThrow();
  });
});
