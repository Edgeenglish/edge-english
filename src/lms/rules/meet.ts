// Google Meet 회의실 주소 검사 (R-05): https://meet.google.com/xxx-xxxx-xxx (또는 /lookup/…) 만 '수업 링크'.
// 홈페이지 주소(https://meet.google.com/)·빈 값은 회의실이 아니라 수강생에게 링크로 내보내지 않음. DB 의 lms_meet_url_ok 와 같은 규칙
const ROOM = /^https:\/\/meet\.google\.com\/([a-z0-9]{3}-[a-z0-9]{4}-[a-z0-9]{3}|lookup\/[A-Za-z0-9_-]+)(\?.*)?$/i;

export function isMeetRoomUrl(url: string | null | undefined): boolean {
  return !!url && ROOM.test(url.trim());
}

/** 회의실 주소면 그대로, 아니면 null (화면은 null 이면 '링크 없음' 안내) */
export const meetRoomUrl = (url: string | null | undefined): string | null => (isMeetRoomUrl(url) ? url!.trim() : null);

/** 수강생에게 보이는 안내 (링크가 회의실 주소가 아닐 때) */
export const MEET_MISSING_KO = '수업 링크는 수업 전에 카카오톡으로 보내 드려요.';
