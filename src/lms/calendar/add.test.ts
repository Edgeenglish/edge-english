import { describe, expect, it } from 'vitest';
import { googleCalendarUrl, icsText, icsUrl } from './add';

const ev = { title: 'Edge English make-up', start: new Date('2026-11-02T10:00:00Z'), end: new Date('2026-11-02T10:40:00Z'), details: 'https://meet.google.com/abc' };

describe('보강 캘린더 버튼', () => {
  it('구글 링크는 UTC 시각', () => {
    const u = new URL(googleCalendarUrl(ev));
    expect(u.searchParams.get('dates')).toBe('20261102T100000Z/20261102T104000Z');
    expect(u.searchParams.get('details')).toBe('https://meet.google.com/abc');
  });
  it('.ics 내용', () => {
    const q = new URL(icsUrl(ev), 'https://x').searchParams;
    const t = icsText(q.get('t')!, q.get('s')!, q.get('e')!, q.get('d'), new Date('2026-10-29T00:00:00Z'))!;
    expect(t).toContain('DTSTART:20261102T100000Z\r\nDTEND:20261102T104000Z');
    expect(t).toContain('SUMMARY:Edge English make-up');
  });
  it('잘못된 값은 거절', () => {
    expect(icsText('x', 'bad', '2026-11-02T10:40:00Z', null)).toBeNull();
    expect(icsText('x', '2026-11-02T10:40:00Z', '2026-11-02T10:00:00Z', null)).toBeNull();
    expect(icsText('a, b; c', '2026-11-02T10:00:00Z', '2026-11-02T10:40:00Z', null)).toContain('SUMMARY:a\\, b\\; c');
  });
});
