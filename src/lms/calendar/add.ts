// 보강을 각자 캘린더에 더하는 버튼 (2026-10-29 대표: 학생·강사 화면 둘 다, 보강만)
// 구글은 일정 추가 화면 링크, 애플·삼성은 .ics 파일(/lms/ics). 나중에 수업이 바뀌어도 캘린더는 저절로 안 바뀜

export type CalendarEvent = { title: string; start: Date; end: Date; details?: string | null };

/** 20261029T100000Z */
const utc = (d: Date) => d.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');

export function googleCalendarUrl(e: CalendarEvent): string {
  const q = new URLSearchParams({ action: 'TEMPLATE', text: e.title, dates: `${utc(e.start)}/${utc(e.end)}` });
  if (e.details) q.set('details', e.details);
  return `https://calendar.google.com/calendar/render?${q}`;
}

export function icsUrl(e: CalendarEvent): string {
  const q = new URLSearchParams({ t: e.title, s: e.start.toISOString(), e: e.end.toISOString() });
  if (e.details) q.set('d', e.details);
  return `/lms/ics?${q}`;
}

const esc = (s: string) => s.replace(/\\/g, '\\\\').replace(/([,;])/g, '\\$1').replace(/\r?\n/g, '\\n');

/** .ics 파일 내용. 잘못된 값이면 null */
export function icsText(title: string, start: string, end: string, details: string | null, now = new Date()): string | null {
  const s = new Date(start);
  const e = new Date(end);
  if (!title || title.length > 120 || (details ?? '').length > 500 || isNaN(+s) || isNaN(+e) || e <= s || +e - +s > 6 * 3600_000) return null;
  return [
    'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Edge English//LMS//EN', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
    'BEGIN:VEVENT',
    `UID:${utc(s)}-${Math.abs(hash(title + start))}@edgeenglish.kr`,
    `DTSTAMP:${utc(now)}`, `DTSTART:${utc(s)}`, `DTEND:${utc(e)}`,
    `SUMMARY:${esc(title)}`,
    ...(details ? [`DESCRIPTION:${esc(details)}`] : []),
    'END:VEVENT', 'END:VCALENDAR', '',
  ].join('\r\n');
}

function hash(s: string): number {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
  return h;
}
