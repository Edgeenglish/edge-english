// 보강 캘린더 파일 (애플·삼성 캘린더용). DB는 읽지 않고 받은 값으로만 만듦
import { icsText } from '@/lms/calendar/add';

export function GET(req: Request) {
  if (process.env.LMS_PREVIEW !== '1') return new Response('Not found', { status: 404 });
  const q = new URL(req.url).searchParams;
  const body = icsText(q.get('t') ?? '', q.get('s') ?? '', q.get('e') ?? '', q.get('d'));
  if (!body) return new Response('Bad request', { status: 400 });
  return new Response(body, {
    headers: {
      'Content-Type': 'text/calendar; charset=utf-8',
      'Content-Disposition': 'attachment; filename="edge-english-make-up.ics"',
      'Cache-Control': 'no-store',
    },
  });
}
