'use client';

// 로그인 A안 카드 하나에서 단계가 바뀜 (H26(146)(150) 홈페이지 회원가입·로그인)
// 로그인: 이메일 + 비밀번호 (+ 켜져 있으면 카카오·네이버) → (운영자) 인증 앱 코드 / 첫 등록
// 회원가입: 이름·이메일·비밀번호·필수 동의 → 메일 6자리 코드 → 가입 끝(로그인된 채)
// 비밀번호 만들기·찾기: 이메일 → 메일 코드 + 새 비밀번호 (기존 학생·강사는 재가입 없이 지금 계정에 비밀번호만)
// 카카오·네이버 첫 로그인이 회원과 연결 안 되면 '처음이에요 / 이미 회원이에요' — 이미 회원이면 기존 계정 로그인 뒤에만 연결

import Link from 'next/link';
import { useEffect, useRef, useState } from 'react';
import type { Provider } from '@supabase/supabase-js';
import { supabaseBrowser } from '@/lms/auth/client';
import {
  afterEmailCode,
  enabledSocial,
  isMakeupLink,
  looksLikeEmail,
  maskEmail,
  needsSocialChoice,
  nextAfterLogin,
  PASSWORD_MIN,
  PROVIDER_ID,
  RESEND_WAIT_SECONDS,
  signupProblems,
  STRINGS,
  type Lang,
  type Role,
  type SignupProblem,
  type SocialProvider,
} from '@/lms/auth/login-flow';

type Step = 'login' | 'signup' | 'signup_code' | 'pw_email' | 'pw_new' | 'totp' | 'enroll' | 'member' | 'social_choice' | 'moving';

const LANG_KEY = 'lms-lang';
const LINK_KEY = 'lms-link-provider'; // '이미 회원이에요' 뒤 기존 계정 로그인이 끝나면 연결할 카카오·네이버
const APPLY_URL = 'https://forms.gle/arWZ6uzK3BFgaxM39';

function readLang(): Lang {
  try {
    return localStorage.getItem(LANG_KEY) === 'en' ? 'en' : 'ko';
  } catch {
    return 'ko';
  }
}
function readPendingLink(): SocialProvider | null {
  try {
    const v = sessionStorage.getItem(LINK_KEY);
    return v === 'kakao' || v === 'naver' ? v : null;
  } catch {
    return null;
  }
}
function setPendingLink(v: SocialProvider | null) {
  try {
    if (v) sessionStorage.setItem(LINK_KEY, v);
    else sessionStorage.removeItem(LINK_KEY);
  } catch {
    /* 저장 안 되면 연결은 로그인 뒤 다시 '이미 회원이에요'로 */
  }
}

