import type { SupabaseClient } from '@supabase/supabase-js';

// 처리 내역 (migration 3900 + 4520): [처리 종료]한 카드 · 종료일 3일 지나 자동 제외된 카드 · [수강 종료]한 수강권 · 시트 [대조 완료](R-06). 다시 열기는 기존 함수
export type HistoryRow = {
  source: 'closed' | 'auto' | 'enrollment' | 'checked';
  kind: string;
  taskId: string;
  signature: string;
  at: Date | null;
  by: string | null;
  name: string | null;
};

export const HISTORY_STATUS: Record<HistoryRow['source'], string> = { closed: '카드 닫음', auto: '자동 제외', enrollment: '수강 종료', checked: '대조 완료' };
export const HISTORY_REASON: Record<HistoryRow['source'], string> = { closed: '운영진이 종료', auto: '종료일 3일 지남', enrollment: '재등록 안 함', checked: '운영진이 시트와 대조 완료로 기록' };
export const TASK_KIND_TEXT: Record<string, string> = {
  new_student_matching: '신규 매칭', renewal_tutor_notice: '재등록 강사 확인', long_leave_request: '장기 연기', no_show_report: '노쇼 신고',
  ending_soon: '수강기간 종료 임박', makeup_unrequested: '보강 미신청', auto_failure: '자동 처리 오류', import_check: '시트 대조',
  lesson_change: '수업 변경', tutor_leave: '강사 휴무', class_record_missing: 'Class Record 미기록', extension_review: '예외 연장 검토',
};

export async function loadTaskHistory(sb: SupabaseClient): Promise<HistoryRow[]> {
  const { data, error } = await sb.rpc('admin_task_history');
  if (error) throw new Error('처리 내역을 읽지 못했어요.');
  return ((data ?? []) as { source: HistoryRow['source']; kind: string; task_id: string; signature: string; at: string | null; by: string | null; name: string | null }[])
    // [카드 닫기] 없앰 (대표 11/9): 예전에 닫은 카드는 이제 숨기지 않으므로 내역에서도 뺌. 예외 연장 검토 [연장 안 함]만 남김
    .filter((r) => r.source !== 'closed' || r.kind === 'extension_review')
    .map((r) => ({ source: r.source, kind: r.kind, taskId: r.task_id, signature: r.signature, at: r.at ? new Date(r.at) : null, by: r.by, name: r.name }));
}

/** 다시 열기: 카드 닫음·자동 제외 = admin_set_task_closed(false), 수강 종료 = admin_enrollment_close(undo), 대조 완료 = admin_import_unmark_checked (대조 전으로, 4520) */
export async function reopenTask(sb: SupabaseClient, r: HistoryRow): Promise<void> {
  const { error } = r.source === 'enrollment'
    ? await sb.rpc('admin_enrollment_close', { p_enrollment: r.taskId, p_undo: true })
    : r.source === 'checked'
      ? await sb.rpc('admin_import_unmark_checked', { p_enrollment: r.taskId })
      : await sb.rpc('admin_set_task_closed', { p_kind: r.kind, p_id: r.taskId, p_signature: r.signature, p_closed: false });
  if (error) throw new Error('다시 열지 못했어요.');
}
