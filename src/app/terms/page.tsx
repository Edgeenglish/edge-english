import type { Metadata } from 'next';
import LegalDoc from '@/components/legal/LegalDoc';
import { TERMS } from '@/lms/auth/legal';

export const metadata: Metadata = { title: '이용약관' };

export default function TermsPage() {
  return <LegalDoc title="이용약관" sections={TERMS} />;
}
