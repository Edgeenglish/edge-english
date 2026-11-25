import type { Metadata } from 'next';
import LevelTest from './LevelTest';

export const metadata: Metadata = {
  title: '무료 레벨테스트',
  description: '20문제·약 10분, 내 영어 레벨과 부족한 부분을 무료로 확인해 보세요.',
};

export default function LevelTestPage() {
  return <LevelTest />;
}
