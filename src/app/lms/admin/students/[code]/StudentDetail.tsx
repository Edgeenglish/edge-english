'use client';

// 운영진 수강생 상세 (H26(44) ①~⑤, migration 4300): 정규 일정 · 수강 · 프로필 · 자기소개/선호 7항목 · 운영진만(결제·메모) · 수업 · 변경 기록·안내
// 시간은 모두 '한국 시간 · 수강생 도시 시간 · 강사 도시 시간' 이름과 같이, 실제 수업 날짜로 계산 (H26(43))
import Link from 'next/link';
import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { diffDays, instantToKstDate, type KstDate } from '@/lms/rules/dates';
import {
  dateOptions, finalEndText, KIND_KO, koZone, kstWithZones, md, mdw, productText, regularNoticeEn, regularNoticeKo, slotsInZone, slotsText, STATUS_TEXT, zoneLabel,
  type RegularPreview, type Slot, type StudentDetailData, type StudentProfile, type StudentStatus,
} from '@/lms/admin/students';
import { AdminHeader, BottomNav, Icon } from '../../ui';
import { styleText } from '@/lms/tutor/followup';
import { Box, btnMain, btnSmall, btnSub, CopyButton, input, label, Row, Sheet, WHO_ROLE } from './parts';
import RegularChange from './RegularChange';
import PrestartMove from './PrestartMove';
import LessonManage, { type LessonManageActions } from './LessonManage';
import { Rich } from '@/app/lms/Rich';
import { CarrySheet, RenewSheet, RewardRows, RewardSheet, type RenewalActions } from './Renewal';
import type { RenewalContext, Rewards } from '@/lms/admin/renewal';

export type DetailActions = {
  reload: () => Promise<void>;
  update: (fields: Record<string, string | null>) => Promise<number>;
  preview: (slots: Slot[], from: KstDate) => Promise<RegularPreview>;
  save: (slots: Slot[], from: KstDate, reason: string) => Promise<{ changeId: string; moved: number }>;
  sent: (changeId: string, who: 'student' | 'tutor', undo?: boolean) => Promise<void>;
  extend: (enrollmentId: string, newEnd: KstDate, kind: 'student_long_term_leave' | 'admin_exception' | 'correction', note: string) => Promise<{ finalEndDate: KstDate; days: number }>;
  /** 첫 수업 시작 전 개별 수업 날짜 변경 (변경권 차감 없음, H26(62)) */
  prestart: (lessonId: string, startsAt: string) => Promise<unknown>;
  prestartMoved: () => Promise<Record<string, string>>;
  /** 보강·보상수업 추가·수정 (20261109040000) */
  lessonManage: LessonManageActions;
};

const won = (n: number) => `${n.toLocaleString('ko-KR')}원`;
export const LEVELS = ['Beginner', 'Pre-Intermediate', 'Intermediate', 'Advanced'] as const;
export const CORRECTION: Record<string, string> = { immediate: '바로바로 교정', major_only: '큰 실수 위주만 교정' };
export const CLASS_STYLE: Record<string, string> = { textbook: '교재', free_talking: '프리토킹', not_sure: '아직 잘 모르겠음' };
const EXT_REASON: Record<string, string> = { student_long_term_leave: '수강생 장기 사정', tutor_long_term_leave: '강사 휴무 자동', admin_exception: '운영 예외', correction: '정정', tutor_fault: '강사 귀책 자동' };
const FIELD_KO: Record<string, string> = {
  name_ko: '한국 이름', name_en: '영문 이름', display_name: 'Preferred Name', country: '국가', city: '도시', timezone: '시간대', gender_age: '성별/연령대', email: '이메일', phone: '휴대폰',
  level: '레벨', level_note: '예전 레벨 표기', class_type: 'Type of class', textbook: '교재', class_note_url: 'Google Docs', admin_memo: '운영 메모', self_intro_en: '기존 자기소개', correction_pref: '교정 선호(시트)',
  job: '직업', hobbies: '취미', interests: '관심사', improve: '개선하고 싶은 부분', hopes: '바라는 점·분위기', correction_style: '선호 교정 방식', correction_note: '교정 설명', class_style: '선호 수업 스타일', class_style_note: '스타일 설명',
};
const STATUS_STYLE: Record<StudentStatus, string> = { active: 'bg-[#e3f5ea] text-[#13623a]', upcoming: 'bg-[#efebff] text-[#5b3fe0]', pending: 'bg-[#fff1d6] text-[#8a5300]', ended: 'bg-[#f0eef6] text-[#6b6880]', none: 'bg-[#fff1d6] text-[#8a5300]' };
const NA = <i className="text-[#b9b6c8]">미응답</i>;
const or = (v: string | null | undefined, fallback: ReactNode = <i className="text-[#b9b6c8]">없음</i>) => (v ? v : fallback);

/** 재등록·보강 이월·적립금 (20261109130000). DB 에 아직 없으면 null → 그 칸·버튼을 안 보임 */
export type RenewalExtra = { ctx: RenewalContext | null; rewards: Rewards | null; actions: RenewalActions };

