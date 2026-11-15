'use client';

// 강사 LMS 전자서명 (H26(188), 시안 docs/lms/previews/tutor-esign-drafts.html, 대표 11/15 확정)
//  - 서명 창: 전문 → 회사 서명 줄 → Country of residence · Full name → [Email me a code] → 6자리 → 서명 의사 문구 → [I agree and sign]
//  - 서명 뒤: 같은 창에 ✓ Signed + 서명 정보 + [Download PDF] (To do 에서는 빠지고 My info › Documents 에 남음)
//  - 운영자 보기: 열람·PDF 받기만, 입력칸·버튼은 못 누름 (대표 11/15: 서명은 강사 본인만)
import { useEffect, useState } from 'react';
import { Rich } from '@/app/lms/Rich';
import { enBoth, enDay } from '@/lms/admin/time-text';
import { useT } from '@/lms/tutor/lang';
import { cleanCode, docParagraphs, downloadPdf, SIGN_ERROR, type SignActions, type SignDoc, type SignList } from '@/lms/tutor/esign';

const card = 'rounded-[14px] border border-[#e6e3ef] bg-white p-4';
const btnMain = 'min-h-[44px] rounded-[10px] bg-[#5b3fe0] px-4 text-[15px] font-semibold text-white disabled:opacity-40';
const btnDone = 'min-h-[44px] rounded-[10px] bg-[#e9e7f0] px-4 text-[15px] font-semibold text-[#6b6880]';
const btnSub = 'min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-4 text-[15px] font-semibold text-[#1d1b2b] disabled:opacity-40';
const input = 'min-h-[44px] w-full rounded-[10px] border border-[#d9d5e6] bg-white px-3 text-[16px] text-[#1d1b2b] disabled:bg-[#f3f1f8] disabled:text-[#8a879c]';

/** 전문 (첫 문단 제목, '1. …' 조 제목 굵게). 이 칸 안에서 스크롤 */
export function DocText({ doc, tz, maxH = 'max-h-[46vh]' }: { doc: SignDoc; tz: string; maxH?: string }) {
  return (
    <div tabIndex={0} aria-label={doc.title} className={`${maxH} overflow-y-auto rounded-[12px] border border-[#e6e3ef] bg-[#fbfaf7] px-4 py-3 text-[14px] leading-relaxed text-[#1d1b2b]`}>
      {docParagraphs(doc.body).map((p, i) => (
        <p key={i} className="mb-2.5">
          {p.heading && <span className={`block font-bold ${p.title ? 'mb-1 text-[16.5px]' : ''}`}>{p.heading}</span>}
          {p.lines.map((l, j) => <span key={j} className="block">{l}</span>)}
        </p>
      ))}
      <p className="mt-1 border-t border-dashed border-[#d9d5e6] pt-2.5 text-[13.5px]">
        Party A: Tangerine English (Edge English)<br />
        Signed electronically by the Representative · <Rich text={enBoth(doc.companySignedAt, tz)} />
      </p>
    </div>
  );
}

