'use client';

// ⑤ 시트 Student Info 이전 (H26(44) ⑤, B안): 강사 Class Record 시트의 'Student Info' 줄을 복사해 붙여 넣으면
// 시트 값과 LMS 값을 나란히 보여 주고, 대표가 칸마다 확인해 고른 것만 LMS에 넣는다. 시트 원본은 읽기만(이 화면은 시트에 아무것도 쓰지 않음).
// 자기소개는 원문 그대로 self_intro_en 에(7개로 나누지 않음). 레벨(A2/B1 등)은 4단계로 바꾸지 않고 level_note(참고)에.
import { useMemo, useState } from 'react';
import type { StudentProfile } from '@/lms/admin/students';
import { btnMain, btnSub, input, label, Sheet } from './parts';

type Mapped = { field: string; title: string; sheet: string };

/** 시트 머리글(강사마다 조금 다름) → LMS 칸 */
const HEADERS: { match: RegExp; field: string; title: string }[] = [
  { match: /^preferred name/i, field: 'display_name', title: 'Preferred Name' },
  { match: /^place of residence/i, field: 'residence', title: '거주지 (국가·도시)' },
  { match: /self introduct/i, field: 'self_intro_en', title: '기존 자기소개 (원문 그대로)' },
  { match: /^gender/i, field: 'gender_age', title: '성별 / 연령대' },
  { match: /^e-?mail/i, field: 'email', title: '이메일' },
  { match: /^level$/i, field: 'level_note', title: '예전 레벨 표기 (참고)' },
  { match: /^type of class/i, field: 'class_type', title: 'Type of class' },
  { match: /^correction/i, field: 'correction_pref', title: '교정 선호 (시트 글)' },
  { match: /^google docs/i, field: 'class_note_url', title: 'Google Docs 링크' },
];

export function parseSheetRows(text: string): { headers: string[]; rows: string[][] } {
  // 탭으로 나뉜 표. 셀 안 줄바꿈은 시트 복사 때 따옴표로 묶여 옴
  const out: string[][] = [];
  let row: string[] = [];
  let cell = '';
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') { cell += '"'; i++; }
      else if (ch === '"') quoted = false;
      else cell += ch;
    } else if (ch === '"' && cell === '') quoted = true;
    else if (ch === '\t') { row.push(cell); cell = ''; }
    else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && text[i + 1] === '\n') i++;
      row.push(cell); cell = '';
      if (row.some((c) => c.trim())) out.push(row);
      row = [];
    } else cell += ch;
  }
  row.push(cell);
  if (row.some((c) => c.trim())) out.push(row);
  if (out.length === 0) return { headers: [], rows: [] };
  const first = out[0].map((h) => h.trim());
  const hasHeader = first.some((h) => /student name|preferred name|place of residence|e-?mail/i.test(h));
  return hasHeader ? { headers: first, rows: out.slice(1) } : { headers: [], rows: out };
}

/** 'Melbourne, Australia' → 도시 Melbourne · 국가 Australia / 'Korea' → 국가만 */
export function splitResidence(v: string): { country: string | null; city: string | null } {
  const t = v.trim();
  if (!t) return { country: null, city: null };
  const parts = t.split(',').map((x) => x.trim()).filter(Boolean);
  if (parts.length >= 2) return { city: parts[0], country: parts.slice(1).join(', ') };
  return { country: t, city: null };
}

export function mapRow(headers: string[], row: string[]): { name: string; items: Mapped[] } {
  const items: Mapped[] = [];
  let name = '';
  headers.forEach((h, i) => {
    const v = (row[i] ?? '').trim();
    if (/^student name/i.test(h)) name = v;
    const m = HEADERS.find((x) => x.match.test(h));
    if (m && v) items.push({ field: m.field, title: m.title, sheet: v });
  });
  return { name, items };
}

const lmsValue = (s: StudentProfile, field: string): string => {
  switch (field) {
    case 'display_name': return s.displayName ?? '';
    case 'residence': return [s.city, s.country].filter(Boolean).join(', ');
    case 'self_intro_en': return s.selfIntroEn ?? '';
    case 'gender_age': return s.genderAge ?? '';
    case 'email': return s.email ?? '';
    case 'level_note': return s.levelNote ?? '';
    case 'class_type': return s.classType ?? '';
    case 'correction_pref': return s.correctionPref ?? '';
    case 'class_note_url': return s.classNoteUrl ?? '';
    default: return '';
  }
};