export default function LoginFlow() {
  const [lang, setLang] = useState<Lang>('ko');
  const [step, setStep] = useState<Step>('login');
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [showPw, setShowPw] = useState(false);
  const [terms, setTerms] = useState(false);
  const [privacy, setPrivacy] = useState(false);
  const [problems, setProblems] = useState<SignupProblem[]>([]);
  const [emailTaken, setEmailTaken] = useState(false);
  const [badLogin, setBadLogin] = useState(false);
  const [joined, setJoined] = useState(false);
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [wait, setWait] = useState(0);
  const [showLost, setShowLost] = useState(false);
  const [enroll, setEnroll] = useState<{ factorId: string; qr: string; secret: string } | null>(null);
  const [factorId, setFactorId] = useState<string | null>(null);
  const [social, setSocial] = useState<SocialProvider[]>([]);
  const [linkFor, setLinkFor] = useState<SocialProvider | null>(null);
  const t = STRINGS[lang];
  const sb = supabaseBrowser();
  const codeRef = useRef<HTMLInputElement>(null);

  // 바로가기 링크로 왔으면 로그인 뒤 그 화면으로 (?next=/lms/student?makeup=…)
  const [next, setNext] = useState<string | null>(null);
  useEffect(() => {
    setLang(readLang());
    setNext(new URLSearchParams(window.location.search).get('next'));
    setLinkFor(readPendingLink());
  }, []);

  // 켜진 간편 로그인만 버튼으로 (꺼진 것을 누르면 오류가 나므로 아예 안 보임)
  useEffect(() => {
    const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
    if (!url || !key) return;
    fetch(`${url}/auth/v1/settings`, { headers: { apikey: key } })
      .then((r) => (r.ok ? r.json() : null))
      .then((s) => setSocial(enabledSocial(s?.external)))
      .catch(() => setSocial([]));
  }, []);

  // 카카오·네이버에서 돌아왔으면(?code=) 세션으로 바꾸고, 아니면 같은 주소의 유효한 세션을 이어 씀
  useEffect(() => {
    if (!sb) return;
    let active = true;
    const params = new URLSearchParams(window.location.search);
    const oauthCode = params.get('code');
    const oauthError = params.get('error_description') || params.get('error');
    (async () => {
      if (oauthError) {
        setPendingLink(null);
        setLinkFor(null);
        setError(t.socialFail);
      }
      if (oauthCode) {
        const { error: e } = await sb.auth.exchangeCodeForSession(oauthCode);
        params.delete('code');
        window.history.replaceState(null, '', `${window.location.pathname}${params.size ? `?${params}` : ''}`);
        if (e) {
          if (active) setError(readPendingLink() ? t.linkFail : t.socialFail);
          setPendingLink(null);
          setLinkFor(null);
          return;
        }
      }
      const { data } = await sb.auth.getSession();
      if (active && data.session) await routeAfterLogin();
    })().catch(() => { /* 세션이 유효하지 않으면 로그인 화면을 그대로 */ });
    return () => { active = false; };
  }, [sb]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (wait <= 0) return;
    const id = setTimeout(() => setWait((w) => w - 1), 1000);
    return () => clearTimeout(id);
  }, [wait]);
  useEffect(() => {
    if (step === 'signup_code' || step === 'totp' || step === 'enroll') codeRef.current?.focus();
  }, [step]);

  function switchLang(l: Lang) {
    setLang(l);
    try {
      localStorage.setItem(LANG_KEY, l);
    } catch {
      /* 저장 안 돼도 화면은 바뀜 */
    }
  }

  function go(s: Step) {
    setError(null);
    setNotice(null);
    setBadLogin(false);
    setProblems([]);
    setCode('');
    setStep(s);
  }

  function failMessage(e: unknown): string {
    const status = (e as { status?: number })?.status;
    if (status === 429) return t.tooMany;
    if (status && status >= 400 && status < 500) return t.badCode;
    return t.network;
  }

  async function routeAfterLogin() {
    if (!sb) return;
    const [{ data: role }, { data: aal }, { data: factors }, { data: userData }] = await Promise.all([
      sb.rpc('my_role'),
      sb.auth.mfa.getAuthenticatorAssuranceLevel(),
      sb.auth.mfa.listFactors(),
      sb.auth.getUser(),
    ]);
    const myRole = (role as Role | null) ?? null;
    const user = userData?.user;
    const providers = (user?.identities ?? []).map((i) => i.provider);
    if (needsSocialChoice({ role: myRole, providers, choseNew: user?.user_metadata?.edge_new_member === true })) {
      return setStep('social_choice');
    }
    const verified = factors?.totp ?? [];
    const after = afterEmailCode({ role: myRole, aal: aal?.currentLevel === 'aal2' ? 'aal2' : 'aal1', verifiedTotp: verified.length });
    if (after.kind === 'go') {
      // '이미 회원이에요'로 기존 계정 로그인을 마쳤으면 카카오·네이버를 이 계정에 연결 (갔다가 이 화면으로 돌아옴)
      const pending = readPendingLink();
      if (pending) {
        setPendingLink(null);
        setStep('moving');
        const { error: e } = await sb.auth.linkIdentity({
          provider: PROVIDER_ID[pending] as Provider,
          options: { redirectTo: `${window.location.origin}/lms/login` },
        });
        if (!e) return;
        setLinkFor(null);
        setStep('login');
        return setError(t.linkFail);
      }
      setStep('moving');
      window.location.assign(nextAfterLogin(new URLSearchParams(window.location.search).get('next'), after.to, myRole));
    } else if (after.kind === 'totp_verify') {
      setFactorId(verified[0].id);
      setCode('');
      setStep('totp');
    } else if (after.kind === 'totp_enroll') {
      const { data, error: e } = await sb.auth.mfa.enroll({ factorType: 'totp', issuer: '엣지영어 LMS', friendlyName: `EdgeEnglish ${new Date().toISOString().slice(0, 10)}` });
      if (e || !data) return setError(failMessage(e));
      setEnroll({ factorId: data.id, qr: data.totp.qr_code, secret: data.totp.secret });
      setCode('');
      setStep('enroll');
    } else {
      setStep('member');
    }
  }

  // ── 로그인
  async function passwordLogin() {
    if (!sb) return setError(t.network);
    setError(null);
    setBadLogin(false);
    if (!looksLikeEmail(email) || !password) return setBadLogin(true);
    setBusy(true);
    const { error: e } = await sb.auth.signInWithPassword({ email: email.trim(), password });
    if (e) {
      setBusy(false);
      if (e.status === 429) return setError(t.tooMany);
      if (e.status && e.status >= 400 && e.status < 500) return setBadLogin(true);
      return setError(t.network);
    }
    await routeAfterLogin();
    setBusy(false);
  }

  async function socialLogin(p: SocialProvider) {
    if (!sb) return setError(t.network);
    setBusy(true);
    const { error: e } = await sb.auth.signInWithOAuth({
      provider: PROVIDER_ID[p] as Provider,
      options: { redirectTo: `${window.location.origin}/lms/login${next ? `?next=${encodeURIComponent(next)}` : ''}` },
    });
    if (e) {
      setBusy(false);
      setError(t.socialFail);
    }
  }

  // ── 회원가입
  async function signup() {
    if (!sb) return setError(t.network);
    setError(null);
    setEmailTaken(false);
    const p = signupProblems({ name, email, password, terms, privacy });
    setProblems(p);
    if (p.length) return;
    setBusy(true);
    const agreedAt = new Date().toISOString();
    const { data, error: e } = await sb.auth.signUp({
      email: email.trim(),
      password,
      options: { data: { name: name.trim(), terms_agreed_at: agreedAt, privacy_agreed_at: agreedAt } },
    });
    setBusy(false);
    if (e) {
      if (e.status === 429) return setError(t.tooMany);
      if (e.code === 'user_already_exists' || e.code === 'email_exists') return setEmailTaken(true);
      if (e.code === 'weak_password') return setProblems(['password']);
      return setError(t.network);
    }
    // 이미 가입된 이메일이면 Supabase 는 오류 대신 로그인 방법이 없는 빈 사용자를 돌려줌 (메일도 안 보냄)
    if (data.user && (data.user.identities?.length ?? 0) === 0) return setEmailTaken(true);
    if (data.session) {
      setJoined(true);
      return routeAfterLogin();
    }
    setCode('');
    setWait(RESEND_WAIT_SECONDS);
    setStep('signup_code');
  }

  async function verifySignup() {
    if (!sb || code.length !== 6) return;
    setBusy(true);
    setError(null);
    const { error: e } = await sb.auth.verifyOtp({ email: email.trim(), token: code, type: 'signup' });
    if (e) {
      setBusy(false);
      return setError(failMessage(e));
    }
    setJoined(true);
    await routeAfterLogin();
    setBusy(false);
  }

  async function resendSignup() {
    if (!sb) return;
    setBusy(true);
    const { error: e } = await sb.auth.resend({ type: 'signup', email: email.trim() });
    setBusy(false);
    if (e && e.status === 429) return setError(t.tooMany);
    setWait(RESEND_WAIT_SECONDS);
    setNotice(t.resent);
  }

  // ── 비밀번호 만들기·찾기 (메일 코드로 로그인 → 새 비밀번호 저장)
  async function sendPwCode(resend = false) {
    if (!sb) return setError(t.network);
    if (!looksLikeEmail(email)) return setError(t.badEmail);
    setBusy(true);
    setError(null);
    const { error: e } = await sb.auth.signInWithOtp({ email: email.trim(), options: { shouldCreateUser: false } });
    setBusy(false);
    // 가입 안 된 이메일(422)도 같은 화면으로 — 가입 여부를 알려 주지 않음
    if (e && e.status === 429) return setError(t.tooMany);
    if (e && !(e.status && e.status >= 400 && e.status < 500)) return setError(t.network);
    setCode('');
    setPassword('');
    setWait(RESEND_WAIT_SECONDS);
    setStep('pw_new');
    setNotice(resend ? t.resent : null);
  }

  async function saveNewPassword() {
    if (!sb || code.length !== 6) return;
    setProblems([]);
    if (password.length < PASSWORD_MIN) return setProblems(['password']);
    setBusy(true);
    setError(null);
    const { error: e } = await sb.auth.verifyOtp({ email: email.trim(), token: code, type: 'email' });
    if (e) {
      setBusy(false);
      return setError(failMessage(e));
    }
    const { error: e2 } = await sb.auth.updateUser({ password });
    if (e2) {
      setBusy(false);
      if (e2.code === 'weak_password') return setProblems(['password']);
      if (e2.code !== 'same_password') return setError(t.network);
    }
    await routeAfterLogin();
    setBusy(false);
  }

  // ── 카카오·네이버 첫 로그인
  async function chooseNew() {
    if (!sb) return;
    setBusy(true);
    await sb.auth.updateUser({ data: { edge_new_member: true } });
    setBusy(false);
    await routeAfterLogin();
  }

  async function chooseExisting() {
    if (!sb) return;
    setBusy(true);
    const { data: user } = await sb.auth.getUser();
    const p = (user.user?.identities ?? []).map((i) => i.provider).find((x) => x !== 'email') ?? '';
    const provider: SocialProvider = p.includes('naver') ? 'naver' : 'kakao';
    // 방금 카카오·네이버로 생긴 빈 계정을 지워야 기존 계정에 연결할 수 있음 (회원 연결이 있는 계정은 DB가 지우지 않음)
    const { data: done, error: e } = await sb.rpc('lms_discard_new_social_account');
    await sb.auth.signOut();
    setBusy(false);
    if (e || done !== true) {
      go('login');
      return setError(t.linkFail);
    }
    setPendingLink(provider);
    setLinkFor(provider);
    go('login');
  }

  async function logout() {
    await sb?.auth.signOut();
    setPendingLink(null);
    setLinkFor(null);
    setJoined(false);
    go('login');
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
  const inputCls = (bad: boolean) =>
    `min-h-[52px] w-full rounded-[14px] border-[1.5px] px-4 text-[16px] text-[#1d1b2b] outline-none focus:border-[#5b3df0] ${bad ? 'border-[#b3261e]' : 'border-[#d9d5e8]'}`;
  const fieldLabel = 'mb-1 block text-[13px] font-semibold text-[#1d1b2b]';
  const errText = 'mt-1 block text-[13px] font-semibold text-[#b3261e]';
  const h1 = 'text-[22px] font-bold text-[#1d1b2b]';
  const linkBtn = 'min-h-[44px] px-1 text-[14px] text-[#55526a]';
  const has = (p: SignupProblem) => problems.includes(p);

  const passwordInput = (id: string, label: string, autoComplete: string, onEnter: () => void, bad: boolean, placeholder?: string) => (
    <label className="block" htmlFor={id}>
      <span className={fieldLabel}>{label}</span>
      <span className="relative block">
        <input
          id={id}
          type={showPw ? 'text' : 'password'}
          autoComplete={autoComplete}
          placeholder={placeholder}
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && onEnter()}
          className={`${inputCls(bad)} pr-[72px]`}
        />
        <button type="button" onClick={() => setShowPw((v) => !v)} className="absolute right-2 top-1/2 min-h-[40px] -translate-y-1/2 px-2 text-[13px] text-[#55526a]">
          {showPw ? t.hide : t.show}
        </button>
      </span>
    </label>
  );

  const steps = (labels: string[], current: number) => (
    <p className="mb-1 text-[12.5px] font-semibold text-[#8a87a0]">
      {labels.map((l, i) => (
        <span key={l}>
          {i > 0 && ' › '}
          <span className={i === current ? 'text-[#5b3df0]' : ''}>
            {i + 1} {l}
          </span>
        </span>
      ))}
    </p>
  );

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
        <img src="/images/brand/edge-english-logo.svg" alt="엣지영어" className="mx-auto h-[36px] w-auto" />
        <p className="mt-1 text-[14px] text-[#55526a]">{t.portal}</p>
      </div>

      <main className="mt-7 w-full max-w-[400px] rounded-[22px] border border-[#e6e3ef] bg-white px-5 py-6">
        {!sb && <p className="text-[14px] text-[#b3261e]">{t.network}</p>}

        {step === 'login' && (
          <form
            onSubmit={(e) => {
              e.preventDefault();
              passwordLogin();
            }}
            className="grid gap-3"
          >
            <h1 className={h1}>{t.loginTitle}</h1>
            {isMakeupLink(next) && <p className="rounded-[12px] bg-[#efeaff] px-3.5 py-2.5 text-[13.5px] font-semibold text-[#3a22b0]">{t.makeupNext}</p>}
            {linkFor && <p className="rounded-[12px] bg-[#efeaff] px-3.5 py-2.5 text-[13.5px] font-semibold text-[#3a22b0]">{t.linkNotice(t.socialName[linkFor])}</p>}
            {social.length > 0 && !linkFor && (
              <>
                {social.map((p) => (
                  <button
                    key={p}
                    type="button"
                    disabled={busy}
                    onClick={() => socialLogin(p)}
                    className={`flex min-h-[52px] w-full items-center justify-center rounded-[14px] text-[16px] font-bold disabled:opacity-40 ${
                      p === 'kakao' ? 'bg-[#FEE500] text-[#191600]' : 'bg-[#03C75A] text-white'
                    }`}
                  >
                    {t.social[p]}
                  </button>
                ))}
                <p className="flex items-center gap-2 text-[12px] text-[#8a87a0] before:h-px before:flex-1 before:bg-[#e6e3ef] after:h-px after:flex-1 after:bg-[#e6e3ef]">{t.or}</p>
              </>
            )}
            <label className="block" htmlFor="login-email">
              <span className={fieldLabel}>{t.emailLabel}</span>
              <input
                id="login-email"
                type="email"
                inputMode="email"
                autoComplete="username"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className={inputCls(false)}
              />
            </label>
            <div>
              {passwordInput('login-password', t.passwordLabel, 'current-password', passwordLogin, badLogin)}
              {badLogin && <span className={errText}>{t.badLogin}</span>}
            </div>
            <button type="submit" disabled={busy} className={`${primary} bg-[#5b3df0]`}>
              {t.login}
            </button>
            <div className="flex flex-wrap justify-center gap-x-4">
              <button type="button" className={`${linkBtn} ${badLogin ? 'font-bold text-[#1d1b2b]' : ''}`} onClick={() => go('pw_email')}>
                {t.pwLink}
              </button>
              {!linkFor && (
                <button type="button" className={`${linkBtn} font-bold text-[#1d1b2b]`} onClick={() => { setPassword(''); go('signup'); }}>
                  {t.signupLink}
                </button>
              )}
            </div>
          </form>
        )}

        {step === 'signup' && (
          <form
            onSubmit={(e) => {
              e.preventDefault();
              signup();
            }}
            className="grid gap-3"
          >
            <div>
              {steps([t.stepInfo, t.stepMail], 0)}
              <h1 className={h1}>{t.signupTitle}</h1>
            </div>
            <label className="block" htmlFor="signup-name">
              <span className={fieldLabel}>{t.nameLabel}</span>
              <input id="signup-name" autoComplete="name" value={name} onChange={(e) => setName(e.target.value)} className={inputCls(has('name'))} />
              {has('name') && <span className={errText}>{t.nameRequired}</span>}
            </label>
            <label className="block" htmlFor="signup-email">
              <span className={fieldLabel}>{t.emailIdLabel}</span>
              <input
                id="signup-email"
                type="email"
                inputMode="email"
                autoComplete="username"
                value={email}
                onChange={(e) => {
                  setEmail(e.target.value);
                  setEmailTaken(false);
                }}
                className={inputCls(has('email') || emailTaken)}
              />
              {has('email') && <span className={errText}>{t.badEmail}</span>}
            </label>
            {emailTaken && (
              <div className="-mt-2">
                <span className={errText}>{t.emailTaken}</span>
                <button type="button" className="min-h-[40px] text-[14px] font-semibold text-[#5b3df0]" onClick={() => go('pw_email')}>
                  {t.makePwWithThis}
                </button>
              </div>
            )}
            <div>
              {passwordInput('signup-password', t.passwordLabel, 'new-password', signup, has('password'), t.pwHint(PASSWORD_MIN))}
              {has('password') && <span className={errText}>{t.pwTooShort(PASSWORD_MIN)}</span>}
            </div>
            <div className="grid gap-1">
              {(
                [
                  [terms, setTerms, t.agreeTerms, 'agree-terms'],
                  [privacy, setPrivacy, t.agreePrivacy, 'agree-privacy'],
                ] as const
              ).map(([v, set, label, id]) => (
                <label key={id} htmlFor={id} className="flex min-h-[40px] items-center gap-2.5 text-[14px] text-[#1d1b2b]">
                  <input id={id} type="checkbox" checked={v} onChange={(e) => set(e.target.checked)} className="h-[20px] w-[20px] accent-[#5b3df0]" />
                  {label}
                </label>
              ))}
              {has('agree') && <span className={errText}>{t.agreeRequired}</span>}
            </div>
            <button type="submit" disabled={busy} className={`${primary} bg-[#5b3df0]`}>
              {t.next}
            </button>
            <div className="flex justify-center gap-3 text-[14px] text-[#55526a]">
              <span className="min-h-[44px] leading-[44px]">{t.haveAccount}</span>
              <button type="button" className={`${linkBtn} font-bold text-[#1d1b2b]`} onClick={() => go('login')}>
                {t.login}
              </button>
            </div>
          </form>
        )}

        {step === 'signup_code' && (
          <div className="grid gap-3">
            <div>
              {steps([t.stepInfo, t.stepMail], 1)}
              <h1 className={h1}>{t.signupCodeTitle}</h1>
              <p className="mt-1.5 text-[13px] leading-relaxed text-[#55526a]">
                <b className="break-all text-[#1d1b2b]">{t.codeSent(maskEmail(email))}</b>
                <br />
                {t.codeLead}
              </p>
            </div>
            {codeBoxes(verifySignup, t.codeLabel)}
            <button type="button" disabled={busy || code.length !== 6} onClick={verifySignup} className={`${primary} bg-[#5b3df0]`}>
              {t.join}
            </button>
            <div className="flex justify-between">
              <button type="button" className={ghost} onClick={() => go('signup')}>
                {t.fixEmail}
              </button>
              <button type="button" className={`${ghost} disabled:opacity-50`} disabled={wait > 0 || busy} onClick={resendSignup}>
                {wait > 0 ? t.resendIn(wait) : t.resend}
              </button>
            </div>
            <p className="text-[13px] leading-relaxed text-[#55526a]">{t.spam}</p>
          </div>
        )}

        {step === 'pw_email' && (
          <form
            onSubmit={(e) => {
              e.preventDefault();
              sendPwCode();
            }}
            className="grid gap-3"
          >
            <div>
              {steps([t.stepEmail, t.stepNewPw], 0)}
              <h1 className={h1}>{t.pwTitle}</h1>
            </div>
            <label className="block" htmlFor="pw-email">
              <span className={fieldLabel}>{t.emailLabel}</span>
              <input id="pw-email" type="email" inputMode="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} className={inputCls(false)} />
            </label>
            <button type="submit" disabled={busy} className={`${primary} bg-[#5b3df0]`}>
              {t.getCode}
            </button>
            <button type="button" className={`${ghost} w-full`} onClick={() => go('login')}>
              {t.backLogin}
            </button>
          </form>
        )}

        {step === 'pw_new' && (
          <form
            onSubmit={(e) => {
              e.preventDefault();
              saveNewPassword();
            }}
            className="grid gap-3"
          >
            <div>
              {steps([t.stepEmail, t.stepNewPw], 1)}
              <h1 className={h1}>{t.newPwTitle}</h1>
              <p className="mt-1.5 text-[13px] leading-relaxed text-[#55526a]">
                <b className="break-all text-[#1d1b2b]">{t.codeSent(maskEmail(email))}</b>
                <br />
                {t.codeLead}
              </p>
            </div>
            <div>
              <span className={fieldLabel}>{t.codeLabel}</span>
              {codeBoxes(() => undefined, t.codeLabel)}
            </div>
            <input type="email" autoComplete="username" value={email} readOnly hidden />
            <div>
              {passwordInput('new-password', t.newPwLabel, 'new-password', saveNewPassword, has('password'), t.pwHint(PASSWORD_MIN))}
              {has('password') && <span className={errText}>{t.pwTooShort(PASSWORD_MIN)}</span>}
            </div>
            <button type="submit" disabled={busy || code.length !== 6} className={`${primary} bg-[#5b3df0]`}>
              {t.savePw}
            </button>
            <div className="flex justify-between">
              <button type="button" className={ghost} onClick={() => go('pw_email')}>
                {t.fixEmail}
              </button>
              <button type="button" className={`${ghost} disabled:opacity-50`} disabled={wait > 0 || busy} onClick={() => sendPwCode(true)}>
                {wait > 0 ? t.resendIn(wait) : t.resend}
              </button>
            </div>
            <p className="text-[13px] leading-relaxed text-[#55526a]">{t.spam}</p>
          </form>
        )}

        {(step === 'totp' || step === 'enroll') && (
          <div>
            <span className="mb-2.5 inline-block rounded-full bg-[#fff1d6] px-2.5 py-1 text-[12px] font-bold text-[#8a5300]">{t.adminOnly}</span>
            <h1 className={h1}>{step === 'enroll' ? t.enrollTitle : t.totpTitle}</h1>
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

        {step === 'social_choice' && (
          <div className="grid gap-3">
            <h1 className={h1}>{t.socialTitle}</h1>
            <button type="button" disabled={busy} onClick={chooseNew} className={`${primary} bg-[#5b3df0]`}>
              {t.socialNew}
            </button>
            <button type="button" disabled={busy} onClick={chooseExisting} className="flex min-h-[52px] w-full items-center justify-center rounded-[14px] border-[1.5px] border-[#5b3df0] text-[16px] font-bold text-[#5b3df0] disabled:opacity-40">
              {t.socialExisting}
            </button>
          </div>
        )}

        {step === 'member' && (
          <div className="grid gap-4">
            {joined && <p className="rounded-[12px] bg-[#e6f6ec] px-3.5 py-2.5 text-[14px] font-semibold text-[#1f7a4d]">{t.joined}</p>}
            <h1 className="text-center text-[18px] font-bold text-[#1d1b2b]">{t.memberTitle}</h1>
            <a href={APPLY_URL} target="_blank" rel="noreferrer" className="mx-auto flex min-h-[48px] w-full max-w-[240px] items-center justify-center rounded-[12px] bg-[#FFD401] text-[15px] font-bold text-[#333]">
              {t.apply}
            </a>
            <button type="button" className={`${ghost} w-full`} onClick={logout}>
              {t.logout}
            </button>
          </div>
        )}

        {step === 'moving' && <p className="text-center text-[15px] text-[#55526a]">{t.moving}</p>}

        {notice && !error && (step === 'pw_new' || step === 'signup_code') && (
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
}
