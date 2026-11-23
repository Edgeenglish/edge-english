/** 학생 영문 이름 표시 (대표 11/22): 별명이 있으면 어디서나 '영문 이름 (별명)', 없거나 같으면 영문 이름만. DB lms_tutor_student_label 과 같은 규칙 */
export function enLabel(nameEn: string | null | undefined, displayName?: string | null): string {
  const en = (nameEn ?? '').trim();
  const nick = (displayName ?? '').trim();
  return !nick || nick.toLowerCase() === en.toLowerCase() ? en : `${en} (${nick})`;
}
