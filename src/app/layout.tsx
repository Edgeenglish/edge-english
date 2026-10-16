import type { Metadata } from 'next';
import './globals.css';
import Header from '@/components/Header';
import Footer from '@/components/Footer';
import FloatingMenu from '@/components/FloatingMenu';
import SiteChrome from '@/components/SiteChrome';

export const metadata: Metadata = {
  title: { default: '엣지영어', template: '%s | 엣지영어' },
  description: '영어 교육 전문가들이 만든 원어민 화상영어 브랜드입니다.',
  keywords: [
    '엣지영어',
    '엣지 영어',
    '화상 영어',
    'edge english',
    '엣지영어 사이트',
    'edge',
    'english',
    'edgeenglish',
    '화상영어',
    '화상영어플랫폼',
    '원어민화상영어',
    '탠저린',
    '시에나',
  ],
  openGraph: {
    type: 'website',
    siteName: '엣지영어',
    title: '엣지영어',
    description: '영어 교육 전문가들이 만든 원어민 화상영어 브랜드입니다.',
    images: ['https://edgeenglish.kr/images/og-image.png'],
    url: 'https://edgeenglish.kr',
  },
  twitter: {
    card: 'summary',
    title: '엣지영어',
    description: '영어 교육 전문가들이 만든 원어민 화상영어 브랜드입니다.',
    images: ['https://edgeenglish.kr/images/og-image.png'],
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="ko" data-theme="light">
      <body>
        <SiteChrome>
          <Header />
        </SiteChrome>

        <main>{children}</main>

        <SiteChrome>
          <FloatingMenu />
          <Footer />
        </SiteChrome>
      </body>
    </html>
  );
}
