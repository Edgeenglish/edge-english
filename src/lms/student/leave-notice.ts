// 학생 '담당 강사님 휴무 안내' 화면의 사과 문구와 대체강사 추천 문구 (대표 11/23)
// 휴무 기간이 11월~1월과 겹치면 연말연초 문구, 아니면 일반 문구 — 운영진 설정 없이 날짜로 자동 선택

export const LEAVE_SORRY_GENERAL = '담당 강사님의 휴무로 해당 기간에는 기존 일정대로 수업을 진행하기 어렵습니다. 불편을 드려 죄송합니다. 🙇';
export const LEAVE_SORRY_YEAR_END = '연말연초 담당 강사님의 휴무로 해당 기간에는 기존 일정대로 수업을 진행하기 어렵습니다. 불편을 드려 죄송합니다. 🙇';

/** 연말연초로 보는 달 (11월·12월·1월) */
export const YEAR_END_MONTHS = [11, 12, 1];

function monthIn(d: Date, tz: string): number {
  const m = new Intl.DateTimeFormat('en-US', { timeZone: tz, month: 'numeric' }).formatToParts(d).find((p) => p.type === 'month')?.value;
  return Number(m);
}

/** 휴무 [from, to) 가 11월~1월과 하루라도 겹치는가 (학생 시간대 날짜 기준) */
export function isYearEndLeave(from: Date, to: Date, tz: string): boolean {
  const end = to.getTime() - 1;
  if (!(from.getTime() <= end)) return YEAR_END_MONTHS.includes(monthIn(from, tz));
  const step = 6 * 3600 * 1000;
  let guard = 0;
  for (let t = from.getTime(); t <= end && guard < 3000; t += step, guard += 1) {
    if (YEAR_END_MONTHS.includes(monthIn(new Date(t), tz))) return true;
  }
  return YEAR_END_MONTHS.includes(monthIn(new Date(end), tz));
}

export function leaveSorryText(from: Date, to: Date, tz: string): string {
  return isYearEndLeave(from, to, tz) ? LEAVE_SORRY_YEAR_END : LEAVE_SORRY_GENERAL;
}

/** 대체강사 추천 상자 글 (답변이 필요한 수업이 있을 때만) */
export function leaveRecommendLines(subTutors: string[]): { title: string; lines: string[]; small: string } {
  const names = [...new Set(subTutors.filter(Boolean))];
  return {
    title: '⭐ 추천 · 원래 시간에 대체강사님과 수업해 보세요!',
    lines: [
      '평소 일정은 그대로 유지하면서 새로운 강사님의 영어와 수업 스타일도 경험해 보실 수 있어요.',
      `인기 강사님 중 한 분인 ${names.join(', ')} 선생님이 기존 수업 시간에 가능하세요.`,
      '실제로 대체강사님과 수업한 뒤 만족하셔서 담당 강사를 변경하신 학생분도 계세요.',
    ],
    small: '(학생마다 잘 맞는 수업 스타일이 다르니, 강사 변경도 언제든 환영이에요! 💗)',
  };
}

/** 답변 버튼 글 (n = 답변이 필요한 수업 수) */
export const leaveButtonOk = (n: number) => `대체강사님과 ${n}회 수업할게요`;
export const leaveButtonWait = (n: number) => `기존 강사님과 ${n}회 보강할게요`;
