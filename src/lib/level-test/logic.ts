import { LEVELS, QUESTIONS, type Level } from './data';

/** 빈칸(___)에 고른 답을 넣은 문장. 'A / B' 답은 빈칸 순서대로 */
export function fill(s: string, opt: string): string {
  const p = opt.split(' / ');
  let k = 0;
  return s.replace(/___/g, () => p[Math.min(k++, p.length - 1)]);
}

/** 정답 문장(따옴표 뺌) — 듣기 mp3 와 짝 */
export const answerSentence = (k: number) => fill(QUESTIONS[k].q, QUESTIONS[k].o[QUESTIONS[k].a]).replace(/"/g, '');
export const audioUrl = (k: number) => `/level-test/q${String(k + 1).padStart(2, '0')}.mp3`;

export const scoreOf = (picks: (number | null)[]) => QUESTIONS.reduce((n, q, k) => n + (picks[k] === q.a ? 1 : 0), 0);

export function levelOf(score: number): Level {
  let L = LEVELS[0];
  for (const l of LEVELS) if (score >= l.min) L = l;
  return L;
}

export const wrongOf = (picks: (number | null)[]) => QUESTIONS.map((_, k) => k).filter((k) => picks[k] !== QUESTIONS[k].a);

export function validPicks(v: unknown): v is number[] {
  return Array.isArray(v) && v.length === QUESTIONS.length && v.every((x, k) => Number.isInteger(x) && x >= 0 && x < QUESTIONS[k].o.length);
}

/** 복습 순서: 틀린 문제 1개씩, 2·4·6번째 뒤에 홍보 카드 0·1·2 */
export type Step = { t: 'q'; k: number } | { t: 'p'; i: number };
export function reviewSteps(wrong: number[]): Step[] {
  const at: Record<number, number> = { 1: 0, 3: 1, 5: 2 };
  const out: Step[] = [];
  wrong.forEach((k, idx) => {
    out.push({ t: 'q', k });
    if (idx in at) out.push({ t: 'p', i: at[idx] });
  });
  return out;
}

/** 문제마다 응원 문구 (시안 그대로) */
export function cheer(done: number, total: number): string {
  const rem = total - done;
  if (done === 0) return `틀린 문제 ${total}개, 하나씩 같이 봐요. 지금 배워 두면 다시는 안 틀려요!`;
  if (rem === 1) return '마지막 문제예요! 이것만 보면 끝나요.';
  if (rem <= 2) return `이제 딱 ${rem}개만 더 보면 돼요! 거의 다 왔어요.`;
  const L = [
    '복습 안 하면 다음에 같은 문제를 또 틀릴 수 있어요. 조금만 더 힘내요!',
    '귀찮아도 지금 한 번 보면 오래 기억에 남아요.',
    `벌써 ${done}개 끝냈어요. 이 기세로 가 봐요!`,
    '소리 내어 따라 읽으면 입에 더 잘 붙어요.',
  ];
  return L[(done - 1) % L.length];
}
export const PROMO_CHEER = ['잠깐! 이런 선생님들과 수업해요', '잠깐! 수업에서는 이런 노트를 매번 적어 드려요', '잠깐! 선생님은 이렇게 골라요'];
