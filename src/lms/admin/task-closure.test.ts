import { describe, expect, it } from 'vitest';
import { fakeTasks } from './fake-data';
import { filterActionableTasks, filterClosedTasks, taskSignature } from './task-closure';
import type { TaskSource } from './board';

const now = new Date('2026-11-02T00:00:00Z');
describe('운영진 업무 종료', () => {
  it('모든 종류 카드는 저장한 서명이 같으면 제외된다', () => {
    const tasks = fakeTasks(now);
    const closures = tasks.map((t) => ({ task_kind: t.kind, task_id: t.id, signature: taskSignature(t) }));
    expect(filterClosedTasks(tasks, closures)).toEqual([]);
    expect(filterClosedTasks(tasks, [])).toEqual(tasks);
  });
  it('재등록 횟수 변화는 종료를 유지하고 새 등록은 별개다', () => {
    const t = fakeTasks(now).find((t) => t.kind === 'ending_soon')!;
    const closure = [{ task_kind: t.kind, task_id: t.id, signature: taskSignature(t) }];
    expect(filterClosedTasks([{ ...t, lessonsLeft: 0 } as TaskSource], closure)).toEqual([]);
    expect(filterClosedTasks([{ ...t, id: 'next' }], closure)).toHaveLength(1);
  });
  it('강사 기록 누락에 새 수업이 추가되면 다시 표시된다', () => {
    const t: TaskSource = { kind: 'class_record_missing', id: 't1', tutorName: 'Emma', createdAt: now, lessons: [{ studentName: '김하준', startsAt: now }] };
    const c = [{ task_kind: t.kind, task_id: t.id, signature: taskSignature(t) }];
    expect(filterClosedTasks([{ ...t, lessons: [...t.lessons, { studentName: '박서연', startsAt: now }] }], c)).toHaveLength(1);
  });
  it('학생·강사 답만 기다리면 제외, 운영 확정·문의·안내는 유지', () => {
    const t: TaskSource = { kind: 'lesson_change', id: 's1', studentName: '김하준', studentCode: 'STU-001', createdAt: now, lessonAt: null, pendingNotices: 0, openMakeups: 1 };
    expect(filterActionableTasks([t])).toEqual([]);
    expect(filterActionableTasks([{ ...t, answeredMakeups: 1 }])).toHaveLength(1);
    expect(filterActionableTasks([{ ...t, pendingNotices: 1 }])).toHaveLength(1);
    const leave: TaskSource = { kind: 'tutor_leave', id: 'off', tutorName: 'Emma', from: '2026-11-02', to: '2026-11-03', undecidedStudents: 0, tutorReply: 1, studentReply: 1, pendingNotices: 0, firstOpenAt: now, createdAt: now };
    expect(filterActionableTasks([leave])).toEqual([]);
    expect(filterActionableTasks([{ ...leave, undecidedStudents: 1 }])).toHaveLength(1);
    expect(filterActionableTasks([{ ...leave, pendingNotices: 1 }])).toHaveLength(1);
  });
});
