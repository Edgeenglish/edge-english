import { describe, expect, it } from 'vitest';
import { cleanCode, docParagraphs, parseSignDoc, parseSignList } from './esign';
import { dueLine } from '../../app/lms/tutor/SignDoc';

describe('전자서명 (H26(188))', () => {
  it('전문 문단: 첫 문단 제목, 1. … 조 제목', () => {
    const p = docParagraphs('Addendum: X\n\nIntro text.\n\n1. Purpose\nBody line.\n\n2. Use\nMore.');
    expect(p[0]).toEqual({ heading: 'Addendum: X', lines: [], title: true });
    expect(p[1]).toEqual({ heading: null, lines: ['Intro text.'], title: false });
    expect(p[2]).toEqual({ heading: '1. Purpose', lines: ['Body line.'], title: false });
  });
  it('코드는 숫자 6자리만', () => {
    expect(cleanCode(' 12-34 56 7')).toBe('123456');
  });
  it('목록·문서 읽기', () => {
    const l = parseSignList({ open: [{ request_id: 'r', title: 'T', revision: 1, due_at: '2026-11-23T03:00:00Z' }], signed: [] });
    expect(l.open[0].dueAt.toISOString()).toBe('2026-11-23T03:00:00.000Z');
    const d = parseSignDoc({ request_id: 'r', title: 'T', revision: 2, body: 'B', statement: 'S', company_signed_at: '2026-11-15T14:00:00Z', document_sha256: 'h', due_at: '2026-11-23T03:00:00Z', signed: null, code: { sent_to: 'a@b', expires_at: '2026-11-16T00:10:00Z' } });
    expect(d.code?.sentTo).toBe('a@b');
    expect(d.signed).toBeNull();
  });
  it('기한 줄: 강사 현지 날짜, 지나면 late', () => {
    const due = new Date('2026-11-22T17:00:00Z');   // Manila 11/23 01:00
    expect(dueLine(due, 'Asia/Manila', new Date('2026-11-20T00:00:00Z'))).toEqual({ text: 'Please sign by Mon, 23 Nov', late: false });
    expect(dueLine(due, 'Asia/Manila', new Date('2026-11-23T00:00:00Z')).late).toBe(true);
  });
});
