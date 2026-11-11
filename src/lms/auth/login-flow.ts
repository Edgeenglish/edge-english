// 로그인 흐름 판정과 화면 문구 (POL-OP-15·POL-AC-02~05, 로그인 시안 A안 + 한·영 전환, D-39)
// H26(146)(150) 홈페이지 회원가입·로그인: 이메일(아이디) + 비밀번호 → (운영자만) 인증 앱 코드.
// 회원가입 = 이름·이메일·비밀번호·필수 동의 2개 + 메일 6자리 코드. 기존 학생·강사는 '비밀번호 만들기·찾기'(메일 코드 → 새 비밀번호).
// 카카오·네이버: 같은 인증 이메일이면 Supabase 가 기존 계정에 자동 연결, 아니면 '처음이에요 / 이미 회원이에요'.
// 화면은 이 함수 결과만 따른다. 실제 권한은 DB(RLS·is_admin 의 aal2 확인)가 막는다.

export type Lang = 'ko' | 'en';
export type Role = 'student' | 'tutor' | 'admin';

/** 코드 입력 화면에 보여 줄 가린 이메일. * 개수 = 실제로 가린 글자 수: student@gmail.com → stu****@gmail.com */
export function maskEmail(email: string): string {
  const [name, domain] = email.trim().split('@');
  if (!domain) return email;
  const shown = Math.min(3, name.length - 1); // 앞 최대 3글자, 적어도 1글자는 가림
  return `${name.slice(0, shown)}${'*'.repeat(name.length - shown)}@${domain}`;
}

export function looksLikeEmail(v: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.trim());
}

export type AfterCode =
  | { kind: 'go'; to: '/lms/student' | '/lms/tutor' | '/lms/admin' }
  | { kind: 'totp_verify' } // 운영자: 이미 등록한 인증 앱 코드 입력
  | { kind: 'totp_enroll' } // 운영자: 처음 한 번 인증 앱 등록
  | { kind: 'not_linked' }; // 로그인 계정은 있지만 수강생·강사·운영자로 연결 안 됨 (POL-AC-04)

/**
 * 메일 코드 로그인 직후 다음 단계.
 * role: 본인 역할 (DB 함수 my_role, 본인 것만). aal: 지금 세션 단계. verifiedTotp: 등록 완료된 인증 앱 수
 */
export function afterEmailCode(input: { role: Role | null; aal: 'aal1' | 'aal2'; verifiedTotp: number }): AfterCode {
  const { role, aal, verifiedTotp } = input;
  if (role === 'admin') {
    if (aal === 'aal2') return { kind: 'go', to: '/lms/admin' };
    return verifiedTotp > 0 ? { kind: 'totp_verify' } : { kind: 'totp_enroll' };
  }
  if (role === 'student') return { kind: 'go', to: '/lms/student' };
  if (role === 'tutor') return { kind: 'go', to: '/lms/tutor' };
  return { kind: 'not_linked' };
}

/**
 * 로그인 뒤 갈 곳: 바로가기 링크로 왔으면(next) 그 주소로 (11/8 보강 바로가기). 다른 사이트·다른 역할 화면으로는 보내지 않음.
 * 운영자는 수강생 보기(/lms/student?student=…)도 가능하므로 /lms/ 아래 어디든
 */
export function nextAfterLogin(next: string | null | undefined, to: string, role: Role | null): string {
  if (!next || !next.startsWith('/lms/') || next.startsWith('//') || next.includes('\\') || /[\r\n]/.test(next)) return to;
  if (role === 'admin') return next;
  return next === to || next.startsWith(`${to}?`) || next.startsWith(`${to}/`) ? next : to;
}
/** 바로가기 링크로 들어와 로그인하는 중인지 (로그인 화면 안내 한 줄) */
export const isMakeupLink = (next: string | null | undefined) => !!next && next.startsWith('/lms/student') && /[?&]makeup=/.test(next);

/** 비밀번호 최소 글자 수 (대표 결정 H26(150) ③) */
export const PASSWORD_MIN = 8;

export type SignupInput = { name: string; email: string; password: string; terms: boolean; privacy: boolean };
export type SignupProblem = 'name' | 'email' | 'password' | 'agree';
/** 회원가입 입력 검사 — 칸마다 첫 문제 하나 (입력칸 바로 아래에 보여 줌) */
export function signupProblems(v: SignupInput): SignupProblem[] {
  const out: SignupProblem[] = [];
  if (!v.name.trim()) out.push('name');
  if (!looksLikeEmail(v.email)) out.push('email');
  if (v.password.length < PASSWORD_MIN) out.push('password');
  if (!v.terms || !v.privacy) out.push('agree');
  return out;
}

