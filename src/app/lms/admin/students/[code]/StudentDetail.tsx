'use client';

import Link from 'next/link';
import { useMemo } from 'react';
import { diffDays, formatInZone, instantToKstDate } from '@/lms/rules/dates';
import { fakeDirectory } from '@/lms/admin/fake-directory';
import { dayLabel, localTime, WEEKDAY_KO } from '@/lms/admin/schedule';
import { AdminHeader, BottomNav, Icon } from '../../ui';

const won = (n: number) => `${n.toLocaleString('ko-KR')}원`;
const md = (d: string) => `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}`;

function Row({ k, v, strong }: { k: string; v: React.ReactNode; strong?: boolean }) {
  return (
    <div className="flex justify-between gap-3 border-b border-[#f0eef6] py-2 text-[14px] last:border-0">
      <span className="shrink-0 text-[#6b6880]">{k}</span>
      <span className={`text-right ${strong ? 'font-bold text-[#1d1b2b]' : 'text-[#1d1b2b]'}`}>{v}</span>
    </div>
  );
}

function Box({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-3">
      <h2 className="mb-1 text-[12px] font-extrabold tracking-wider text-[#6b6880]">{title}</h2>
      {children}
    </section>
  );
}

export default function StudentDetail({ code, nowIso }: { code: string; nowIso: string }) {
  const now = useMemo(() => new Date(nowIso), [nowIso]);
  const today = instantToKstDate(now);
  const dir = useMemo(() => fakeDirectory(now), [now]);
  const s = dir.students.find((x) => x.code === code);
  const tutor = dir.tutors.find((t) => t.id === s?.tutorId) ?? null;
  const upcoming = dir.lessons.filter((l) => l.studentCode === code && l.startsAt > now && l.state === 'scheduled').slice(0, 5);
  const recent = dir.lessons.filter((l) => l.studentCode === code && l.startsAt <= now).slice(-3).reverse();

  return (
    <div className="mx-auto min-h-dvh max-w-[1280px] pb-24 lg:pb-8">
      <AdminHeader active="students" demo />
      <div className="grid gap-3 px-4 pt-3 lg:px-7">
        <Link href="/lms/admin/students?demo=1" className="flex min-h-[36px] w-fit items-center gap-1 text-[13px] font-semibold text-[#5b3fe0]">
          <Icon name="chevron" className="h-4 w-4 rotate-180" /> 학생 목록
        </Link>
        {!s ? (
          <p className="rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-8 text-center text-[14px] text-[#6b6880]">{code} 학생을 찾을 수 없어요. (가상 데이터에 없는 학생)</p>
        ) : (
          <>
            <div className="flex flex-wrap items-center gap-3 rounded-[16px] bg-[#1b1442] px-4 py-4 text-white">
              <span className="flex h-12 w-12 items-center justify-center rounded-full bg-[#2c2263] text-[18px] font-bold text-white">{s.name.slice(-1)}</span>
              <div className="min-w-0 flex-1">
                <p className="text-[20px] font-bold text-white">
                  {s.name} <span className="text-[14px] font-normal text-[#c9c0ff]">{s.nameEn} · {s.code}</span>
                </p>
                <p className="text-[13px] text-[#d8d3f5]">
                  {s.product} · {tutor ? `${tutor.name} (${tutor.country})` : '강사 배정 전'}
                </p>
              </div>
              <div className="grid grid-cols-3 gap-2 text-center">
                {[
                  ['정규 남음', `${s.regularLeft}/${s.lessonsTotal}`],
                  ['변경권', `${s.creditsLeft}/${s.creditsPerPeriod}`],
                  ['종료', s.status === 'waiting_match' ? '시작 전' : `D-${Math.max(0, diffDays(today, s.periodEnd))}`],
                ].map(([k, v]) => (
                  <span key={k} className="rounded-[10px] bg-[#2c2263] px-3 py-1.5">
                    <span className="block text-[11px] text-[#c9c0ff]">{k}</span>
                    <b className="block text-[16px] text-white">{v}</b>
                  </span>
                ))}
              </div>
            </div>

            <div className="grid gap-3 lg:grid-cols-3 lg:items-start">
              <Box title="연락처 · 시간대">
                <Row k="이메일 (로그인)" v={s.email} />
                <Row k="휴대폰" v={s.phone} />
                <Row k="사는 곳 시간대" v={`${s.timezone} · 지금 ${formatInZone(now, s.timezone).time}`} />
                <Row k="수업 안내" v={<span className={s.consent === '동의 필요' ? 'font-bold text-[#a35b00]' : ''}>{s.consent}</span>} />
                {s.memo && <Row k="운영 메모" v={s.memo} />}
              </Box>

              <Box title="수강">
                <Row k="수강권" v={s.product} strong />
                <Row k="기간" v={`${md(s.periodStart)} – ${md(s.periodEnd)}`} />
                <Row k="고정 수업" v={s.slots.length ? s.slots.map((x) => `${WEEKDAY_KO[x.weekday]} ${x.time}`).join(' · ') : '배정 전'} />
                {tutor &&
                  s.slots.map((x) => {
                    const next = dir.lessons.find((l) => l.studentCode === code && l.startsAt > now && new Date(l.startsAt.getTime() + 9 * 3600_000).getUTCDay() === x.weekday);
                    return next ? <Row key={x.weekday} k={`${WEEKDAY_KO[x.weekday]} ${x.time} → 강사 현지`} v={`${tutor.name} ${localTime(next.startsAt, tutor.timezone)}`} /> : null;
                  })}
                <Row k="재등록" v={s.renewal} />
                <Row k="적립금" v={won(s.points)} />
              </Box>

              <Box title="결제 (운영자만 보임)">
                {s.payments.map((p, i) => (
                  <Row key={i} k={`${md(p.on)} · ${p.method}`} v={<>{won(p.amount)} <span className={`text-[12px] ${p.confirmed ? 'text-[#13623a]' : 'text-[#a35b00]'}`}>{p.confirmed ? '확인' : '확인 전'}</span></>} />
                ))}
              </Box>

              <Box title="다가오는 수업">
                {upcoming.length === 0 && <p className="py-2 text-[13px] text-[#6b6880]">예정된 수업이 없어요.</p>}
                {upcoming.map((l) => (
                  <Row key={l.id} k={`${dayLabel(instantToKstDate(l.startsAt))} ${formatInZone(l.startsAt, 'Asia/Seoul').time}`} v={`${l.kind === 'makeup' ? '보강 · ' : ''}${tutor ? `현지 ${localTime(l.startsAt, tutor.timezone)}` : ''}`} />
                ))}
              </Box>

              <Box title="지난 수업">
                {recent.length === 0 && <p className="py-2 text-[13px] text-[#6b6880]">지난 수업이 없어요.</p>}
                {recent.map((l) => (
                  <Row key={l.id} k={`${dayLabel(instantToKstDate(l.startsAt))} ${formatInZone(l.startsAt, 'Asia/Seoul').time}`} v={l.state === 'canceled' ? (l.note ?? '취소') : '진행'} />
                ))}
              </Box>

              <Box title="신청 · 처리 중">
                {s.requests.length === 0 && <p className="py-2 text-[13px] text-[#6b6880]">진행 중인 신청이 없어요.</p>}
                {s.requests.map((r) => (
                  <Row key={r.title} k={r.title} v={r.status} />
                ))}
              </Box>
            </div>
            <p className="text-[12.5px] text-[#6b6880]">수정·처리 버튼(연락처 변경, 수업 변경 대신 처리, 적립금 조정 등)은 서버 저장 기능을 만들 때 함께 붙입니다.</p>
          </>
        )}
      </div>
      <BottomNav active="students" demo />
    </div>
  );
}
