// 시각 칸에 숫자로 바로 치기 (2026-10-26 대표: 스크롤로만 고르기 불편) — '1730'·'17:30'·'930'·'오후 5:30'·'5pm' → 'HH:MM'
// 못 읽으면 null (화면은 친 글자를 그대로 두고 값은 비움)

export function parseTimeText(raw: string): string | null {
  let t = raw.trim().toLowerCase().replace(/\s+/g, '');
  if (!t) return null;
  let pm: boolean | null = null;
  if (/^(오후|pm)|(오후|pm)$/.test(t)) pm = true;
  else if (/^(오전|am)|(오전|am)$/.test(t)) pm = false;
  t = t.replace(/오후|오전|pm|am/g, '').replace(/시$/, '').replace(/시/, ':').replace(/분$/, '');
  let h: number;
  let m: number;
  const colon = /^(\d{1,2})[:.](\d{1,2})$/.exec(t);
  if (colon) {
    h = Number(colon[1]);
    m = Number(colon[2]);
  } else if (/^\d{1,4}$/.test(t)) {
    if (t.length <= 2) {
      h = Number(t);
      m = 0;
    } else {
      h = Number(t.slice(0, t.length - 2));
      m = Number(t.slice(-2));
    }
  } else return null;
  if (pm === true && h < 12) h += 12;
  if (pm === false && h === 12) h = 0;
  if (h > 23 || m > 59) return null;
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
}
