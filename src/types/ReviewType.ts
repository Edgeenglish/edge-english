export interface ReviewType {
  id: string;
  date: string; // YYYY-MM-DD
  name: string; // 가린 이름 (예: 김O수)
  job: string; // 비어 있을 수 있음
  text: string;
  highlight: string; // 대표 문장, 비어 있을 수 있음
}
