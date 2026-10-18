'use client';

// 로그인 A안: 가운데 카드 하나에서 단계가 바뀜 — 이메일 → 메일 코드 → (운영자) 인증 앱 코드 / 첫 등록
// 등록 안 된 이메일도 화면은 같게 진행 (등록 여부를 알려 주지 않음, 계정·메일은 생기지 않음)

import Link from 'next/link';
import { useEffect, useRef, useState } from 'react';
import { supabaseBrowser } from '@/lms/auth/client';
import { afterEmailCode, looksLikeEmail, maskEmail, RESEND_WAIT_SECONDS, STRINGS, type Lang, type Role } from '@/lms/auth/login-flow';

type Step = 'email' | 'code' | 'totp' | 'enroll' | 'not_linked' | 'moving';

const LANG_KEY = 'lms-lang';

function readLang(): Lang {
  try {
    return localStorage.getItem(LANG_KEY) === 'en' ? 'en' : 'ko';
  } catch {
    return 'ko';
  }
}

export default function LoginFlow() {
  const [lang, setLang] = useState<Lang>('ko');
  const [step, setStep] = useState<Step>('email');
  const [email, setEmail] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [wait, setWait] = useState(0);
  const [showLost, setShowLost] = useState(false);
  const [enroll, setEnroll] = useState<{ factorId: string; qr: string; secret: string } | null>(null);
  const [factorId, setFactorId] = useState<string | null>(null);
  const t = STRINGS[lang];
  const sb = supabaseBrowser();
  const codeRef = useRef<HTMLInputElement>(null);

  useEffect(() => setLang(readLang()), []);
  useEffect(() => {
    if (wait <= 0) return;
    const id = setTimeout(() => setWait((w) => w - 1), 1000);
    return () => clearTimeout(id);
  }, [wait]);
  useEffect(() => {
    if (step !== 'email') codeRef.current?.focus();
  }, [step]);

  function switchLang(next: Lang) {
    setLang(next);
    try {
      localStorage.setItem(LANG_KEY, next);
    } catch {
      /* 저장 안 돼도 화면은 바뀜 */
    }
  }

  function failMessage(e: unknown): string {
    const status = (e as { status?: number })?.status;
    if (status === 429) return t.tooMany;
    if (status && status >= 400 && status < 500) return t.badCode;
    return t.network;
  }

  async function sendCode(resend = false) {
    if (!sb) return setError(t.network);
    if (!looksLikeEmail(email)) return setError(t.badEmail);
    setBusy(true);
    setError(null);
    const { error: e } = await sb.auth.signInWithOtp({ email: email.trim(), options: { shouldCreateUser: false } });
    setBusy(false);
    // 등록 안 된 이메일(422)도 같은 화면으로 — 등록 여부를 알려 주지 않음
    if (e && e.status === 429) return setError(t.tooMany);
    if (e && !(e.status && e.status >= 400 && e.status < 500)) return setError(t.network);
    setCode('');
    setWait(RESEND_WAIT_SECONDS);
    setStep('code');
    setNotice(resend ? t.resent : null);
  }

  async function routeAfterLogin() {
    if (!sb) return;
    const [{ data: role }, { data: aal }, { data: factors }] = await Promise.all([
      sb.rpc('my_role'),
      sb.auth.mfa.getAuthenticatorAssuranceLevel(),
      sb.auth.mfa.listFactors(),
    ]);
    const verified = factors?.totp ?? [];
    const next = afterEmailCode({
      role: (role as Role | null) ?? null,
      aal: aal?.currentLevel === 'aal2' ? 'aal2' : 'aal1',
      verifiedTotp: verified.length,
    });
    if (next.kind === 'go') {
      setStep('moving');
      window.location.assign(next.to);
    } else if (next.kind === 'totp_verify') {
      setFactorId(verified[0].id);
      setCode('');
      setStep('totp');
    } else if (next.kind === 'totp_enroll') {
      const { data, error: e } = await sb.auth.mfa.enroll({ factorType: 'totp', friendlyName: `EdgeEnglish ${new Date().toISOString().slice(0, 10)}` });
      if (e || !data) return setError(failMessage(e));
      setEnroll({ factorId: data.id, qr: data.totp.qr_code, secret: data.totp.secret });
      setCode('');
      setStep('enroll');
    } else {
      setStep('not_linked');
    }
  }

  async function verifyEmailCode() {
    if (!sb || code.length !== 6) return;
    setBusy(true);
    setError(null);
    const { error: e } = await sb.auth.verifyOtp({ email: email.trim(), token: code, type: 'email' });
    if (e) {
      setBusy(false);
      return setError(failMessage(e));
    }
    await routeAfterLogin();
    setBusy(false);
  }

  async function verifyTotp() {
    const id = step === 'enroll' ? enroll?.factorId : factorId;
    if (!sb || !id || code.length !== 6) return;
    setBusy(true);
    setError(null);
    const { error: e } = await sb.auth.mfa.challengeAndVerify({ factorId: id, code });
    if (e) {
      setBusy(false);
      return setError(failMessage(e));
    }
    await routeAfterLogin();
    setBusy(false);
  }

  async function logout() {
    await sb?.auth.signOut();
    setStep('email');
    setCode('');
    setError(null);
  }

  const codeBoxes = (onDone: () => void, label: string) => (
    <label className="relative block">
      <span className="sr-only">{label}</span>
      <input
        ref={codeRef}
        inputMode="numeric"
        autoComplete="one-time-code"
        maxLength={6}
        value={code}
        onChange={(e) => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))}
        onKeyDown={(e) => e.key === 'Enter' && onDone()}
        className="absolute inset-0 z-10 h-full w-full cursor-text opacity-0"
      />
      <span aria-hidden className="grid grid-cols-6 gap-2">
        {Array.from({ length: 6 }, (_, i) => (
          <span
            key={i}
            className={`flex h-[58px] items-center justify-center rounded-[12px] border-[1.5px] bg-white text-[26px] font-bold text-[#1d1b2b] ${
              i === Math.min(code.length, 5) ? 'border-[#5b3df0] shadow-[0_0_0_3px_#e4ddff]' : 'border-[#d9d5e8]'
            }`}
          >
            {code[i] ?? ''}
          </span>
        ))}
      </span>
    </label>
  );

  const primary = 'flex min-h-[52px] w-full items-center justify-center rounded-[14px] text-[16px] font-bold text-white disabled:opacity-40';
  const ghost = 'min-h-[44px] text-[14px] text-[#55526a]';

  return (
    <div className="flex min-h-dvh flex-col items-center px-[18px] pb-10 pt-6">
      <div className="flex w-full max-w-[400px] justify-end">
        <div role="group" aria-label="Language" className="flex rounded-full border border-[#d9d5e8] bg-white p-0.5 text-[13px]">
          {(['ko', 'en'] as const).map((l) => (
            <button
              key={l}
              type="button"
              aria-pressed={lang === l}
              onClick={() => switchLang(l)}
              className={`min-h-[32px] rounded-full px-3 ${lang === l ? 'bg-[#1b1442] font-semibold text-white' : 'text-[#55526a]'}`}
            >
              {l === 'ko' ? '한국어' : 'English'}
            </button>
          ))}
        </div>
      </div>

      <div className="mt-6 text-center">
        <p className="text-[26px] font-bold text-[#09246b]">
          Edge<span className="text-[#5b3df0]">English</span>
        </p>
        <p className="mt-1 text-[14px] text-[#55526a]">{t.portal}</p>
      </div>

      <main className="mt-7 w-full max-w-[400px] rounded-[22px] border border-[#e6e3ef] bg-white px-5 py-6">
        {!sb && <p className="text-[14px] text-[#b3261e]">{t.network}</p>}

        {step === 'email' && (
          <form
            onSubmit={(e) => {
              e.preventDefault();
              sendCode();
            }}
          >
            <h1 className="text-[22px] font-bold text-[#1d1b2b]">{t.loginTitle}</h1>
            <p className="mb-[18px] mt-1.5 text-[13px] leading-relaxed text-[#55526a]">{t.loginLead}</p>
            <label className="block">
              <span className="sr-only">{t.emailLabel}</span>
              <input
                type="email"
                inputMode="email"
                autoComplete="email"
                placeholder={t.emailLabel}
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="min-h-[52px] w-full rounded-[14px] border-[1.5px] border-[#d9d5e8] px-4 text-[16px] text-[#1d1b2b] outline-none focus:border-[#5b3df0]"
              />
            </label>
            <button type="submit" disabled={busy} className={`${primary} mt-3 bg-[#5b3df0]`}>
              {t.sendCode}
            </button>
            <p className="mt-[18px] text-[13px] leading-relaxed text-[#55526a]">
              {t.noPassword}
              <br />
              {t.contact}
            </p>
          </form>
        )}

        {step === 'code' && (
          <div>
            <h1 className="text-[22px] font-bold text-[#1d1b2b]">{t.codeTitle}</h1>
            <p className="mb-[18px] mt-1.5 text-[13px] leading-relaxed text-[#55526a]">
              <b className="break-all text-[#1d1b2b]">{t.codeSent(maskEmail(email))}</b>
              <br />
              {t.codeLead}
            </p>
            {codeBoxes(verifyEmailCode, t.codeLabel)}
            <button type="button" disabled={busy || code.length !== 6} onClick={verifyEmailCode} className={`${primary} mt-4 bg-[#5b3df0]`}>
              {t.login}
            </button>
            <div className="mt-2 flex justify-between">
              <button type="button" className={ghost} onClick={() => setStep('email')}>
                {t.changeEmail}
              </button>
              <button type="button" className={`${ghost} disabled:opacity-50`} disabled={wait > 0 || busy} onClick={() => sendCode(true)}>
                {wait > 0 ? t.resendIn(wait) : t.resend}
              </button>
            </div>
            <p className="text-[13px] leading-relaxed text-[#55526a]">{t.spam}</p>
          </div>
        )}

        {(step === 'totp' || step === 'enroll') && (
          <div>
            <span className="mb-2.5 inline-block rounded-full bg-[#fff1d6] px-2.5 py-1 text-[12px] font-bold text-[#8a5300]">{t.adminOnly}</span>
            <h1 className="text-[22px] font-bold text-[#1d1b2b]">{step === 'enroll' ? t.enrollTitle : t.totpTitle}</h1>
            <p className="mb-[18px] mt-1.5 text-[13px] leading-relaxed text-[#55526a]">{step === 'enroll' ? t.enrollLead : t.totpLead}</p>
            {step === 'enroll' && enroll && (
              <div className="mb-4 text-center">
                <img src={enroll.qr} alt="QR" width={180} height={180} className="mx-auto rounded-[12px] border border-[#e6e3ef]" />
                <p className="mt-2 text-[12px] text-[#55526a]">{t.enrollManual}</p>
                <p className="mt-1 break-all font-mono text-[13px] text-[#1d1b2b]">{enroll.secret}</p>
              </div>
            )}
            {codeBoxes(verifyTotp, t.totpTitle)}
            <button type="button" disabled={busy || code.length !== 6} onClick={verifyTotp} className={`${primary} mt-4 bg-[#1b1442]`}>
              {step === 'enroll' ? t.enrollDone : t.confirm}
            </button>
            {step === 'enroll' ? (
              <p className="mt-3 rounded-[12px] bg-[#f1eefc] px-3.5 py-3 text-[13px] leading-relaxed text-[#3a2f7a]">{t.enrollTip}</p>
            ) : (
              <>
                <button type="button" className={`${ghost} mt-1.5 w-full`} onClick={() => setShowLost((v) => !v)}>
                  {t.lostPhone}
                </button>
                {showLost && <p className="text-[13px] leading-relaxed text-[#55526a]">{t.lostPhoneHelp}</p>}
              </>
            )}
            <button type="button" className={`${ghost} w-full`} onClick={logout}>
              {t.logout}
            </button>
          </div>
        )}

        {step === 'not_linked' && (
          <div>
            <h1 className="text-[20px] font-bold text-[#1d1b2b]">{t.notLinkedTitle}</h1>
            <p className="mt-2 text-[14px] leading-relaxed text-[#55526a]">{t.notLinkedLead}</p>
            <button type="button" className={`${primary} mt-5 bg-[#1b1442]`} onClick={logout}>
              {t.logout}
            </button>
          </div>
        )}

        {step === 'moving' && <p className="text-center text-[15px] text-[#55526a]">{t.moving}</p>}

        {notice && !error && step === 'code' && (
          <p role="status" className="mt-3 text-[13px] text-[#13623a]">
            {notice}
          </p>
        )}
        {error && (
          <p role="alert" className="mt-3 text-[13px] leading-relaxed text-[#b3261e]">
            {error}
          </p>
        )}
      </main>

      <Link href="/" className="mt-5 text-[13px] text-[#4b2fd6]">
        {t.backHome}
      </Link>
    </div>
  );
}