export type SocialProvider = 'kakao' | 'naver';
/** Supabase 공급자 이름. 네이버는 기본 지원이 없어 직접 연결(custom OAuth) 이름 */
export const PROVIDER_ID: Record<SocialProvider, string> = { kakao: 'kakao', naver: 'custom:naver' };
/**
 * 켜진 간편 로그인만 버튼으로 (꺼진 버튼은 보이지 않게).
 * 카카오 = /auth/v1/settings 의 external.kakao. 네이버(직접 연결)는 settings 에 안 나와서
 * /auth/v1/authorize?provider=custom:naver 가 넘겨 주면(302) 켜진 것으로 본다 (없으면 400 'not found').
 */
export function enabledSocial(external: Record<string, boolean> | null | undefined, naverOn = false): SocialProvider[] {
  const out: SocialProvider[] = [];
  if (external?.kakao) out.push('kakao');
  if (naverOn) out.push('naver');
  return out;
}

/**
 * 카카오·네이버로 로그인했는데 엣지영어 회원(학생·강사·운영자)과 연결이 없을 때 '처음이에요 / 이미 회원이에요'를 물을지.
 * 이메일·비밀번호 계정이 함께 있으면(같은 인증 이메일로 자동 연결됐거나 직접 가입) 묻지 않음. 한 번 '처음이에요'를 고르면 다시 묻지 않음.
 */
export function needsSocialChoice(input: { role: Role | null; providers: string[]; choseNew: boolean }): boolean {
  if (input.role || input.choseNew) return false;
  const social = input.providers.filter((p) => p !== 'email');
  return social.length > 0 && !input.providers.includes('email');
}

/** 코드 다시 보내기 대기 시간(초) — Supabase 이메일 최소 발송 간격과 같게 */
export const RESEND_WAIT_SECONDS = 60;