export function SignSheetBody({ actions, requestId, tz, onSigned }: { actions: SignActions; requestId: string; tz: string; onSigned: () => void }) {
  const t = useT();
  const [doc, setDoc] = useState<SignDoc | null>(null);
  const [err, setErr] = useState('');
  const [country, setCountry] = useState('');
  const [name, setName] = useState('');
  const [code, setCode] = useState('');
  const [sentTo, setSentTo] = useState<string | null>(null);
  const [codeErr, setCodeErr] = useState('');
  const [busy, setBusy] = useState<'code' | 'sign' | 'pdf' | null>(null);
  const admin = !actions.sign;

  async function load() {
    try {
      const d = await actions.doc(requestId);
      setDoc(d);
      setSentTo(d.code?.sentTo ?? null);
    } catch (e) { setErr(e instanceof Error ? e.message : 'Could not load.'); }
  }
  useEffect(() => { void load(); }, [requestId]); // eslint-disable-line react-hooks/exhaustive-deps

  async function sendCode() {
    if (!actions.sendCode) return;
    setBusy('code'); setCodeErr(''); setCode('');
    try { setSentTo((await actions.sendCode(requestId)).sentTo); } catch (e) { setCodeErr(e instanceof Error ? e.message : 'Could not send. Please try again.'); } finally { setBusy(null); }
  }
  async function sign() {
    if (!actions.sign) return;
    setBusy('sign'); setCodeErr('');
    try {
      const r = await actions.sign(requestId, code, name, country);
      if (r.ok) { await load(); onSigned(); return; }
      setCodeErr(r.error === 'wrong' && r.left !== undefined ? `${SIGN_ERROR.wrong} ${r.left} ${r.left === 1 ? 'try' : 'tries'} left.` : SIGN_ERROR[r.error]);
      if (r.error === 'too_many' || r.error === 'expired' || r.error === 'no_code') setSentTo(null);
    } catch (e) { setCodeErr(e instanceof Error ? e.message : 'Could not sign. Please try again.'); } finally { setBusy(null); }
  }
  async function pdf(signatureId: string) {
    setBusy('pdf');
    try { const f = await actions.pdf(signatureId); downloadPdf(f.filename, f.base64); } catch (e) { setErr(e instanceof Error ? e.message : 'Could not download.'); } finally { setBusy(null); }
  }

  if (err && !doc) return <p role="alert" className="pt-10 text-[14px] text-[#b3261e]">{err}</p>;
  if (!doc) return <p className="pt-10 text-center text-[14px] text-[#6b6880]">Loading…</p>;
  const ready = name.trim().length >= 2 && country.trim().length >= 2;
  return (
    <div className="grid gap-3 pt-1">
      <header className="pr-12">
        <h2 className="text-[18px] font-bold leading-snug text-[#1d1b2b]">{t('Sign', '서명')}: {doc.title}</h2>
        <p className="text-[13px] text-[#6b6880]">Version {doc.revision}</p>
      </header>

      {doc.signed && (
        <div className={card}>
          <p className="mb-2 text-[16px] font-bold text-[#1f7a4d]">✓ {t('Signed', '서명함')}</p>
          <dl className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1 text-[14.5px]">
            <dt className="text-[#6b6880]">{t('Name', '이름')}</dt><dd>{doc.signed.name}</dd>
            <dt className="text-[#6b6880]">{t('Country', '거주 국가')}</dt><dd>{doc.signed.country}</dd>
            <dt className="text-[#6b6880]">{t('Signed', '서명 시각')}</dt><dd><Rich text={enBoth(doc.signed.signedAt, doc.signed.tz)} /></dd>
          </dl>
          <button type="button" disabled={busy === 'pdf'} onClick={() => void pdf(doc.signed!.signatureId)} className={`${btnSub} mt-3`}>{t('Download PDF', 'PDF 받기')}</button>
        </div>
      )}

      <DocText doc={doc} tz={tz} maxH={doc.signed ? 'max-h-[40vh]' : 'max-h-[46vh]'} />

      {!doc.signed && (
        <>
          <label className="grid gap-1 text-[14.5px] font-semibold text-[#1d1b2b]">
            Country of residence
            <input value={country} onChange={(e) => setCountry(e.target.value)} disabled={admin} autoComplete="country-name" maxLength={80} className={input} />
          </label>
          <label className="grid gap-1 text-[14.5px] font-semibold text-[#1d1b2b]">
            Full name
            <input value={name} onChange={(e) => setName(e.target.value)} disabled={admin} autoComplete="name" maxLength={100} className={input} />
          </label>

          <div className="grid gap-2">
            <div className="flex flex-wrap items-center gap-2">
              {sentTo
                ? <button type="button" disabled className={btnDone}>{t('Code sent', '코드 보냄')} ✓</button>
                : <button type="button" disabled={admin || busy === 'code'} onClick={() => void sendCode()} className={btnSub}>{busy === 'code' ? 'Sending…' : 'Email me a code'}</button>}
              {sentTo && <span className="min-w-0 break-all text-[13.5px] text-[#55526a]">{sentTo}</span>}
            </div>
            {sentTo && (
              <>
                <label className="grid gap-1 text-[14.5px] font-semibold text-[#1d1b2b]">
                  6-digit code
                  <input value={code} onChange={(e) => setCode(cleanCode(e.target.value))} inputMode="numeric" autoComplete="one-time-code" maxLength={6}
                    className={`${input} max-w-[180px] tracking-[0.3em]`} />
                </label>
                <button type="button" disabled={busy === 'code'} onClick={() => void sendCode()} className="min-h-[36px] w-fit text-[13.5px] font-semibold text-[#5b3fe0] underline">Send a new code</button>
              </>
            )}
            {codeErr && <p role="alert" className="text-[14px] text-[#b3261e]">{codeErr}</p>}
          </div>

          <p className="rounded-[10px] bg-[#efecfd] px-3 py-2.5 text-[14px] leading-relaxed text-[#1d1b2b]">{doc.statement}</p>
          {admin && <p className="text-[13.5px] text-[#55526a]">{t('Only the tutor can sign.', '강사 본인만 서명할 수 있어요')}</p>}
          <button type="button" disabled={admin || !ready || !sentTo || code.length !== 6 || busy === 'sign'} onClick={() => void sign()} className={`${btnMain} w-full`}>
            {busy === 'sign' ? 'Signing…' : 'I agree and sign'}
          </button>
        </>
      )}
      {err && <p role="alert" className="text-[14px] text-[#b3261e]">{err}</p>}
    </div>
  );
}

