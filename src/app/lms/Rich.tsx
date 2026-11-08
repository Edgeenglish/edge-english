// 글 속 *기준 이름* 표시를 굵은 글씨로 보여 줌 (time-text.ts: WhatsApp 은 *별표*, 화면은 굵게)
export function Rich({ text }: { text: string }) {
  return (
    <>
      {text.split(/(\*[^*\n]+\*)/).map((p, i) =>
        /^\*[^*\n]+\*$/.test(p) ? <b key={i} className="font-bold" style={{ color: 'inherit' }}>{p.slice(1, -1)}</b> : p,
      )}
    </>
  );
}
