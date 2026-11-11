import { describe, expect, it } from 'vitest';
import { flattenNaver } from './naver';

describe('네이버 회원 정보 펴기 (H26(150))', () => {
  it('response 안의 id·name → sub·name, 이메일은 로그인 이메일로 넘기지 않음(naver_email)', () => {
    expect(flattenNaver({ resultcode: '00', response: { id: 'abc', email: 'a@naver.com', name: '김하준' } })).toEqual({ sub: 'abc', name: '김하준', naver_email: 'a@naver.com' });
    expect(flattenNaver({ resultcode: '00', response: { id: 'abc' } })).toEqual({ sub: 'abc' });
    expect(flattenNaver({ resultcode: '00', response: { id: 'abc', email: 'a@naver.com' } })).not.toHaveProperty('email');
  });
  it('실패 응답·아이디 없음은 거절', () => {
    expect(flattenNaver({ resultcode: '024', message: 'Authentication failed' })).toBeNull();
    expect(flattenNaver({ resultcode: '00', response: {} })).toBeNull();
  });
});
