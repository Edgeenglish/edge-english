import { readFileSync, existsSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { LEVELS, QUESTIONS } from './data';
import { answerSentence, audioUrl, levelOf, reviewSteps, scoreOf, validPicks, wrongOf } from './logic';

describe('레벨테스트', () => {
  it('20문제, 연습 3개씩', () => {
    expect(QUESTIONS).toHaveLength(20);
    QUESTIONS.forEach((q) => {
      expect(q.d).toHaveLength(3);
      expect(q.e).toHaveLength(2);
      expect(q.a).toBeLessThan(q.o.length);
    });
  });
  it('레벨 기준 0~6 입문·7~12 초급·13~16 중급·17~20 고급 (H26)', () => {
    expect([0, 6, 7, 12, 13, 16, 17, 20].map((n) => levelOf(n).name)).toEqual(['입문', '입문', '초급', '초급', '중급', '중급', '고급', '고급']);
    expect(LEVELS.filter((l) => l.camp).map((l) => l.name)).toEqual(['입문', '초급']);
  });
  it('점수·틀린 문제', () => {
    const all = QUESTIONS.map((q) => q.a);
    expect(scoreOf(all)).toBe(20);
    expect(wrongOf(all)).toEqual([]);
    const one = [...all];
    one[3] = (one[3] + 1) % 4;
    expect(scoreOf(one)).toBe(19);
    expect(wrongOf(one)).toEqual([3]);
    expect(validPicks(all)).toBe(true);
    expect(validPicks([...all.slice(0, 19), 9])).toBe(false);
  });
  it('홍보 카드는 복습 2·4·6번째 뒤', () => {
    const s = reviewSteps([0, 1, 2, 3, 4, 5, 6]);
    expect(s.map((x) => (x.t === 'q' ? 'q' : `p${x.i}`)).join(',')).toBe('q,q,p0,q,q,p1,q,q,p2,q');
  });
  it('정답 듣기 mp3 20개가 시안 음성과 같은 문장', () => {
    const t = readFileSync('docs/homepage/level-test/sian-v1.html', 'utf8');
    const line = t.split('\n').find((l) => l.startsWith('const AUDIO ='))!;
    const keys = Object.keys(JSON.parse(line.slice('const AUDIO = '.length).replace(/;\s*$/, '')));
    QUESTIONS.forEach((_, k) => {
      expect(keys[k]).toBe(answerSentence(k));
      expect(existsSync(`public${audioUrl(k)}`)).toBe(true);
    });
  });
});