export default function SheetImport({ student, save, onClose }: { student: StudentProfile; save: (fields: Record<string, string | null>) => Promise<void>; onClose: () => void }) {
  const [text, setText] = useState('');
  const [pick, setPick] = useState<Record<string, boolean>>({});
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const parsed = useMemo(() => parseSheetRows(text), [text]);
  const rows = useMemo(() => parsed.rows.map((r) => mapRow(parsed.headers, r)), [parsed]);
  // 여러 줄을 붙여 넣었으면 이 학생 이름(한국 이름·영문)과 맞는 줄을 고름
  const mine = rows.find((r) => r.name && (r.name.includes(student.nameKo ?? '\u0000') || r.name.toLowerCase().includes(student.nameEn.toLowerCase()))) ?? (rows.length === 1 ? rows[0] : null);
  const items = mine?.items ?? [];
  const diff = items.map((it) => ({ ...it, lms: lmsValue(student, it.field), same: lmsValue(student, it.field).trim() === it.sheet.trim() }));
  const chosen = diff.filter((d) => !d.same && (pick[d.field] ?? d.lms === ''));   // LMS 가 비어 있으면 기본 선택, 값이 있으면 덮어쓰지 않음(직접 골라야)

  async function onSave() {
    const fields: Record<string, string | null> = {};
    for (const d of chosen) {
      if (d.field === 'residence') {
        const r = splitResidence(d.sheet);
        fields.country = r.country;
        fields.city = r.city;
      } else if (d.field === 'class_note_url' && !/^https?:\/\//.test(d.sheet)) {
        continue;   // 시트의 'Google docs link' 가 문서 이름(예: 김은아_Benny)이면 주소가 아니라 넣지 않음
      } else fields[d.field] = d.sheet;
    }
    if (Object.keys(fields).length === 0) return;
    setBusy(true);
    setErr('');
    try {
      await save(fields);
      onClose();
    } catch (x) {
      setErr(x instanceof Error ? x.message : '저장하지 못했어요.');
      setBusy(false);
    }
  }

  return (
    <Sheet title="시트 Student Info 에서 가져오기" onClose={onClose} wide>
      <p className="mb-2 text-[13px] text-[#6b6880]">
        강사 Class Record 시트의 <b>Student Info</b> 탭에서 머리글 줄과 이 학생 줄을 복사해 아래에 붙여 넣으세요 (시트는 읽기만, 여기서 시트를 고치지 않아요).
        시트 값과 LMS 값을 나란히 보여 드리고, 체크한 칸만 LMS에 넣어요. LMS에 이미 값이 있는 칸은 기본으로 체크하지 않아요(덮어쓰기 방지).
      </p>
      <label htmlFor="imp-text" className={label}>붙여 넣기</label>
      <textarea id="imp-text" value={text} onChange={(e) => setText(e.target.value)} rows={4} className={`${input} font-mono text-[13px]`} placeholder="Enrollment	Enrolled Classes	…	Student Name	Preferred Name	…" />
      {text && !mine && <p className="mt-2 text-[13.5px] text-[#b3261e]">이 학생({student.nameKo} · {student.nameEn})과 맞는 줄을 찾지 못했어요. 머리글 줄과 학생 줄을 같이 복사했는지 확인해 주세요.</p>}
      {mine && (
        <div className="mt-3 overflow-hidden rounded-[12px] border border-[#e6e3ef] bg-white">
          <div className="grid grid-cols-[auto_1fr_1fr] gap-2 border-b border-[#e6e3ef] bg-[#f7f6fb] px-3 py-2 text-[12.5px] font-bold text-[#6b6880]">
            <span className="w-[72px]">넣기</span><span>시트 값 ({mine.name || '이름 없음'})</span><span>LMS 지금 값</span>
          </div>
          {diff.map((d) => {
            const on = !d.same && (pick[d.field] ?? d.lms === '');
            return (
              <label key={d.field} className={`grid grid-cols-[auto_1fr_1fr] gap-2 border-b border-[#f0eef6] px-3 py-2 text-[13px] last:border-0 ${d.same ? 'text-[#6b6880]' : 'text-[#1d1b2b]'}`}>
                <span className="w-[72px]">
                  {d.same ? <span className="text-[12px]">같음</span> : (
                    <input type="checkbox" checked={on} onChange={(e) => setPick({ ...pick, [d.field]: e.target.checked })} className="h-[18px] w-[18px] accent-[#5b3fe0]" />
                  )}
                  <span className="block text-[11.5px] font-semibold text-[#6b6880]">{d.title}</span>
                </span>
                <span className="whitespace-pre-wrap break-words">{d.sheet}</span>
                <span className="whitespace-pre-wrap break-words">{d.lms || <i className="text-[#b9b6c8]">비어 있음</i>}</span>
              </label>
            );
          })}
        </div>
      )}
      {err && <p className="mt-3 rounded-[10px] bg-[#fdecea] px-3 py-2 text-[14px] text-[#b3261e]">{err}</p>}
      <div className="mt-4 flex gap-2">
        <button type="button" className={btnSub} onClick={onClose} disabled={busy}>닫기</button>
        <button type="button" className={`${btnMain} flex-1`} disabled={chosen.length === 0 || busy} onClick={onSave}>{busy ? '저장 중…' : `체크한 ${chosen.length}칸 LMS에 넣기`}</button>
      </div>
    </Sheet>
  );
}
