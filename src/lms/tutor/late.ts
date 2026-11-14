// 강사 '늦어요' 알림 (대표 11/13 범위·설계, 11/14 문구 확정). DB 함수 tutor_late_notice 가 같은 검사를 다시 함
import type { TutorLesson } from './screen';

export const TUTOR_LATE = {
  /** 수업 시작 몇 시간 전부터 버튼이 보이는지 (시작하면 사라짐) */
  openHoursBefore: 2,
  /** 값 20 = '20분 이상' */
  minutes: [5, 10, 15, 20] as const,
  reasons: [
    { code: 'internet', label: 'Internet problem', ko: '인터넷 연결에 문제가 생겼어요' },
    { code: 'power', label: 'Power outage', ko: '정전이 됐어요' },
    { code: 'device', label: 'Computer or device issue', ko: '컴퓨터·장비에 문제가 생겼어요' },
    { code: 'personal', label: 'Personal emergency', ko: '갑자기 급한 일이 생겼어요' },
    { code: 'previous', label: 'Previous appointment ran late', ko: '앞 일정이 늦게 끝났어요' },
  ] as const,
  /** ? 안내 (대표 11/14 확정) */
  help: "Please let your student know as early as possible, at least 10 minutes before class starts, so they aren't left waiting. This button is available from 2 hours before class until it starts. This notice doesn't excuse the delay: you'll still extend the class by the time you're late, and it counts as a late start.",
};
export type TutorLateMinutes = (typeof TUTOR_LATE.minutes)[number];
export type TutorLateReason = (typeof TUTOR_LATE.reasons)[number]['code'];
export type TutorLateNotice = { minutes: number; reason: TutorLateReason | null; at: Date };

export const tutorLateChip = (m: number) => (m >= 20 ? '20+ min' : `${m} min`);
/** 보낸 뒤 회색 버튼: 'Sent ✓ · about 10 min late' / 'Sent ✓ · 20+ min late' */
export const tutorLateSent = (m: number) => `Sent ✓ · ${m >= 20 ? '20+ min late' : `about ${m} min late`}`;
export const tutorLateReasonEn = (code: string | null) => TUTOR_LATE.reasons.find((r) => r.code === code)?.label ?? null;
export const tutorLateReasonKo = (code: string | null) => TUTOR_LATE.reasons.find((r) => r.code === code)?.ko ?? null;
/** 학생 홈 '다음 수업' 카드 노란 띠 (대표 11/14 확정) */
export const tutorLateBand = (m: number, reason: string | null) =>
  `⚠️ 강사님이 ${m >= 20 ? '20분 이상' : `약 ${m}분`} 늦을 예정이에요${tutorLateReasonKo(reason) ? ` · ${tutorLateReasonKo(reason)}` : ''}`;

/** 버튼을 누를 수 있는 때: 예정 수업, 시작 2시간 전 ~ 시작 전, 휴무 처리 중·다른 강사 대체 아님 */
export function tutorLateOpen(l: Pick<TutorLesson, 'state' | 'startsAt' | 'leaveOpen' | 'coveredByOther'>, now: Date): boolean {
  if (l.state !== 'scheduled' || l.leaveOpen || l.coveredByOther) return false;
  const start = l.startsAt.getTime();
  return now.getTime() >= start - TUTOR_LATE.openHoursBefore * 3_600_000 && now.getTime() < start;
}