export default function StudentDetail({ data, nowIso, actions, extra }: { data: StudentDetailData; nowIso: string; actions: DetailActions; extra?: RenewalExtra }) {
  const now = useMemo(() => new Date(nowIso), [nowIso]);
  const today = instantToKstDate(now);
  const s = data.student;
  const e = data.enrollment;
  const slot = data.slots[0] ?? null;
  // 결제 확인 전(pending_payment)은 수업·일정이 없으므로 '수강 예정·0/4회'가 아니라 '결제 확인 전 · 강사 배정 전'으로 (QA B-01)
  const status: StudentStatus = !e ? 'none' : e.status === 'completed' || e.status === 'canceled' || e.finalEndDate < today ? 'ended' : e.status === 'pending_payment' ? 'pending' : e.startDate > today ? 'upcoming' : 'active';
  const pending = status === 'pending';
  const [sheet, setSheet] = useState<null | 'profile' | 'answers' | 'regular' | 'extend' | 'prestart' | 'renew' | 'carry' | 'reward_in' | 'reward_out' | { notice: string }>(null);
  const [flash, setFlash] = useState('');
  const ctx = extra?.ctx ?? null;
  const nx = ctx?.next ?? null;
  const who = { id: s.id, code: s.code ?? '', name: s.nameKo ?? s.nameEn, timezone: s.timezone };
  // 재등록 넣기: 다음 수강권이 아직 없으면 항상 (수강기간과 관계없이). 대시보드 [재등록 넣기]는 ?renew=1 로 바로 열림
  const canRenew = !!ctx?.prev && !nx && !pending;
  // 입력 중에 화면이 새로고침·재실행되면(휴대폰 앱 전환 뒤 등) 임시 저장한 입력이 있는 창을 다시 열어 줌 (2026-11-06 대표 보고: 프로필 수정 중 창이 닫힘)
  useEffect(() => {
    if (readDraft(s.id, '프로필 수정')) setSheet('profile');
    else if (readDraft(s.id, '자기소개 · 수업 선호 (수강생 답 입력)')) setSheet('answers');
    else if (new URLSearchParams(window.location.search).get('renew') === '1' && canRenew) setSheet('renew');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [s.id]);
  // 첫 수업 시작 전: 이 수강권의 정규 수업이 모두 아직 앞으로 남아 있을 때만 (시작 뒤는 수업 변경·변경권 절차)
  const regularAhead = data.upcoming.filter((l) => l.kind === 'regular' && !l.substitute && !l.leaveOpen);
  const prestartOpen = !!e && (e.status === 'confirmed' || e.status === 'active') && regularAhead.length > 0 && regularAhead.length >= e.lessonsPurchased;
  const pendingChanges = data.changes.filter((c) => !c.studentSentAt || !c.tutorSentAt);
  const autoExt = e ? e.extensions.filter((x) => x.auto === 'leave_makeup').reduce((a, x) => a + x.days, 0) : 0;
  // 강사 귀책 자동 연장 (H26(92), 20261108020000): 마지막 줄 메모에 '강사 휴무 n · 노쇼 n'
  const faultRows = e ? e.extensions.filter((x) => x.auto === 'fault') : [];
  const faultExt = faultRows.reduce((a, x) => a + x.days, 0);
  const faultWhy = faultRows.at(-1)?.note?.match(/강사 휴무 (\d+) · 노쇼 (\d+)/);
  const faultText = faultWhy ? [Number(faultWhy[1]) ? `강사 휴무 ${faultWhy[1]}` : '', Number(faultWhy[2]) ? `노쇼 ${faultWhy[2]}` : ''].filter(Boolean).join(' · ') : '';
  const manualExt = e ? e.extensions.filter((x) => !x.auto).reduce((a, x) => a + x.days, 0) : 0;

  return (
    <div className="mx-auto min-h-dvh max-w-[1280px] pb-24 lg:pb-8">
      <AdminHeader active="students" demo={false} />
      <div className="grid gap-3 px-4 pt-3 lg:px-7">
        <Link href="/lms/admin/students" className="flex min-h-[36px] w-fit items-center gap-1 text-[13px] font-semibold text-[#5b3fe0]">
          <Icon name="chevron" className="h-4 w-4 rotate-180" /> 수강생 목록
        </Link>

        <div className="flex flex-wrap items-center gap-3 rounded-[16px] bg-[#1b1442] px-4 py-4 text-white">
          <span className="flex h-12 w-12 items-center justify-center rounded-full bg-[#2c2263] text-[18px] font-bold text-white">{(s.nameKo ?? s.nameEn).slice(-1)}</span>
          <div className="min-w-0 flex-1">
            <p className="text-[20px] font-bold text-white">
              {s.nameKo} <span className="text-[14px] font-normal text-[#c9c0ff]">({s.nameEn}{s.displayName && s.displayName.toLowerCase() !== s.nameEn.toLowerCase() ? ` · "${s.displayName}"` : ''}) · {s.code}</span>
              <span className={`ml-2 rounded-full px-2 py-0.5 align-middle text-[11.5px] font-bold ${STATUS_STYLE[status]}`}>{STATUS_TEXT[status]}</span>
            </p>
            <p className="text-[13px] text-[#d8d3f5]">
              {productText(e)}{pending ? ' · 결제 확인 전 · 강사 배정 전' : slot ? ` · ${slot.tutor}${slot.tutorCountry ? ` (${slot.tutorCountry})` : ''}` : e ? ' · 강사 배정 전' : ''}
            </p>
          </div>
          {e && (
            <div className="grid grid-cols-3 gap-2 text-center">
              {(pending
                ? [
                    ['수업', `결제 확인 후 ${e.lessonsPurchased}회 생성`],
                    ['강사', '배정 전'],
                    ['희망 시작', md(e.startDate)],
                  ]
                : [
                ['남은 정규', `${e.leftRegular}/${e.lessonsPurchased}`],
                ['이월', `${e.lessonsCarriedIn}회`],
                ['최종 종료', status === 'ended' ? md(e.finalEndDate) : `${md(e.finalEndDate)} (D-${Math.max(0, diffDays(today, e.finalEndDate))})`],
              ]).map(([k, v]) => (
                <span key={k} className="rounded-[10px] bg-[#2c2263] px-3 py-1.5">
                  <span className="block text-[11px] text-[#c9c0ff]">{k}</span>
                  <b className="block text-[15px] text-white">{v}</b>
                </span>
              ))}
            </div>
          )}
        </div>

        {flash && <p className="rounded-[10px] bg-[#e3f5ea] px-3 py-2 text-[13.5px] font-semibold text-[#13623a]">{flash}</p>}

        {pendingChanges.length > 0 && (
          <button type="button" onClick={() => setSheet({ notice: pendingChanges[0].id })}
            className="flex min-h-[48px] items-center justify-between gap-2 rounded-[12px] border-2 border-[#f0a33a] bg-[#fff4d6] px-4 text-left text-[14px] font-semibold text-[#5c3b00]">
            정규 일정 변경 안내를 아직 안 보냈어요 ({pendingChanges.length}건) — 문구 복사 · 발송 완료 기록
            <Icon name="chevron" className="h-4 w-4" />
          </button>
        )}

        <div className="grid gap-3 lg:grid-cols-3 lg:items-start">
          <Box title="정규 일정" action={e && status !== 'ended' ? <button type="button" className={btnSmall} onClick={() => setSheet('regular')}>정규 일정 수정</button> : undefined}>
            {data.slots.length === 0 ? <p className="py-2 text-[13px] text-[#6b6880]">정규 일정이 없어요{pending ? ' (결제 확인 전 — 확인한 뒤 강사 배정·일정 확정)' : e ? ' (강사 배정·일정 확정 전)' : ''}.</p> : (
              <>
                <Row k="한국 시간" v={<>{slotsText(data.slots)} · {slot!.durationMin}분</>} strong />
                {s.timezone !== 'Asia/Seoul' && <Row k={`수강생 · ${koZone(s.timezone)}`} v={slotsInZone(data.slots, s.timezone, today)} />}
                {slot!.tutorTz !== 'Asia/Seoul' && <Row k={`강사 ${slot!.tutor} · ${koZone(slot!.tutorTz)}`} v={slotsInZone(data.slots, slot!.tutorTz, today)} />}
                <Row k="적용" v={`${md(slot!.from)}부터`} />
                {data.nextSlots.length > 0 && <Row k={`${mdw(data.nextSlots[0].from)}부터 적용 예정`} v={<b className="text-[#5b3fe0]">{slotsText(data.nextSlots)} 한국 시간</b>} />}
                <Row k="바뀐 기록" v={data.changes.length === 0 ? '없음' : <button type="button" className="font-semibold text-[#5b3fe0] underline" onClick={() => setSheet({ notice: data.changes[0].id })}>{data.changes.length}건 보기</button>} />
              </>
            )}
          </Box>

          <Box title="수강" action={(e && !pending && e.status !== 'completed' && e.status !== 'canceled') || canRenew ? (
            <span className="flex flex-wrap gap-1.5">
              {e && !pending && e.status !== 'completed' && e.status !== 'canceled' && <button type="button" className={btnSmall} onClick={() => setSheet('extend')}>종료일 연장</button>}
              {canRenew && <button type="button" className={`${btnSmall} !border-[#5b3fe0] !bg-[#5b3fe0] !text-white`} onClick={() => setSheet('renew')}>재등록 넣기</button>}
            </span>
          ) : undefined}>
            {!e ? <p className="py-2 text-[13px] text-[#6b6880]">수강권이 없어요.</p> : (
              <>
                <Row k="등록 상품" v={productText(e)} strong />
                <Row k="등록 수업" v={`${e.lessonsPurchased}회${e.lessonsCarriedIn ? ` + 이월 ${e.lessonsCarriedIn}회` : ''}`} />
                {pending
                  ? <Row k="수업 · 일정" v={`결제 확인 전 — 확인하면 수업 ${e.lessonsPurchased}회가 만들어져요 (아직 0회)`} />
                  : <Row k="진행 · 남은" v={`진행 ${e.done}회 · 남은 정규 ${e.leftRegular}회 (보강 포함 ${e.leftAll}회)`} />}
                <Row k={pending ? '희망 기간' : '기간'} v={`${md(e.startDate)} – ${md(e.baseEndDate)} (${diffDays(e.startDate, e.baseEndDate) + 1}일)${pending ? ' · 결제 확인 후 첫 수업일 기준으로 확정' : ''}`} />
                {e.extensionDays > 0 && <Row k="연장" v={[faultExt ? `+${faultExt}일 (${faultText ? `${faultText}, ` : ''}자동)` : '', autoExt ? `+${autoExt}일 (휴무 자동)` : '', manualExt ? `${manualExt > 0 ? '+' : ''}${manualExt}일 (운영진)` : ''].filter(Boolean).join(' · ')} />}
                {!pending && <Row k="최종 종료" v={finalEndText(e.finalEndDate, s.timezone)} strong />}
                {e.sheet && <Row k="시트 기준" v={`${e.sheet.used ?? 0}/${e.sheet.total ?? '?'}회`} />}
                {nx && (
                  <>
                    <Row k="다음 수강권" v={<>{nx.seq}차 · {productText({ weeks: nx.weeks, legacyLabel: null, weeklyCount: nx.weeklyCount, durationMin: nx.durationMin })}<span className="block text-[12.5px] font-normal text-[#6b6880]">{mdw(nx.startDate)} – {mdw(nx.finalEndDate)} · 결제 확인함</span></>} strong />
                    {!nx.planConfirmed && (
                      <Row k="정규 일정" v={<span className="text-[#b3261e]">확정 전 · 휴무로 미뤄진 수업 날짜 먼저</span>} />
                    )}
                    {(nx.carriedIn > 0 || ctx!.carry.length > 0) && (
                      <Row k="보강 이월" v={
                        <span className="inline-flex flex-wrap items-center justify-end gap-1.5">
                          {nx.carriedIn > 0 && <span>{nx.carriedIn}회 이월함 ✓</span>}
                          {ctx!.carry.length > 0 && (ctx!.carryOk
                            ? <><span>{ctx!.carry.length}회 가능</span><button type="button" className={`${btnSmall} !border-[#5b3fe0] !bg-[#5b3fe0] !text-white`} onClick={() => setSheet('carry')}>보강 이월</button></>
                            : <span className="text-[#b3261e]">{ctx!.carry.length}회 · 종료일 뒤 결제라 이월 안 됨</span>)}
                        </span>
                      } />
                    )}
                  </>
                )}
              </>
            )}
          </Box>

          {extra?.rewards && (
            <Box title="적립금" action={<span className="flex gap-1.5"><button type="button" className={btnSmall} onClick={() => setSheet('reward_in')}>넣기</button><button type="button" className={btnSmall} onClick={() => setSheet('reward_out')}>빼기</button></span>}>
              <RewardRows rewards={extra.rewards} />
            </Box>
          )}

          <Box title="프로필" action={<span className="flex gap-1.5"><Link href={`/lms/admin/students/sheet?student=${s.code}`} className={`${btnSmall} inline-flex items-center`}>시트 값 비교</Link><button type="button" className={btnSmall} onClick={() => setSheet('profile')}>수정</button></span>}>
            <Row k="영문 이름 (여권)" v={s.nameEn} strong />
            <Row k="Preferred Name" v={or(s.displayName)} />
            <Row k="거주" v={[s.country, s.city].filter(Boolean).join(' · ') || <i className="text-[#b9b6c8]">없음</i>} />
            <Row k="시간대" v={<>{s.timezone} · 지금 {zoneLabel(now, s.timezone)}</>} />
            <Row k="성별 / 연령대" v={or(s.genderAge)} />
            <Row k="이메일" v={s.email ? <span className="inline-flex flex-wrap items-center justify-end gap-1.5">{s.email}<CopyButton text={s.email} /></span> : or(null)} />
            <Row k="휴대폰" v={or(s.phone)} />
            <Row k="레벨 (강사 평가)" v={s.level ? <>{s.level}{s.levelBy || s.levelAt ? <span className="block text-[12px] text-[#6b6880]">{[s.levelBy, s.levelAt ? md(instantToKstDate(s.levelAt)) : ''].filter(Boolean).join(' · ')}</span> : null}</> : <i className="text-[#b9b6c8]">평가 전</i>} />
            {s.levelNote && <Row k="예전 레벨 표기" v={s.levelNote} />}
            <Row k="Type of class" v={or(s.classType)} />
            {/* 강사가 첫 수업 후 확인한 실제 수업 방식 (4600) — 수강생 희망(7번)과 다른 칸 */}
            <Row k="수업 방식 (강사 확인)" v={s.tutorClassStyle ? <>{styleText(s, 'ko')}<span className="block text-[12.5px] text-[#6b6880]">{s.tutorClassStyleBy ?? '강사'} 확인{s.tutorClassStyleAt ? ` · ${md(instantToKstDate(s.tutorClassStyleAt))}` : ''}</span></> : <i className="text-[#b9b6c8]">첫 수업 후 강사 확인 전</i>} />
            <Row k="교재" v={or(s.textbook)} />
            <Row k="Google Docs" v={s.classNoteUrl ? <a href={s.classNoteUrl} target="_blank" rel="noreferrer" className="font-semibold text-[#5b3fe0] underline">수업 노트 열기 ↗</a> : or(null)} />
          </Box>

          <Box title="자기소개 · 수업 선호 (수강생 답)" action={<button type="button" className={btnSmall} onClick={() => setSheet('answers')}>수정</button>}>
            <Row k="1 직업" v={or(s.job, NA)} />
            <Row k="2 취미" v={or(s.hobbies, NA)} />
            <Row k="3 관심사" v={or(s.interests, NA)} />
            <Row k="4 개선하고 싶은 부분" v={s.improve ? <>{s.improve}{s.improveTutorAt && <span className="block text-[12.5px] text-[#6b6880]">강사가 첫 수업에서 직접 확인 · {md(instantToKstDate(s.improveTutorAt))}</span>}</> : NA} />
            <Row k="5 바라는 점·분위기" v={or(s.hopes, NA)} />
            <Row k="6 선호 교정 방식" v={s.correctionStyle ? <>{CORRECTION[s.correctionStyle]}{s.correctionNote && <span className="block text-[12.5px] text-[#6b6880]">{s.correctionNote}</span>}</> : NA} />
            <Row k="7 선호 수업 스타일" v={s.classStyle ? <>{CLASS_STYLE[s.classStyle]}{s.classStyleNote && <span className="block text-[12.5px] text-[#6b6880]">{s.classStyleNote}</span>}</> : NA} />
            {s.answersAt && <p className="pt-1 text-[12px] text-[#6b6880]">마지막 수정 {md(instantToKstDate(s.answersAt))}</p>}
            {(s.selfIntroEn || s.correctionPref) && (
              <details className="mt-1 text-[13px]">
                <summary className="cursor-pointer font-semibold text-[#5b3fe0]">기존 시트 자기소개 (원문 그대로)</summary>
                {s.selfIntroEn && <p className="mt-1 whitespace-pre-wrap text-[#1d1b2b]">{s.selfIntroEn}</p>}
                {s.correctionPref && <p className="mt-1 text-[#6b6880]">교정 선호(시트): {s.correctionPref}</p>}
              </details>
            )}
          </Box>

          <Box title="운영진만 (강사 화면에 안 보임)">
            {data.enrollments.length === 0 && <p className="py-2 text-[13px] text-[#6b6880]">결제 기록이 없어요.</p>}
            {data.enrollments.map((en) => (
              <div key={en.id} className="border-b border-[#f0eef6] py-2 text-[13.5px] last:border-0">
                <p className="font-semibold text-[#1d1b2b]">{en.seq}차 · {productText(en)} · {md(en.startDate)}–{md(en.finalEndDate)} <span className="text-[12px] font-normal text-[#6b6880]">{en.status}</span></p>
                {en.payments.length === 0 ? <p className="text-[#6b6880]">결제 {en.amountDue ? won(en.amountDue) : ''} 기록 없음</p> : en.payments.map((p, i) => (
                  <p key={i} className="text-[#1d1b2b]">{p.on ? md(p.on) : '날짜 없음'} · {p.method} · {won(p.amount)} <span className={`text-[12px] ${p.confirmed ? 'text-[#13623a]' : 'text-[#a35b00]'}`}>{p.confirmed ? '확인' : '확인 전'}</span></p>
                ))}
              </div>
            ))}
            <Row k="로그인 이메일" v={or(data.loginEmail, <i className="text-[#b9b6c8]">계정 없음</i>)} />
            <Row k="운영 메모" v={or(s.adminMemo)} />
            {s.lmsSince && <Row k="LMS 시작" v={s.lmsSince} />}
          </Box>

          {e && !pending && (
            <LessonManage student={{ timezone: s.timezone }} regularTutorId={slot?.tutorId ?? null} finalEnd={e.finalEndDate}
              actions={actions.lessonManage} />
          )}

          <Box title="다가오는 수업" action={prestartOpen ? (
            <button type="button" onClick={() => setSheet('prestart')} className="min-h-[36px] rounded-[10px] border border-[#cfc4ff] bg-white px-3 text-[13px] font-semibold text-[#5b3fe0]">
              시작 전 날짜 변경
            </button>
          ) : undefined}>
            {data.upcoming.length === 0 && <p className="py-2 text-[13px] text-[#6b6880]">예정된 수업이 없어요.</p>}
            {data.upcoming.slice(0, 8).map((l) => (
              <div key={l.id} className="border-b border-[#f0eef6] py-2 text-[13.5px] last:border-0">
                <p className="text-[#1d1b2b]">{kstWithZones(l.startsAt, [{ label: '수강생', tz: s.timezone }, { label: `강사 ${l.tutor}`, tz: l.tutorTz }])}</p>
                <p className="text-[12.5px] text-[#6b6880]">{l.kind === 'regular' && l.seq ? `정규 ${l.seq}회` : KIND_KO[l.kind] ?? l.kind}{l.substitute ? ` · 대체강사 ${l.tutor}` : ''}{l.leaveOpen ? ' · 강사 휴무 처리 중' : ''}</p>
              </div>
            ))}
            {data.upcoming.length > 8 && <p className="pt-1 text-[12.5px] text-[#6b6880]">… {data.upcoming.length - 8}회 더 · 수업 변경은 <Link href={`/lms/admin/change?student=${s.code}`} className="font-semibold text-[#5b3fe0] underline">수업 변경·보강</Link>에서</p>}
          </Box>

          <Box title="지난 수업">
            {data.recent.length === 0 && <p className="py-2 text-[13px] text-[#6b6880]">지난 수업이 없어요.</p>}
            {data.recent.map((l) => <Row key={l.id} k={<Rich text={`${zoneLabel(l.startsAt, 'Asia/Seoul')} *한국 시간*`} />} v={`${KIND_KO[l.kind] ?? l.kind} · ${l.classStatus ?? (l.state === 'scheduled' ? '기록 전' : l.state)}`} />)}
            {data.recentTopics.length > 0 && (
              <details className="mt-1 text-[13px]">
                <summary className="cursor-pointer font-semibold text-[#5b3fe0]">최근 Covered Topics {data.recentTopics.length}건</summary>
                {data.recentTopics.map((t, i) => <p key={i} className="mt-1 text-[#1d1b2b]"><span className="text-[#6b6880]">{md(instantToKstDate(t.startsAt))} {t.tutor}{t.substitute ? ' (대체)' : ''}:</span> {t.topics}</p>)}
              </details>
            )}
          </Box>
        </div>

        {data.edits.length > 0 && (
          <details className="rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-3 text-[13px]">
            <summary className="cursor-pointer text-[12px] font-extrabold tracking-wider text-[#6b6880]">정보 수정 기록 {data.edits.length}건</summary>
            <ul className="mt-2 grid gap-1">
              {data.edits.map((x, i) => (
                <li key={i} className="text-[#1d1b2b]">
                  <span className="text-[#6b6880]">{zoneLabel(x.at, 'Asia/Seoul')} · {WHO_ROLE[x.role] ?? x.role}{x.role === 'student' ? '' : ` ${x.by}`}</span> · {FIELD_KO[x.field] ?? x.field}: <s className="text-[#b9b6c8]">{x.old ?? '(빈 값)'}</s> → {x.new ?? '(빈 값)'}
                </li>
              ))}
            </ul>
          </details>
        )}
      </div>
      <BottomNav active="students" demo={false} />

      {sheet === 'regular' && (
        <RegularChange data={data} today={today} preview={actions.preview} save={actions.save} onClose={() => setSheet(null)}
          onSaved={async (changeId) => { await actions.reload(); setSheet({ notice: changeId }); }} />
      )}
      {sheet === 'prestart' && e && (
        <PrestartMove lessons={regularAhead} period={{ start: e.startDate, end: e.finalEndDate }} student={{ nameEn: s.nameEn, timezone: s.timezone, city: s.city }}
          move={actions.prestart} loadMoved={actions.prestartMoved} onSaved={actions.reload} onClose={() => setSheet(null)} />
      )}
      {sheet === 'extend' && e && <ExtendSheet enrollment={e} studentTz={s.timezone} today={today} extend={actions.extend} onClose={() => setSheet(null)} onSaved={async () => { await actions.reload(); setSheet(null); }} />}
      {sheet === 'profile' && <ProfileSheet student={s} update={actions.update} onClose={() => setSheet(null)} onSaved={async () => { await actions.reload(); setSheet(null); }} />}
      {sheet === 'answers' && <AnswersSheet student={s} update={actions.update} onClose={() => setSheet(null)} onSaved={async () => { await actions.reload(); setSheet(null); }} />}
      {sheet === 'renew' && extra && ctx?.prev && (
        <RenewSheet who={who} ctx={ctx} today={today} actions={extra.actions} onClose={() => setSheet(null)} onSaved={actions.reload} onCarry={() => setSheet('carry')} />
      )}
      {sheet === 'carry' && extra && ctx?.prev && ctx.next && (
        <CarrySheet who={who} ctx={ctx} today={today} actions={extra.actions} onClose={() => setSheet(null)} onSaved={actions.reload} />
      )}
      {(sheet === 'reward_in' || sheet === 'reward_out') && extra?.rewards && (
        <RewardSheet who={who} rewards={extra.rewards} mode={sheet === 'reward_in' ? 'in' : 'out'} today={today} actions={extra.actions} onClose={() => setSheet(null)}
          onSaved={async (msg) => { await actions.reload(); setSheet(null); setFlash(msg); }} />
      )}
      {sheet && typeof sheet === 'object' && (
        <NoticeSheet data={data} changeId={sheet.notice} sent={actions.sent} reload={actions.reload} onClose={() => setSheet(null)} />
      )}
    </div>
  );
}

/** ③ 저장 뒤 안내: 수강생 카카오톡·강사 WhatsApp 문구 복사 → 각각 [발송 완료] (수강생·강사 따로 기록) */
function NoticeSheet({ data, changeId, sent, reload, onClose }: { data: StudentDetailData; changeId: string; sent: DetailActions['sent']; reload: () => Promise<void>; onClose: () => void }) {
  const [cur, setCur] = useState(changeId);
  const [busy, setBusy] = useState('');
  const c = data.changes.find((x) => x.id === cur) ?? data.changes[0];
  const s = data.student;
  if (!c) return null;
  const ctx = { studentNameKo: s.nameKo ?? s.nameEn, studentNameEn: s.nameEn, studentTz: s.timezone, tutorName: c.tutor, tutorTz: c.tutorTz, durationMin: data.enrollment?.durationMin ?? data.slots[0]?.durationMin ?? 0, effectiveFrom: c.effectiveFrom, newSlots: c.newSlots, moved: c.moved };
  const ko = regularNoticeKo(ctx);
  const en = regularNoticeEn(ctx);
  async function mark(who: 'student' | 'tutor', undo: boolean) {
    setBusy(who);
    try { await sent(c!.id, who, undo); await reload(); } finally { setBusy(''); }
  }
  return (
    <Sheet title="정규 일정 변경 · 안내" onClose={onClose} wide>
      {data.changes.length > 1 && (
        <select value={c.id} onChange={(e) => setCur(e.target.value)} className={`${input} mb-3`} aria-label="변경 기록 고르기">
          {data.changes.map((x) => <option key={x.id} value={x.id}>{md(instantToKstDate(x.at))} 저장 · {mdw(x.effectiveFrom)}부터 {slotsText(x.oldSlots)} → {slotsText(x.newSlots)}</option>)}
        </select>
      )}
      <div className="mb-3 rounded-[12px] bg-white px-3 py-2 text-[13.5px] text-[#1d1b2b]">
        <p><b>{mdw(c.effectiveFrom)}부터</b> {slotsText(c.oldSlots)} → <b>{slotsText(c.newSlots)}</b> <b>한국 시간</b> · 바뀐 수업 {c.moved.length}회 · 그대로 {c.kept.length}회</p>
        <p className="text-[12.5px] text-[#6b6880]">사유: {c.reason} · 저장 {zoneLabel(c.at, 'Asia/Seoul')} <b>한국 시간</b></p>
      </div>
      <div className="grid gap-3 lg:grid-cols-2">
        <NoticeCard title="수강생 카카오톡" text={ko} sentAt={c.studentSentAt} busy={busy === 'student'} onSent={() => mark('student', false)} onUndo={() => mark('student', true)} />
        {/* 강사는 자동 메일 + 강사 화면 Updates (H26(122)(127)). 자동으로 못 보냈을 때(메일 주소 없음)만 복사 카드 */}
        {!c.tutorSentAt && <NoticeCard title={`강사 WhatsApp (${c.tutor})`} text={en} sentAt={c.tutorSentAt} busy={busy === 'tutor'} onSent={() => mark('tutor', false)} onUndo={() => mark('tutor', true)} />}
      </div>
      <p className="mt-3 text-[12px] text-[#6b6880]">수강생·강사 화면에는 저장 즉시 반영돼 있어요. 강사에게는 자동 메일이 가요. 수강생 안내는 복사해 직접 보내고, 보낸 뒤 [발송 완료]를 눌러 기록해요.</p>
    </Sheet>
  );
}
function NoticeCard({ title, text, sentAt, busy, onSent, onUndo }: { title: string; text: string; sentAt: Date | null; busy: boolean; onSent: () => void; onUndo: () => void }) {
  return (
    <section className="rounded-[12px] border border-[#e6e3ef] bg-white p-3">
      <div className="mb-1 flex items-center justify-between gap-2">
        <h3 className="text-[13px] font-extrabold text-[#6b6880]">{title}</h3>
        {sentAt ? <span className="text-[12.5px] font-semibold text-[#13623a]">✓ 보냄 {zoneLabel(sentAt, 'Asia/Seoul')}</span> : <span className="text-[12.5px] font-semibold text-[#a35b00]">안 보냄</span>}
      </div>
      <textarea readOnly value={text} rows={9} className="w-full rounded-[10px] border border-[#e6e3ef] bg-[#f7f6fb] px-3 py-2 text-[13px] text-[#1d1b2b]" />
      <div className="mt-2 flex gap-2">
        <CopyButton text={text} className={btnSub}>문구 복사</CopyButton>
        {sentAt ? <button type="button" className={btnSub} disabled={busy} onClick={onUndo}>발송 기록 취소</button>
          : <button type="button" className={`${btnMain} flex-1`} disabled={busy} onClick={onSent}>{busy ? '기록 중…' : '발송 완료'}</button>}
      </div>
    </section>
  );
}

/** 운영진만 종료일 연장: 새 최종 종료일을 고르면 더해지는 날을 자동 계산 → enrollment_extensions 한 줄 */
function ExtendSheet({ enrollment: e, studentTz, today, extend, onClose, onSaved }: {
  enrollment: NonNullable<StudentDetailData['enrollment']>; studentTz: string; today: KstDate; extend: DetailActions['extend']; onClose: () => void; onSaved: () => Promise<void>;
}) {
  const options = useMemo(() => dateOptions(e.baseEndDate, (e.finalEndDate > today ? e.finalEndDate : today).slice(0, 4) === '9999' ? e.finalEndDate : addDaysSafe(e.finalEndDate, 120)), [e, today]);
  const [newEnd, setNewEnd] = useState<KstDate>(e.finalEndDate);
  const [kind, setKind] = useState<'student_long_term_leave' | 'admin_exception' | 'correction'>('student_long_term_leave');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const days = diffDays(e.finalEndDate, newEnd);
  const auto = e.extensions.filter((x) => x.auto);
  async function onSave() {
    setBusy(true);
    setErr('');
    try {
      await extend(e.id, newEnd, kind, note.trim());
      await onSaved();
    } catch (x) {
      setErr(x instanceof Error ? x.message : '저장하지 못했어요.');
      setBusy(false);
    }
  }
  return (
    <Sheet title="종료일 연장 (운영진만)" onClose={onClose}>
      <div className="grid gap-2 rounded-[12px] bg-white px-3 py-2 text-[13.5px]">
        <Row k="원래 종료" v={<Rich text={`${mdw(e.baseEndDate)} 오후 11:59 *한국 시간*`} />} />
        {/* 합계 먼저, 기록은 접어 둠 (QA 11/8: 휴대폰에서 입력란까지 스크롤이 길었음) */}
        {e.extensions.length > 0 && <Row k="이미 연장" v={`${e.extensionDays > 0 ? '+' : ''}${e.extensionDays}일 (기록 ${e.extensions.length}건)`} />}
        {e.extensions.length > 0 && (
          <details className="text-[13px] text-[#55526a]">
            <summary className="cursor-pointer font-semibold text-[#5b3fe0]">연장 기록 보기</summary>
            <ul className="mt-1 grid gap-0.5">
              {e.extensions.map((x) => (
                <li key={x.id}>{`${x.days > 0 ? '+' : ''}${x.days}일 · ${EXT_REASON[x.reason] ?? x.reason}${x.note ? ` (${x.note})` : ''}`}</li>
              ))}
            </ul>
          </details>
        )}
        <Row k="지금 최종 종료" v={finalEndText(e.finalEndDate, studentTz)} strong />
      </div>
      <div className="mt-3 grid gap-3">
        <div>
          <label htmlFor="ext-date" className={label}>새 최종 종료일 (오후 11:59 한국 시간)</label>
          <select id="ext-date" value={newEnd} onChange={(x) => setNewEnd(x.target.value)} className={input}>
            {options.map((d) => <option key={d} value={d}>{mdw(d)}{d === e.finalEndDate ? ' (지금)' : ''}</option>)}
          </select>
          {days !== 0 && <p className="mt-1 text-[13px] text-[#1d1b2b]">= {finalEndText(newEnd, studentTz)} · <b>{days > 0 ? `+${days}일` : `${days}일 (줄임)`}</b> (자동 계산)</p>}
        </div>
        <div>
          <span className={label}>사유 종류</span>
          <div className="flex flex-wrap gap-1.5">
            {(['student_long_term_leave', 'admin_exception', 'correction'] as const).map((k) => (
              <button key={k} type="button" aria-pressed={kind === k} onClick={() => setKind(k)}
                className={`min-h-[40px] rounded-[10px] px-3 text-[14px] font-semibold ${kind === k ? 'bg-[#5b3fe0] text-white' : 'border border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>{EXT_REASON[k]}</button>
            ))}
          </div>
        </div>
        <div>
          <label htmlFor="ext-note" className={label}>사유 (필수)</label>
          <input id="ext-note" value={note} onChange={(x) => setNote(x.target.value)} placeholder="예: 수강생 입원으로 2주 수업 못 함 — 대표 승인 11/3" className={input} />
        </div>
        <div className="rounded-[12px] bg-white px-3 py-2 text-[13px] text-[#1d1b2b]">
          <p className="font-bold text-[#6b6880]">같이 바뀌는 곳</p>
          <ul className="mt-1 list-disc pl-5">
            <li>수강생 화면 수강 종료일{studentTz !== 'Asia/Seoul' ? ` (${koZone(studentTz)}으로도 표시)` : ''} · 보강·무료 보상수업 사용 기한 · 재등록 안내 마감 · 대시보드 종료 임박 · 강사 화면 Enrollment</li>
            <li>수업 회차는 그대로 ({e.lessonsPurchased}회{e.lessonsCarriedIn ? ` + 이월 ${e.lessonsCarriedIn}회` : ''}) — 연장만으로 회차가 늘지 않아요</li>
            {auto.length > 0 && <li>강사 휴무 자동 연장(+{auto.reduce((a, x) => a + x.days, 0)}일)은 그대로 두고 합계로 계산해요 (중복 없음)</li>}
            <li>기록: {md(e.finalEndDate)} → {days === 0 ? '새 종료일' : md(newEnd)}, 사유, 운영진, 저장 시각. 지우거나 고칠 수 없고 잘못 넣으면 ‘정정’ 줄을 하나 더해요</li>
          </ul>
        </div>
      </div>
      {err && <p className="mt-3 rounded-[10px] bg-[#fdecea] px-3 py-2 text-[14px] text-[#b3261e]">{err}</p>}
      <div className="mt-4 flex gap-2">
        <button type="button" className={btnSub} onClick={onClose} disabled={busy}>취소</button>
        <button type="button" className={`${btnMain} flex-1`} disabled={days === 0 || !note.trim() || busy} onClick={onSave}>{busy ? '저장 중…' : days === 0 ? '새 종료일 고르기' : `${md(newEnd)}로 ${days > 0 ? '연장' : '정정'}`}</button>
      </div>
    </Sheet>
  );
}
function addDaysSafe(d: KstDate, n: number): KstDate {
  const t = new Date(`${d}T00:00:00Z`);
  t.setUTCDate(t.getUTCDate() + n);
  return t.toISOString().slice(0, 10);
}

type Field = { key: string; title: string; kind?: 'text' | 'textarea' | 'select'; options?: [string, string][]; hint?: string };
const PROFILE_FIELDS: Field[] = [
  { key: 'name_ko', title: '한국 이름 (운영진 식별 기준)' },
  { key: 'name_en', title: '영문 이름 (여권, 강사 식별 기준)' },
  { key: 'display_name', title: 'Preferred Name (수업 중 불리고 싶은 이름, 선택)' },
  { key: 'country', title: '거주 국가' },
  { key: 'city', title: '도시' },
  { key: 'timezone', title: '시간대 (IANA, 예: America/Toronto)' },
  { key: 'gender_age', title: '성별 / 연령대 (받은 정보만)' },
  { key: 'email', title: '이메일' },
  { key: 'phone', title: '휴대폰' },
  { key: 'level', title: '영어 레벨 (English Speaking Level Rubric)', kind: 'select', options: [['', '평가 전'], ...LEVELS.map((l) => [l, l] as [string, string])] },
  { key: 'level_note', title: '예전 레벨 표기 (시트 A2/B1 등, 참고)' },
  { key: 'class_type', title: 'Type of class' },
  { key: 'textbook', title: '교재' },
  { key: 'class_note_url', title: 'Google Docs 링크 (https://…)' },
  { key: 'admin_memo', title: '운영 메모 (강사 화면에 안 보임)', kind: 'textarea' },
];
const ANSWER_FIELDS: Field[] = [
  { key: 'job', title: '1 직업' }, { key: 'hobbies', title: '2 취미' }, { key: 'interests', title: '3 관심사' },
  { key: 'improve', title: '4 영어에서 개선하고 싶은 부분', kind: 'textarea' }, { key: 'hopes', title: '5 수업에서 바라는 점·분위기', kind: 'textarea' },
  { key: 'correction_style', title: '6 선호 교정 방식', kind: 'select', options: [['', '미응답'], ['immediate', CORRECTION.immediate], ['major_only', CORRECTION.major_only]] },
  { key: 'correction_note', title: '6 교정 방식 설명 (선택)' },
  { key: 'class_style', title: '7 선호 수업 스타일', kind: 'select', options: [['', '미응답'], ['textbook', CLASS_STYLE.textbook], ['free_talking', CLASS_STYLE.free_talking], ['not_sure', CLASS_STYLE.not_sure]] },
  { key: 'class_style_note', title: '7 스타일 설명 (선택)' },
];
function valueOf(s: StudentProfile, key: string): string {
  const m: Record<string, string | null> = {
    name_ko: s.nameKo, name_en: s.nameEn, display_name: s.displayName, country: s.country, city: s.city, timezone: s.timezone, gender_age: s.genderAge, email: s.email, phone: s.phone,
    level: s.level, level_note: s.levelNote, class_type: s.classType, textbook: s.textbook, class_note_url: s.classNoteUrl, admin_memo: s.adminMemo,
    job: s.job, hobbies: s.hobbies, interests: s.interests, improve: s.improve, hopes: s.hopes, correction_style: s.correctionStyle, correction_note: s.correctionNote, class_style: s.classStyle, class_style_note: s.classStyleNote,
  };
  return m[key] ?? '';
}

// 입력 중 임시 저장 (이 기기, 수강생·창마다): 창이 닫히거나 화면이 새로고침돼도 입력이 사라지지 않게. 저장하거나 '닫을까요?'에 확인하면 지움
const draftKey = (studentId: string, title: string) => `lms_admin_draft_${studentId}_${title}`;
function readDraft(studentId: string, title: string): Record<string, string> | null {
  try { const s = localStorage.getItem(draftKey(studentId, title)); return s ? (JSON.parse(s) as Record<string, string>) : null; } catch { return null; }
}
function writeDraft(studentId: string, title: string, v: Record<string, string> | null) {
  try { if (v) localStorage.setItem(draftKey(studentId, title), JSON.stringify(v)); else localStorage.removeItem(draftKey(studentId, title)); } catch { /* 저장 안 되는 브라우저 */ }
}
function FieldsSheet({ title, fields, student, update, onClose, onSaved, foot }: {
  title: string; fields: Field[]; student: StudentProfile; update: DetailActions['update']; onClose: () => void; onSaved: () => Promise<void>; foot?: ReactNode;
}) {
  const base = useMemo(() => Object.fromEntries(fields.map((f) => [f.key, valueOf(student, f.key)])), [fields, student]);
  const [restored, setRestored] = useState(() => readDraft(student.id, title));
  const [v, setV] = useState<Record<string, string>>(() => ({ ...base, ...(readDraft(student.id, title) ?? {}) }));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const changed = Object.fromEntries(fields.filter((f) => (v[f.key] ?? '').trim() !== valueOf(student, f.key).trim()).map((f) => [f.key, (v[f.key] ?? '').trim() || null]));
  const n = Object.keys(changed).length;
  const set = (key: string, val: string) => {
    const next = { ...v, [key]: val };
    setV(next);
    const diff = Object.fromEntries(Object.entries(next).filter(([k, x]) => (x ?? '').trim() !== (base[k] ?? '').trim()));
    writeDraft(student.id, title, Object.keys(diff).length ? diff : null);
  };
  // 닫기(확인한 뒤)·취소 → 임시 저장도 지움
  const closeAndClear = () => { writeDraft(student.id, title, null); onClose(); };
  async function onSave() {
    setBusy(true);
    setErr('');
    try {
      await update(changed);
      writeDraft(student.id, title, null);
      await onSaved();
    } catch (x) {
      setErr(x instanceof Error ? x.message : '저장하지 못했어요.');
      setBusy(false);
    }
  }
  return (
    <Sheet title={title} onClose={closeAndClear} dirty={n > 0 && !busy}>
      {restored && n > 0 && (
        <p className="mb-3 flex items-center gap-2 rounded-[10px] bg-[#fff4d6] px-3 py-2 text-[13px] text-[#5c3b00]">
          <span className="flex-1">저장하지 않았던 입력을 되살렸어요.</span>
          <button type="button" className="min-h-[32px] rounded-[8px] border border-[#e6e3ef] bg-white px-2.5 text-[12.5px] font-semibold text-[#1d1b2b]" onClick={() => { setV(base); writeDraft(student.id, title, null); setRestored(null); }}>원래대로</button>
        </p>
      )}
      <div className="grid gap-3">
        {fields.map((f) => (
          <div key={f.key}>
            <label htmlFor={`f-${f.key}`} className={label}>{f.title}</label>
            {f.kind === 'select' ? (
              <select id={`f-${f.key}`} value={v[f.key] ?? ''} onChange={(e) => set(f.key, e.target.value)} className={input}>
                {f.options!.map(([val, t]) => <option key={val} value={val}>{t}</option>)}
              </select>
            ) : f.kind === 'textarea' ? (
              <textarea id={`f-${f.key}`} value={v[f.key] ?? ''} onChange={(e) => set(f.key, e.target.value)} rows={3} className={input} />
            ) : (
              <input id={`f-${f.key}`} value={v[f.key] ?? ''} onChange={(e) => set(f.key, e.target.value)} className={input} />
            )}
          </div>
        ))}
      </div>
      {foot}
      {err && <p className="mt-3 rounded-[10px] bg-[#fdecea] px-3 py-2 text-[14px] text-[#b3261e]">{err}</p>}
      <div className="mt-4 flex gap-2">
        <button type="button" className={btnSub} onClick={() => { if (n > 0 && !window.confirm('입력 중인 내용이 있어요. 저장하지 않고 닫을까요?')) return; closeAndClear(); }} disabled={busy}>취소</button>
        <button type="button" className={`${btnMain} flex-1`} disabled={n === 0 || busy} onClick={onSave}>{busy ? '저장 중…' : n === 0 ? '바뀐 것 없음' : `${n}칸 저장`}</button>
      </div>
    </Sheet>
  );
}
function ProfileSheet(p: { student: StudentProfile; update: DetailActions['update']; onClose: () => void; onSaved: () => Promise<void> }) {
  return <FieldsSheet title="프로필 수정" fields={PROFILE_FIELDS} {...p}
    foot={<p className="mt-3 text-[12px] text-[#6b6880]">영어 이름 칸은 따로 없어요 — 영문 이름(여권) 하나만 씁니다. 강사 화면에는 ‘{p.student.nameEn}{p.student.displayName ? ` (${p.student.displayName})` : ''}’로 보여요. 누가 언제 무엇을 바꿨는지 기록돼요.</p>} />;
}
function AnswersSheet(p: { student: StudentProfile; update: DetailActions['update']; onClose: () => void; onSaved: () => Promise<void> }) {
  return <FieldsSheet title="자기소개 · 수업 선호 (수강생 답 입력)" fields={ANSWER_FIELDS} {...p}
    foot={<p className="mt-3 text-[12px] text-[#6b6880]">첫 수업 전 카톡으로 받은 답을 그대로 적어요. 받지 않은 항목은 비워 두면 ‘미응답’으로 저장돼요 (추측해서 적지 않기). 기존 시트 자기소개는 원문 그대로 따로 보관돼요.</p>} />;
}
