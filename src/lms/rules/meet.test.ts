import { describe, expect, it } from 'vitest';
import { isMeetRoomUrl, meetRoomUrl } from './meet';

describe('Google Meet 회의실 주소 (R-05)', () => {
  it('회의실 코드(xxx-xxxx-xxx)·lookup 주소만 유효', () => {
    expect(isMeetRoomUrl('https://meet.google.com/abc-defg-hij')).toBe(true);
    expect(isMeetRoomUrl('https://meet.google.com/ABC-DEFG-HIJ?authuser=0')).toBe(true);
    expect(isMeetRoomUrl('https://meet.google.com/lookup/abc123')).toBe(true);
  });
  it('홈페이지 주소·빈 값·다른 사이트는 회의실이 아님', () => {
    for (const u of ['https://meet.google.com/', 'https://meet.google.com', '', null, undefined, 'https://workspace.google.com/products/meet/', 'https://meet.google.com/abc', 'http://meet.google.com/abc-defg-hij'])
      expect(isMeetRoomUrl(u)).toBe(false);
  });
  it('meetRoomUrl 은 유효하면 주소, 아니면 null', () => {
    expect(meetRoomUrl(' https://meet.google.com/abc-defg-hij ')).toBe('https://meet.google.com/abc-defg-hij');
    expect(meetRoomUrl('https://meet.google.com/')).toBeNull();
  });
});
