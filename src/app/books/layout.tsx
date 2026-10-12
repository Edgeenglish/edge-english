import type { Metadata } from 'next';

export const metadata: Metadata = { title: '교재 소개' };

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
