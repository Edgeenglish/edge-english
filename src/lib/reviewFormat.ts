import { ReviewType } from '@/types/ReviewType';

// 이름 중간 글자 가리기: 김민 → 김O, 김민수 → 김O수, 남궁민수 → 남OO수
export function maskName(raw: string) {
  const chars = Array.from(raw.replace(/\s+/g, ''));
  if (chars.length <= 1) return chars.join('');
  if (chars.length === 2) return chars[0] + 'O';
  return chars[0] + 'O'.repeat(chars.length - 2) + chars[chars.length - 1];
}

// 후기 본문에 섞인 전화번호·이메일 가리기
export function maskContact(text: string) {
  return text
    .replace(/01[016789][-.\s]?\d{3,4}[-.\s]?\d{4}/g, '010-****-****')
    .replace(/[\w.+-]+@[\w-]+(\.[\w-]+)+/g, '***@***');
}

// 카드 하단 표시 이름: "직장인 김O수 님" / "김O수 님"
export function displayName(review: ReviewType) {
  return `${review.job ? `${review.job} ` : ''}${review.name} 님`;
}

// 2026-10-12 → 2026.10.12
export function displayDate(date: string) {
  return date.replaceAll('-', '.');
}