/** My info › Documents: 서명할 문서 + 서명한 문서 (PDF 받기) */
export function DocumentsCard({ list, actions, onOpen }: { list: SignList; actions: SignActions; onOpen: (requestId: string) => void }) {
  const t = useT();
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState('');
  async function pdf(id: string) {
    setBusy(id); setErr('');
    try { const f = await actions.pdf(id); downloadPdf(f.filename, f.base64); } catch (e) { setErr(e instanceof Error ? e.message : 'Could not download.'); } finally { setBusy(null); }
  }
  return (
    <section aria-label="Documents" className={card}>
      <h2 className="mb-1 text-[16px] font-bold text-[#1d1b2b]">{t('Documents', '서명 문서')}</h2>
      {list.open.length === 0 && list.signed.length === 0 && <p className="py-2 text-[14.5px] text-[#6b6880]">{t('No documents', '문서가 없어요')}</p>}
      <ul className="divide-y divide-[#f0eef5]">
        {list.open.map((o) => (
          <li key={o.requestId} className="flex flex-wrap items-center gap-x-3 gap-y-1 py-3">
            <span className="min-w-0 flex-1">
              <span className="block text-[15px] font-semibold text-[#1d1b2b]">{o.title}</span>
              <span className="block text-[13px] text-[#6b6880]">Version {o.revision} · {t('Not signed', '서명 전')}</span>
            </span>
            <button type="button" onClick={() => onOpen(o.requestId)} className={btnMain}>{t('Sign', '서명')} ›</button>
          </li>
        ))}
        {list.signed.map((s) => (
          <li key={s.signatureId} className="flex flex-wrap items-center gap-x-3 gap-y-1 py-3">
            <span className="min-w-0 flex-1">
              <span className="block text-[15px] font-semibold text-[#1d1b2b]">{s.title}</span>
              <span className="block text-[13px] text-[#55526a]">Version {s.revision} · {t('Signed', '서명')} <Rich text={enBoth(s.signedAt, s.tz)} /></span>
            </span>
            <span className="flex gap-2">
              <button type="button" onClick={() => onOpen(s.requestId)} className={btnSub}>{t('View', '보기')}</button>
              <button type="button" disabled={busy === s.signatureId} onClick={() => void pdf(s.signatureId)} className={btnSub}>PDF</button>
            </span>
          </li>
        ))}
      </ul>
      {err && <p role="alert" className="mt-2 text-[14px] text-[#b3261e]">{err}</p>}
    </section>
  );
}

/** To do 줄 아래 기한: 'Please sign by Mon, 23 Nov' (강사 현지 날짜). 지나면 빨간 글자 */
export function dueLine(dueAt: Date, tz: string, now: Date): { text: string; late: boolean } {
  return { text: `Please sign by ${enDay(dueAt, tz)}`, late: now.getTime() > dueAt.getTime() };
}
