// 로그인 흐름 판정과 화면 문구 (POL-OP-15·POL-AC-02~05, 로그인 시안 A안 + 한·영 전환, D-39)
// 순서: 이메일 → 메일 6자리 코드 → (운영자만) 인증 앱 코드. 비밀번호 없음, 공개 가입 없음.
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
  | { kind: 'not_linked' }; // 로그인 계정은 있지만 학생·강사·운영자로 연결 안 됨 (POL-AC-04)

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

/** 코드 다시 보내기 대기 시간(초) — Supabase 이메일 최소 발송 간격과 같게 */
export const RESEND_WAIT_SECONDS = 60;

export const STRINGS = {
  ko: {
    portal: '수업 관리',
    loginTitle: '로그인',
    loginLead: '등록하신 이메일로 6자리 코드를 보내 드려요.',
    emailLabel: '이메일 주소',
    sendCode: '코드 받기',
    noPassword: '비밀번호는 없어요. 엣지영어에 등록한 이메일을 넣어 주세요.',
    contact: '문의: 카카오톡 채널 엣지영어',
    badEmail: '이메일 주소를 다시 확인해 주세요.',
    codeTitle: '코드 입력',
    codeSent: (masked: string) => `${masked} 으로 보냈어요.`,
    codeLead: '등록된 이메일이면 1분 안에 도착해요. (10분 동안 유효)',
    codeLabel: '6자리 코드',
    login: '로그인',
    changeEmail: '이메일 바꾸기',
    resend: '다시 보내기',
    resendIn: (s: number) => `다시 보내기 (${s}초)`,
    resent: '코드를 다시 보냈어요.',
    spam: '메일이 안 보이면 스팸함도 확인해 주세요. 제목: 엣지영어 로그인 코드',
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
    notLinkedTitle: '아직 연결되지 않은 계정이에요',
    notLinkedLead: '엣지영어 운영자가 등록을 마치면 이용할 수 있어요. 카카오톡 채널로 문의해 주세요.',
    logout: '로그아웃',
    moving: '이동하는 중…',
    backHome: '← 홈페이지로',
  },
  en: {
    portal: 'Class portal',
    loginTitle: 'Log in',
    loginLead: "We'll email a 6-digit code to your registered address.",
    emailLabel: 'Email address',
    sendCode: 'Send code',
    noPassword: 'No password needed. Use the email registered with Edge English.',
    contact: 'Questions: WhatsApp Edge English',
    badEmail: 'Please check the email address.',
    codeTitle: 'Enter code',
    codeSent: (masked: string) => `Sent to ${masked}.`,
    codeLead: 'If the email is registered, it arrives within a minute. (Valid for 10 minutes)',
    codeLabel: '6-digit code',
    login: 'Log in',
    changeEmail: 'Change email',
    resend: 'Resend',
    resendIn: (s: number) => `Resend (${s}s)`,
    resent: 'We sent a new code.',
    spam: "Can't find it? Check your spam folder. Subject: 엣지영어 로그인 코드",
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
    notLinkedTitle: 'This account is not linked yet',
    notLinkedLead: 'You can use it once Edge English finishes your registration. Please contact us.',
    logout: 'Log out',
    moving: 'Redirecting…',
    backHome: '← Home page',
  },
} as const;
