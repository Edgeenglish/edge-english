import { NextResponse, type NextRequest } from 'next/server';

// LMS 주소 이전 (정책 원본 H26(108)): 옛 주소(Vercel lms-prod)에 LMS_MOVED_TO=https://edgeenglish.kr 를 넣으면
// /lms 아래 모든 주소를 같은 경로·물음표 뒤(?makeup=, ?next=)까지 그대로 새 주소로 넘긴다.
// 값이 없으면(지금·새 주소 자체) 아무것도 안 함. 되돌리기: 환경변수를 지우고 다시 배포. 307 = 브라우저가 영구 기억하지 않음
// www.edgeenglish.kr/lms 는 edgeenglish.kr/lms 로 (로그인은 주소마다 따로 저장 → 한 주소로 모음, 홈페이지는 그대로)
export function lmsMovedTarget(url: URL, movedTo: string | undefined): URL | null {
  if (url.host === 'www.edgeenglish.kr') return new URL(url.pathname + url.search, 'https://edgeenglish.kr');
  if (!movedTo) return null;
  let target: URL;
  try {
    target = new URL(url.pathname + url.search, movedTo);
  } catch {
    return null;
  }
  if (target.protocol !== 'https:' || target.host === url.host) return null;
  return target;
}

export function proxy(request: NextRequest) {
  const target = lmsMovedTarget(request.nextUrl, process.env.LMS_MOVED_TO);
  return target ? NextResponse.redirect(target, 307) : NextResponse.next();
}

export const config = { matcher: ['/lms', '/lms/:path*'] };
