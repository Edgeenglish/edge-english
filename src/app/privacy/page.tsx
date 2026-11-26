import type { Metadata } from 'next';
import LegalDoc from '@/components/legal/LegalDoc';
import { PRIVACY_POLICY } from '@/lms/auth/legal';

export const metadata: Metadata = { title: '개인정보 처리방침' };

export default function PrivacyPage() {
  return (
    <LegalDoc
      title="개인정보 처리방침"
      intro="탠저린 영어(이하 '회사')는 개인정보 보호법에 따라 회원의 개인정보를 다음과 같이 처리합니다."
      sections={PRIVACY_POLICY}
    />
  );
}