export const STRINGS = {
  ko: {
    portal: '수업 관리',
    loginTitle: '로그인',
    emailLabel: '이메일',
    passwordLabel: '비밀번호',
    show: '보기',
    hide: '숨기기',
    login: '로그인',
    badLogin: '이메일 또는 비밀번호가 맞지 않아요',
    pwLink: '비밀번호 만들기·찾기',
    signupLink: '회원가입',
    social: { kakao: '카카오로 로그인', naver: '네이버로 로그인' },
    socialName: { kakao: '카카오', naver: '네이버' },
    or: '또는',
    signupTitle: '회원가입',
    nameLabel: '이름',
    emailIdLabel: '이메일 (아이디)',
    pwHint: (n: number) => `${n}자 이상`,
    agreeTerms: '이용약관 동의 (필수)',
    agreePrivacy: '개인정보 수집·이용 동의 (필수)',
    next: '다음',
    haveAccount: '이미 회원이에요',
    stepInfo: '정보 입력',
    stepMail: '메일 확인',
    nameRequired: '이름을 넣어 주세요',
    badEmail: '이메일 주소를 다시 확인해 주세요',
    pwTooShort: (n: number) => `비밀번호는 ${n}자 이상이에요`,
    agreeRequired: '필수 동의를 체크해 주세요',
    emailTaken: '이미 가입된 이메일이에요',
    makePwWithThis: '이 이메일로 비밀번호 만들기 ›',
    signupCodeTitle: '메일로 받은 코드',
    join: '가입하기',
    fixEmail: '‹ 이메일 고치기',
    pwTitle: '비밀번호 만들기·찾기',
    stepEmail: '이메일',
    stepNewPw: '새 비밀번호',
    getCode: '코드 받기',
    newPwTitle: '새 비밀번호',
    codeLabel: '메일로 받은 코드',
    newPwLabel: '새 비밀번호',
    savePw: '저장하고 로그인',
    backLogin: '‹ 로그인',
    codeSent: (masked: string) => `${masked} 으로 보냈어요.`,
    codeLead: '1분 안에 도착해요. (10분 동안 유효)',
    resend: '코드 다시 받기',
    resendIn: (s: number) => `코드 다시 받기 (${s}초)`,
    resent: '코드를 다시 보냈어요.',
    spam: '메일이 안 보이면 스팸함도 확인해 주세요.',
    badCode: '코드가 맞지 않거나 시간이 지났어요. 다시 확인하거나 새 코드를 받아 주세요.',
    tooMany: '요청이 많아요. 잠시 뒤에 다시 해 주세요.',
    network: '연결이 불안정해요. 잠시 뒤에 다시 해 주세요.',
    adminOnly: '운영자만',
    totpTitle: '인증 앱 코드',
    totpLead: 'Google Authenticator 등 인증 앱에 보이는 6자리 숫자를 넣어 주세요. 이 기기에서는 로그아웃할 때까지 다시 묻지 않아요.',
    confirm: '확인',
    lostPhone: '휴대폰을 잃어버렸어요',
    lostPhoneHelp: '대표 계정은 Supabase 관리 화면에서 인증 앱을 지운 뒤 다시 등록해요. 직원은 대표에게 요청해 주세요.',
    enrollTitle: '인증 앱 등록 (처음 한 번)',
    enrollLead: '① 휴대폰에 Google Authenticator 설치 → ② 앱에서 + → QR 코드 스캔 → ③ 앱에 보이는 6자리 입력',
    enrollManual: 'QR이 안 되면 이 코드를 앱에 직접 입력',
    enrollDone: '등록 완료',
    enrollTip: '복구 코드가 없어요. 휴대폰·태블릿 2대에 함께 등록해 두는 것을 권해요.',
    joined: '가입했어요',
    memberTitle: '아직 수강 중인 수업이 없어요',
    apply: '수강신청',
    socialTitle: '엣지영어가 처음이세요?',
    socialNew: '처음이에요',
    socialExisting: '이미 회원이에요',
    linkNotice: (p: string) => `기존 계정으로 로그인하면 ${p}가 연결돼요.`,
    linkFail: '연결하지 못했어요. 이메일로 로그인해 주세요.',
    socialFail: '로그인하지 못했어요. 이메일로 로그인해 주세요.',
    logout: '로그아웃',
    moving: '이동하는 중…',
    backHome: '← 홈페이지로',
    makeupNext: '로그인하면 링크의 보강 날짜 고르기로 바로 이어져요.',
  },
  en: {
    portal: 'Class portal',
    loginTitle: 'Log in',
    emailLabel: 'Email',
    passwordLabel: 'Password',
    show: 'Show',
    hide: 'Hide',
    login: 'Log in',
    badLogin: 'Email or password is incorrect',
    pwLink: 'Set or reset password',
    signupLink: 'Sign up',
    social: { kakao: 'Continue with Kakao', naver: 'Continue with Naver' },
    socialName: { kakao: 'Kakao', naver: 'Naver' },
    or: 'or',
    signupTitle: 'Sign up',
    nameLabel: 'Name',
    emailIdLabel: 'Email (your ID)',
    pwHint: (n: number) => `At least ${n} characters`,
    agreeTerms: 'I agree to the Terms of Use (required)',
    agreePrivacy: 'I agree to the collection and use of personal data (required)',
    next: 'Next',
    haveAccount: 'Already a member?',
    stepInfo: 'Your details',
    stepMail: 'Email check',
    nameRequired: 'Please enter your name',
    badEmail: 'Please check the email address',
    pwTooShort: (n: number) => `Use at least ${n} characters`,
    agreeRequired: 'Please tick the required boxes',
    emailTaken: 'This email is already registered',
    makePwWithThis: 'Set a password for this email ›',
    signupCodeTitle: 'Code from your email',
    join: 'Sign up',
    fixEmail: '‹ Change email',
    pwTitle: 'Set or reset password',
    stepEmail: 'Email',
    stepNewPw: 'New password',
    getCode: 'Send code',
    newPwTitle: 'New password',
    codeLabel: 'Code from your email',
    newPwLabel: 'New password',
    savePw: 'Save and log in',
    backLogin: '‹ Log in',
    codeSent: (masked: string) => `Sent to ${masked}.`,
    codeLead: 'It arrives within a minute. (Valid for 10 minutes)',
    resend: 'Send a new code',
    resendIn: (s: number) => `Send a new code (${s}s)`,
    resent: 'We sent a new code.',
    spam: "Can't find it? Check your spam folder.",
    badCode: 'The code is wrong or has expired. Check it or get a new code.',
    tooMany: 'Too many requests. Please try again shortly.',
    network: 'Connection problem. Please try again shortly.',
    adminOnly: 'Admins only',
    totpTitle: 'Authenticator code',
    totpLead: "Enter the 6 digits shown in your authenticator app. You won't be asked again on this device until you log out.",
    confirm: 'Confirm',
    lostPhone: 'I lost my phone',
    lostPhoneHelp: 'The owner removes the authenticator in the Supabase dashboard and registers again. Staff: ask the owner.',
    enrollTitle: 'Set up authenticator (once)',
    enrollLead: '1) Install Google Authenticator 2) Tap + and scan the QR code 3) Enter the 6 digits shown',
    enrollManual: "If the QR doesn't work, enter this key in the app",
    enrollDone: 'Finish setup',
    enrollTip: 'There are no recovery codes. Register it on two devices (phone + tablet).',
    joined: "You're signed up",
    memberTitle: 'No classes yet',
    apply: 'Apply for classes',
    socialTitle: 'New to Edge English?',
    socialNew: "Yes, I'm new",
    socialExisting: 'I already have an account',
    linkNotice: (p: string) => `Log in with your account to connect ${p}.`,
    linkFail: "Couldn't connect. Please log in with your email.",
    socialFail: "Couldn't log in. Please log in with your email.",
    logout: 'Log out',
    moving: 'Redirecting…',
    backHome: '← Home page',
    makeupNext: 'After you log in, the make-up date page from your link opens.',
  },
} as const;
