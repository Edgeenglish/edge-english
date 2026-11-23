import { describe, expect, it } from 'vitest';
import { lmsMovedTarget } from './proxy';

const OLD = 'https://edge-english-git-lms-prod-support-2126.vercel.app';

describe('LMS 주소 이전 넘김 (H26(108))', () => {
  it('환경변수 없으면 다른 주소는 넘기지 않음', () => {
    const TEST = 'https://edge-english-git-lms-test-support-2126.vercel.app';
    expect(lmsMovedTarget(new URL(`${TEST}/lms/student`), undefined)).toBeNull();
    expect(lmsMovedTarget(new URL(`${TEST}/lms/student`), '')).toBeNull();
  });
  it('옛 운영 주소는 환경변수 없이도 edgeenglish.kr 로 (11/17)', () => {
    expect(lmsMovedTarget(new URL(`${OLD}/lms/student?makeup=abc`), undefined)?.href).toBe('https://edgeenglish.kr/lms/student?makeup=abc');
    expect(lmsMovedTarget(new URL(`${OLD}/lms/login`), '')?.href).toBe('https://edgeenglish.kr/lms/login');
  });
  it('같은 경로·물음표 뒤까지 그대로', () => {
    expect(lmsMovedTarget(new URL(`${OLD}/lms/student?makeup=abc`), 'https://edgeenglish.kr')?.href).toBe('https://edgeenglish.kr/lms/student?makeup=abc');
    expect(lmsMovedTarget(new URL(`${OLD}/lms/login?next=%2Flms%2Fstudent%3Fmakeup%3Dabc`), 'https://edgeenglish.kr')?.href)
      .toBe('https://edgeenglish.kr/lms/login?next=%2Flms%2Fstudent%3Fmakeup%3Dabc');
    expect(lmsMovedTarget(new URL(`${OLD}/lms`), 'https://edgeenglish.kr')?.href).toBe('https://edgeenglish.kr/lms');
  });
  it('www 는 환경변수 없이도 edgeenglish.kr 로', () => {
    expect(lmsMovedTarget(new URL('https://www.edgeenglish.kr/lms/student?makeup=abc'), undefined)?.href).toBe('https://edgeenglish.kr/lms/student?makeup=abc');
    expect(lmsMovedTarget(new URL('https://edgeenglish.kr/lms'), undefined)).toBeNull();
  });
  it('새 주소 자체·잘못된 값·https 아님은 넘기지 않음(무한 반복 방지)', () => {
    expect(lmsMovedTarget(new URL('https://edgeenglish.kr/lms/student'), 'https://edgeenglish.kr')).toBeNull();
    const TEST = 'https://edge-english-git-lms-test-support-2126.vercel.app';
    expect(lmsMovedTarget(new URL(`${TEST}/lms`), 'not a url')).toBeNull();
    expect(lmsMovedTarget(new URL(`${TEST}/lms`), 'http://edgeenglish.kr')).toBeNull();
  });
});
