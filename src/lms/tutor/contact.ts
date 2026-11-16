// 강사 [학생에게 연락하기] (H26(197), 대표 11/16 시안 3판 승인). DB 함수 tutor_contact_student 가 같은 검사를 다시 함
import type { TutorLesson } from './screen';

export const TUTOR_CONTACT = {
  /** 1차: 수업 시작 몇 분 뒤부터 (POL-TU-09) */
  firstAfterMin: 5,
  /** 강사 한마디 최대 글자 수 (대표 11/16) */
  noteMax: 150,
};
export type ContactStage = 1 | 2;
export type ContactSent = { stage: ContactStage; at: Date; byAdmin: boolean };

/** 강사 화면에 보이는 학생 메일 요약 (영어, 실제 메일은 한국어) */
export function contactGist(stage: ContactStage, tutorName: string): string {
  return stage === 1
    ? `"${tutorName} is waiting for you in the class room. Please join now, or let us know on KakaoTalk if you can't make it." + Join class button`
    : `"You can still join the class. ${tutorName} is waiting until the class ends." + Join class button`;
}

type L = Pick<TutorLesson, 'state' | 'startsAt' | 'endsAt' | 'leaveOpen' | 'coveredByOther'>;

/** 지금 누를 수 있는 단계: 1차 = 시작 5분 뒤~끝, 2차 = 1차를 보냈고 수업 절반 뒤~끝. 없으면 null */
export function contactStageOpen(l: L, sent: readonly ContactSent[], now: Date): ContactStage | null {
  if (l.state !== 'scheduled' || l.leaveOpen || l.coveredByOther) return null;
  const t = now.getTime();
  const start = l.startsAt.getTime();
  const end = l.endsAt.getTime();
  if (t >= end) return null;
  const has = (s: ContactStage) => sent.some((x) => x.stage === s);
  if (!has(1)) return t >= start + TUTOR_CONTACT.firstAfterMin * 60_000 ? 1 : null;
  if (!has(2) && t >= start + (end - start) / 2) return 2;
  return null;
}
