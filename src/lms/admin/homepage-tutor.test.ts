import { describe, expect, it } from 'vitest';
import { homepageProfile } from './homepage-tutor';

describe('홈페이지 강사 소개 찾기', () => {
  it('괄호 앞 영문 이름으로 찾음 (대소문자 무시)', () => {
    expect(homepageProfile('grace')?.name).toBe('Grace(그레이스)');
  });
  it('홈페이지에 없으면 null (가짜 소개를 만들지 않음)', () => {
    expect(homepageProfile('Alex')).toBeNull();
  });
});
