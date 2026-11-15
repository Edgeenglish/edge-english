'use client';

// 강사 서명 문서 (H26(188), 시안 4번, 대표 11/15)
//  - 문서마다 판: 초안(고치기) → [회사 서명하고 올리기] (대표 계정·시각 = 회사 서명, 올린 뒤 전문 수정 불가)
//  - 올린 판: 강사별 서명 현황(서명 시각·거주 국가·서명본 메일) · [PDF] · 서명 요청 보낼 강사 추가 · 새 판 만들기
//  - 새 문서 (신규 강사·본계약 등)
import Link from 'next/link';
import { useCallback, useEffect, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';
import { AdminHeader, BottomNav } from '../ui';
import { useAdminSb } from '../useAdmin';
import { formatInZone } from '@/lms/rules/dates';
import { downloadPdf } from '@/lms/tutor/esign';
import { loadTutorAccounts, type TutorAccount } from '@/lms/tutor/live';

const box = 'min-w-0 rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-3';
const btn = 'inline-flex min-h-[40px] items-center rounded-[10px] bg-[#7d5ffb] px-3 text-[13.5px] font-semibold text-white disabled:opacity-40';
const btnLine = 'inline-flex min-h-[40px] items-center rounded-[10px] border border-[#7d5ffb] px-3 text-[13.5px] font-semibold text-[#5b3fe0] disabled:opacity-40';
const field = 'w-full rounded-[10px] border border-[#d9d5e6] px-3 py-2 text-[16px] lg:text-[14px]';

type Req = { requestId: string; tutorId: string; tutor: string; requestedAt: Date; dueAt: Date; signatureId: string | null; signedAt: Date | null; country: string | null; mailStatus: string | null; mailError: string | null };
type Doc = { id: string; title: string; revision: number; status: 'draft' | 'published' | 'retired'; body: string; statement: string; publishedAt: Date | null; requests: Req[] };

const WD = ['일', '월', '화', '수', '목', '금', '토'];
/** '11/16(월) 오후 7:12 한국 시간' */
function kst(d: Date): string {
  const f = formatInZone(d, 'Asia/Seoul');
  const [h, m] = f.time.split(':').map(Number);
  return `${Number(f.date.slice(5, 7))}/${Number(f.date.slice(8))}(${WD[new Date(`${f.date}T00:00:00Z`).getUTCDay()]}) ${h < 12 ? '오전' : '오후'} ${h % 12 || 12}:${String(m).padStart(2, '0')} 한국 시간`;
}

function parseDocs(rows: Record<string, unknown>[]): Doc[] {
  return rows.map((d) => ({
    id: String(d.id), title: String(d.title), revision: Number(d.revision), status: d.status as Doc['status'],
    body: String(d.body ?? ''), statement: String(d.statement ?? ''), publishedAt: d.published_at ? new Date(String(d.published_at)) : null,
    requests: ((d.requests ?? []) as Record<string, unknown>[]).map((r) => ({
      requestId: String(r.request_id), tutorId: String(r.tutor_id), tutor: String(r.tutor), requestedAt: new Date(String(r.requested_at)), dueAt: new Date(String(r.due_at)),
      signatureId: (r.signature_id as string | null) ?? null, signedAt: r.signed_at ? new Date(String(r.signed_at)) : null, country: (r.country as string | null) ?? null,
      mailStatus: (r.mail_status as string | null) ?? null, mailError: (r.mail_error as string | null) ?? null,
    })),
  }));
}

const MAIL: Record<string, string> = { queued: '보내는 중', sent: '보냄', failed: '못 보냄', canceled: '취소' };

export default function SignAdmin() {
  const { sb, error } = useAdminSb();
  const [docs, setDocs] = useState<Doc[] | null>(null);
  const [tutors, setTutors] = useState<TutorAccount[]>([]);
  const [err, setErr] = useState('');
  const load = useCallback(async () => {
    if (!sb) return;
    try {
      const r = await sb.rpc('admin_sign_docs');
      if (r.error) throw new Error(r.error.message);
      setDocs(parseDocs(r.data as Record<string, unknown>[]));
      setTutors(await loadTutorAccounts(sb));
    } catch (e) { setErr(e instanceof Error ? e.message : '불러오지 못했어요.'); }
  }, [sb]);
  useEffect(() => { void load(); }, [load]);

  // 문서 이름별로 묶고, 판은 최신부터
  const titles = [...new Set((docs ?? []).map((d) => d.title))];
  return (
    <div className="mx-auto min-h-dvh max-w-[1280px] pb-24 lg:pb-8">
      <AdminHeader active="home" demo={false} />
      <div className="grid gap-3 px-4 pt-3 lg:max-w-[860px] lg:px-7 lg:pt-5">
        <Link href="/lms/admin" className="min-h-[32px] w-fit text-[13.5px] font-semibold text-[#5b3fe0]">← 홈</Link>
        <h1 className="text-[17px] font-bold text-[#1d1b2b]">강사 서명 문서</h1>
        {(error || err) && <p role="alert" className="text-[13px] text-[#c62b2b]">{error ?? err}</p>}
        {!docs && !error && !err && <p className="py-10 text-center text-[14px] text-[#6b6880]">불러오는 중…</p>}
        {sb && docs && titles.map((title) => (
          <DocGroup key={title} sb={sb} docs={docs.filter((d) => d.title === title)} tutors={tutors} onChanged={load} />
        ))}
        {sb && docs && <NewDoc sb={sb} onSaved={load} />}
      </div>
      <BottomNav active="home" demo={false} />
    </div>
  );
}

function DocGroup({ sb, docs, tutors, onChanged }: { sb: SupabaseClient; docs: Doc[]; tutors: TutorAccount[]; onChanged: () => Promise<void> }) {
  const [showOld, setShowOld] = useState(false);
  const draft = docs.find((d) => d.status === 'draft');
  const live = docs.find((d) => d.status === 'published');
  const old = docs.filter((d) => d.status === 'retired');
  const [err, setErr] = useState('');
  async function newVersion() {
    if (!live) return;
    setErr('');
    const r = await sb.rpc('admin_sign_doc_save', { p_document: null, p_title: live.title, p_body: live.body, p_statement: live.statement });
    if (r.error) setErr(r.error.message); else await onChanged();
  }
  return (
    <section aria-label={docs[0].title} className={`${box} grid gap-3`}>
      <h2 className="text-[16px] font-bold text-[#1d1b2b]">{docs[0].title}</h2>
      {live && <LiveDoc sb={sb} doc={live} tutors={tutors} onChanged={onChanged} />}
      {draft && <DraftDoc sb={sb} doc={draft} onChanged={onChanged} />}
      {live && !draft && <button type="button" onClick={() => void newVersion()} className={`${btnLine} w-fit`}>새 판 만들기</button>}
      {err && <p role="alert" className="text-[13px] text-[#c62b2b]">{err}</p>}
      {old.length > 0 && (
        <div>
          <button type="button" onClick={() => setShowOld(!showOld)} className="min-h-[36px] text-[13px] font-semibold text-[#5b3fe0] underline">{showOld ? '지난 판 접기' : `지난 판 ${old.length}개`}</button>
          {showOld && old.map((d) => <LiveDoc key={d.id} sb={sb} doc={d} tutors={tutors} onChanged={onChanged} />)}
        </div>
      )}
    </section>
  );
}

function LiveDoc({ sb, doc, tutors, onChanged }: { sb: SupabaseClient; doc: Doc; tutors: TutorAccount[]; onChanged: () => Promise<void> }) {
  const [adding, setAdding] = useState(false);
  const [pick, setPick] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [showText, setShowText] = useState(false);
  const asked = new Set(doc.requests.map((r) => r.tutorId));
  const canAsk = tutors.filter((t) => t.active && !asked.has(t.id));
  async function send() {
    setBusy(true); setErr('');
    const r = await sb.rpc('admin_sign_request', { p_document: doc.id, p_tutors: pick });
    setBusy(false);
    if (r.error) return setErr(r.error.message);
    setPick([]); setAdding(false); await onChanged();
  }
  async function pdf(id: string) {
    const tutor = doc.requests.find((r) => r.signatureId === id)?.tutorId;
    const r = await sb.rpc('tutor_signed_pdf', { p_signature: id, p_tutor: tutor });
    if (r.error) return setErr(r.error.message);
    const j = r.data as { filename: string; base64: string };
    downloadPdf(j.filename, j.base64);
  }
  return (
    <div className="grid gap-2 border-t border-[#e6e3ef] pt-2 first:border-0 first:pt-0">
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
        <b className="text-[14.5px]">{doc.revision}판</b>
        {doc.status === 'retired' && <span className="text-[13px] text-[#6b6880]">지난 판</span>}
        {doc.publishedAt && <span className="text-[13px] font-semibold text-[#1f7a4d]">회사 서명함 {kst(doc.publishedAt)}</span>}
        <button type="button" onClick={() => setShowText(!showText)} className="min-h-[32px] text-[13px] font-semibold text-[#5b3fe0] underline">{showText ? '전문 접기' : '전문 보기'}</button>
      </div>
      {showText && <pre className="max-h-[40vh] overflow-auto whitespace-pre-wrap rounded-[10px] bg-[#fbfaf7] p-3 font-sans text-[13px] leading-relaxed">{doc.body}{'\n\n'}{doc.statement}</pre>}
      {doc.requests.length > 0 && (
        <ul className="divide-y divide-[#f0eef5]">
          {doc.requests.map((r) => (
            <li key={r.requestId} className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-2 py-2 text-[13.5px]">
              <span>
                <b className="text-[14px] text-[#1d1b2b]">{r.tutor}</b>{' '}
                {r.signedAt
                  ? <span className="font-semibold text-[#1f7a4d]">서명함 ✓</span>
                  : <span className={Date.now() > r.dueAt.getTime() ? 'font-semibold text-[#b3261e]' : 'text-[#6b6880]'}>서명 대기 · 기한 {kst(r.dueAt)}</span>}
                {r.signedAt && (
                  <span className="block text-[12.5px] text-[#55526a]">
                    {r.country} · {kst(r.signedAt)} · 서명본 메일 {MAIL[r.mailStatus ?? ''] ?? '없음'}{r.mailError ? ` (${r.mailError})` : ''}
                  </span>
                )}
              </span>
              {r.signatureId && <button type="button" onClick={() => void pdf(r.signatureId!)} className={btnLine}>PDF</button>}
            </li>
          ))}
        </ul>
      )}
      {doc.status === 'published' && !adding && <button type="button" disabled={canAsk.length === 0} onClick={() => setAdding(true)} className={`${btn} w-fit`}>서명 요청 보낼 강사 추가</button>}
      {adding && (
        <div className="grid gap-1.5 rounded-[10px] bg-[#f7f6fb] p-3">
          {canAsk.map((t) => (
            <label key={t.id} className="flex min-h-[40px] items-center gap-2 text-[14.5px]">
              <input type="checkbox" className="h-[18px] w-[18px] accent-[#5b3fe0]" checked={pick.includes(t.id)}
                onChange={(e) => setPick(e.target.checked ? [...pick, t.id] : pick.filter((x) => x !== t.id))} />
              {t.name}{t.hasLogin ? '' : <span className="text-[12.5px] text-[#b3261e]">강사 계정 없음</span>}
            </label>
          ))}
          <div className="flex gap-2">
            <button type="button" disabled={busy || pick.length === 0} onClick={() => void send()} className={btn}>요청 보내기</button>
            <button type="button" onClick={() => { setAdding(false); setPick([]); }} className={btnLine}>닫기</button>
          </div>
        </div>
      )}
      {err && <p role="alert" className="text-[13px] text-[#c62b2b]">{err}</p>}
    </div>
  );
}

function DraftDoc({ sb, doc, onChanged }: { sb: SupabaseClient; doc: Doc; onChanged: () => Promise<void> }) {
  const [body, setBody] = useState(doc.body);
  const [stmt, setStmt] = useState(doc.statement);
  const [sure, setSure] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [saved, setSaved] = useState(false);
  const dirty = body !== doc.body || stmt !== doc.statement;
  async function save() {
    setBusy(true); setErr('');
    const r = await sb.rpc('admin_sign_doc_save', { p_document: doc.id, p_title: null, p_body: body, p_statement: stmt });
    setBusy(false);
    if (r.error) return setErr(r.error.message);
    setSaved(true); await onChanged();
  }
  async function publish() {
    setBusy(true); setErr('');
    const r = await sb.rpc('admin_sign_doc_publish', { p_document: doc.id });
    setBusy(false);
    if (r.error) return setErr(r.error.message);
    await onChanged();
  }
  return (
    <div className="grid gap-2 border-t border-[#e6e3ef] pt-2 first:border-0 first:pt-0">
      <b className="text-[14.5px]">{doc.revision}판 · 초안</b>
      <label className="grid gap-1 text-[13px] font-semibold text-[#55526a]">전문
        <textarea value={body} onChange={(e) => { setBody(e.target.value); setSaved(false); setSure(false); }} rows={12} className={`${field} font-sans leading-relaxed`} />
      </label>
      <label className="grid gap-1 text-[13px] font-semibold text-[#55526a]">서명 문구
        <textarea value={stmt} onChange={(e) => { setStmt(e.target.value); setSaved(false); setSure(false); }} rows={2} className={field} />
      </label>
      <div className="flex flex-wrap gap-2">
        {saved && !dirty ? <button type="button" disabled className="inline-flex min-h-[40px] items-center rounded-[10px] bg-[#e9e7f0] px-3 text-[13.5px] font-semibold text-[#6b6880]">저장함 ✓</button>
          : <button type="button" disabled={busy || !dirty} onClick={() => void save()} className={btnLine}>저장</button>}
        {!sure && <button type="button" disabled={busy || dirty} onClick={() => setSure(true)} className={btn}>회사 서명하고 올리기</button>}
      </div>
      {sure && (
        <div className="grid gap-2 rounded-[10px] bg-[#fff4d6] p-3 text-[13.5px] text-[#5c3b00]">
          <p>올리면 이 판의 전문은 고칠 수 없어요.</p>
          <div className="flex gap-2">
            <button type="button" disabled={busy} onClick={() => void publish()} className={btn}>올리기</button>
            <button type="button" onClick={() => setSure(false)} className={btnLine}>취소</button>
          </div>
        </div>
      )}
      {err && <p role="alert" className="text-[13px] text-[#c62b2b]">{err}</p>}
    </div>
  );
}

function NewDoc({ sb, onSaved }: { sb: SupabaseClient; onSaved: () => Promise<void> }) {
  const [open, setOpen] = useState(false);
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [stmt, setStmt] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  async function save() {
    setBusy(true); setErr('');
    const r = await sb.rpc('admin_sign_doc_save', { p_document: null, p_title: title, p_body: body, p_statement: stmt });
    setBusy(false);
    if (r.error) return setErr(r.error.message);
    setOpen(false); setTitle(''); setBody(''); setStmt(''); await onSaved();
  }
  if (!open) return <button type="button" onClick={() => setOpen(true)} className={`${btnLine} w-fit`}>새 문서 만들기</button>;
  return (
    <section aria-label="새 문서" className={`${box} grid gap-2`}>
      <h2 className="text-[15px] font-bold text-[#1d1b2b]">새 문서</h2>
      <label className="grid gap-1 text-[13px] font-semibold text-[#55526a]">문서 이름 (영어, 강사에게 보임)
        <input value={title} onChange={(e) => setTitle(e.target.value)} className={field} />
      </label>
      <label className="grid gap-1 text-[13px] font-semibold text-[#55526a]">전문
        <textarea value={body} onChange={(e) => setBody(e.target.value)} rows={10} className={field} />
      </label>
      <label className="grid gap-1 text-[13px] font-semibold text-[#55526a]">서명 문구
        <textarea value={stmt} onChange={(e) => setStmt(e.target.value)} rows={2} className={field} />
      </label>
      <div className="flex gap-2">
        <button type="button" disabled={busy || !title.trim() || !body.trim() || !stmt.trim()} onClick={() => void save()} className={btn}>초안 저장</button>
        <button type="button" onClick={() => setOpen(false)} className={btnLine}>닫기</button>
      </div>
      {err && <p role="alert" className="text-[13px] text-[#c62b2b]">{err}</p>}
    </section>
  );
}
