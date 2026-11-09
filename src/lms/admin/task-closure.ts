import type { SupabaseClient } from '@supabase/supabase-js';
import type { TaskSource } from './board';

export type TaskClosure = { task_kind: string; task_id: string; signature: string };

// 정렬 순서만 달라진 응답은 같은 업무로 본다. 새 수업·안내가 생기면 다시 표시한다.
function canonical(value: unknown): unknown {
  if (value instanceof Date) return value.toISOString();
  if (Array.isArray(value)) return value.map(canonical).sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, canonical(v)]));
  return value;
}

export function taskSignature(task: TaskSource): string {
  // 같은 수강등록은 남은 횟수·안내 여부가 바뀌어도 수동 종료를 유지한다.
  return task.kind === 'ending_soon' ? task.id : JSON.stringify(canonical(task));
}

export function filterClosedTasks(tasks: TaskSource[], closures: TaskClosure[]): TaskSource[] {
  const closed = new Map(closures.map((c) => [`${c.task_kind}:${c.task_id}`, c.signature]));
  return tasks.filter((t) => closed.get(`${t.kind}:${t.id}`) !== taskSignature(t));
}

/** 운영진의 조치가 있는 카드만. 답을 기다리는 상태는 각 업무 화면에서 확인한다. */
export function filterActionableTasks(tasks: TaskSource[]): TaskSource[] {
  return tasks.filter((t) => {
    // 자동 메일 못 보냄(만료 메일 포함)도 운영진이 직접 보내야 하는 일 (11/9)
    if (t.kind === 'lesson_change') return t.pendingNotices > 0 || (t.answeredMakeups ?? 0) > 0 || (t.emailFailed ?? 0) > 0;
    if (t.kind === 'tutor_leave') {
      const steps = t.noticeSteps;
      const readyNotices = steps ? steps.tutor + steps.confirm + (steps.proposeStudents?.length ?? 0) : t.pendingNotices;
      return t.undecidedStudents > 0 || readyNotices > 0;
    }
    // 재등록: 열린 업무는 늘 운영진 차례(새 기간 일정 확정 또는 강사에게 통보) — 통보하면 업무가 끝나 목록에서 빠짐 (11/9 A안)
    return true;
  });
}

export async function saveTaskClosure(sb: SupabaseClient, task: TaskSource, closed: boolean): Promise<void> {
  const { error } = await sb.rpc('admin_set_task_closed', {
    p_kind: task.kind, p_id: task.id, p_signature: taskSignature(task), p_closed: closed,
  });
  if (error) throw new Error('카드 닫기를 저장하지 못했어요. 다시 시도해 주세요.');
}
