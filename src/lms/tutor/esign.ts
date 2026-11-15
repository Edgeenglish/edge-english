// 강사 LMS 전자서명 (H26(188), 대표 11/15). 규칙·기록은 DB (migration 20261115050000)
//  - To do 'Sign: …' → 전문 → 거주 국가·이름 → 이메일 6자리 코드 → [I agree and sign]
//  - 서명은 강사 본인만 (운영자 보기는 열람·PDF 받기만)
import type { SupabaseClient } from '@supabase/supabase-js';

export type SignOpen = { requestId: string; title: string; revision: number; dueAt: Date };
export type SignDone = { signatureId: string; requestId: string; title: string; revision: number; signedAt: Date; tz: string };
export type SignList = { open: SignOpen[]; signed: SignDone[] };
export type SignDoc = {
  requestId: string;
  title: string;
  revision: number;
  body: string;
  statement: string;
  companySignedAt: Date;
  documentSha256: string;
  dueAt: Date;
  signed: { signatureId: string; name: string; country: string; signedAt: Date; tz: string } | null;
  code: { sentTo: string; expiresAt: Date } | null;
};
export type SignResult = { ok: true; signatureId: string } | { ok: false; error: 'wrong' | 'too_many' | 'expired' | 'no_code'; left?: number };

export type SignActions = {
  list: () => Promise<SignList | null>;
  doc: (requestId: string) => Promise<SignDoc>;
  /** 운영자 보기면 null (서명은 강사 본인만) */
  sendCode: ((requestId: string) => Promise<{ sentTo: string; expiresAt: Date }>) | null;
  sign: ((requestId: string, code: string, name: string, country: string) => Promise<SignResult>) | null;
  pdf: (signatureId: string) => Promise<{ filename: string; base64: string }>;
};

function check<T>(r: { data: T; error: { message: string } | null }): T {
  if (r.error) throw new Error(r.error.message);
  return r.data;
}
const missing = (code?: string) => code === 'PGRST202' || code === '42883';

export function parseSignList(j: Record<string, unknown>): SignList {
  return {
    open: ((j.open ?? []) as Record<string, unknown>[]).map((o) => ({
      requestId: String(o.request_id), title: String(o.title), revision: Number(o.revision), dueAt: new Date(String(o.due_at)),
    })),
    signed: ((j.signed ?? []) as Record<string, unknown>[]).map((s) => ({
      signatureId: String(s.signature_id), requestId: String(s.request_id), title: String(s.title), revision: Number(s.revision),
      signedAt: new Date(String(s.signed_at)), tz: String(s.tz),
    })),
  };
}

export function parseSignDoc(j: Record<string, unknown>): SignDoc {
  const s = j.signed as Record<string, unknown> | null;
  const c = j.code as Record<string, unknown> | null;
  return {
    requestId: String(j.request_id),
    title: String(j.title),
    revision: Number(j.revision),
    body: String(j.body ?? ''),
    statement: String(j.statement ?? ''),
    companySignedAt: new Date(String(j.company_signed_at)),
    documentSha256: String(j.document_sha256),
    dueAt: new Date(String(j.due_at)),
    signed: s ? { signatureId: String(s.signature_id), name: String(s.name), country: String(s.country), signedAt: new Date(String(s.signed_at)), tz: String(s.tz) } : null,
    code: c ? { sentTo: String(c.sent_to), expiresAt: new Date(String(c.expires_at)) } : null,
  };
}

/** 전문 → 문단. 첫 문단은 제목, 각 문단 첫 줄이 '1. …' 이면 조 제목 */
export function docParagraphs(body: string): { heading: string | null; lines: string[]; title: boolean }[] {
  return body.trim().split(/\n\s*\n/).map((p, i) => {
    const lines = p.split('\n');
    if (i === 0) return { heading: lines[0], lines: lines.slice(1), title: true };
    if (/^\d+\.\s/.test(lines[0])) return { heading: lines[0], lines: lines.slice(1), title: false };
    return { heading: null, lines, title: false };
  });
}

/** 6자리 숫자만 (붙여 넣은 공백·하이픈 제거) */
export const cleanCode = (s: string) => s.replace(/\D/g, '').slice(0, 6);

export const SIGN_ERROR: Record<'wrong' | 'too_many' | 'expired' | 'no_code', string> = {
  wrong: 'Wrong code.',
  too_many: 'Too many wrong codes. Send a new code.',
  expired: 'This code has expired. Send a new code.',
  no_code: 'Send a code to your email first.',
};

export function signActions(sb: SupabaseClient, tutorId: string | null): SignActions {
  return {
    list: async () => {
      const r = await sb.rpc('tutor_sign_list', { p_tutor: tutorId });
      if (missing(r.error?.code)) return null;   // 함수 없는 옛 DB: 표시만 없음
      return parseSignList(check(r) as Record<string, unknown>);
    },
    doc: async (requestId) => parseSignDoc(check(await sb.rpc('tutor_sign_doc', { p_request: requestId, p_tutor: tutorId })) as Record<string, unknown>),
    sendCode: tutorId ? null : async (requestId) => {
      const j = check(await sb.rpc('tutor_sign_send_code', { p_request: requestId })) as Record<string, unknown>;
      return { sentTo: String(j.sent_to), expiresAt: new Date(String(j.expires_at)) };
    },
    sign: tutorId ? null : async (requestId, code, name, country) => {
      const j = check(await sb.rpc('tutor_sign', { p_request: requestId, p_code: code, p_name: name, p_country: country })) as Record<string, unknown>;
      if (j.ok === true) return { ok: true, signatureId: String(j.signature_id) };
      return { ok: false, error: j.error as 'wrong', left: typeof j.left === 'number' ? j.left : undefined };
    },
    pdf: async (signatureId) => {
      const j = check(await sb.rpc('tutor_signed_pdf', { p_signature: signatureId, p_tutor: tutorId })) as Record<string, unknown>;
      return { filename: String(j.filename), base64: String(j.base64) };
    },
  };
}

/** base64 PDF → 내려받기 */
export function downloadPdf(filename: string, base64: string) {
  const bin = atob(base64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const url = URL.createObjectURL(new Blob([bytes], { type: 'application/pdf' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}
