// 신규 학생 등록 미리보기용 가상 신청서·강사 일정 (실제 사람·실제 일정 아님). '지금' 기준으로 만든다
// - 신청서 2건은 새 형식(요일 × 시간대 체크), 1건은 예전 형식(희망 시간 자유 서술)
// - 강사 가능 시간은 강사 현지 시각 → 서머타임이 바뀌면 한국 시각 칸이 저절로 옮겨짐 (토론토 11/1, 런던 10/25)
// - 다음다음 주 화요일 20:00 에 Alex 보강 1건 (그날만 막히고 다음 주 화 20:00 은 가능해야 함)

import type { Busy } from '../rules/booking';
import { addDays, instantToKstDate, kstToInstant, weekdayOf } from '../rules/dates';
import { fakeDirectory } from './fake-directory';
import type { FormResponse, RegTutor } from './registration';
import { weekOf } from './schedule';

const raw = (f: Omit<FormResponse, 'raw'>, wishLabel: string): FormResponse => ({
  ...f,
  raw: [
    ['타임스탬프', f.submittedAt],
    ['이름', f.nameKo],
    ['영문 이름', f.nameEn],
    ['이메일', f.email],
    ['휴대폰 (해외: 카카오톡 ID)', f.phone],
    ['거주 국가 / 도시', f.countryCity],
    ['연령대', f.ageGroup],
    ['성별', f.gender],
    ['영어 고민·학습 목표', f.concern],
    ['수업 길이', f.duration],
    ['주 횟수', f.weekly],
    ['수강 기간', f.term],
    ['희망 시간', wishLabel],
    ['시작 희망일', f.startWish],
    ['입금자명', f.payerName],
  ],
});

export function fakeApplications(now: Date): FormResponse[] {
  const today = instantToKstDate(now);
  const nextTue = (from: string) => {
    let d = addDays(from, 1);
    while (weekdayOf(d) !== 2) d = addDays(d, 1);
    return d;
  };
  const wishStart = nextTue(addDays(today, 7));
  return [
    raw(
      {
        ref: '응답 #128', submittedAt: `${addDays(today, -2)} 14:22`, nameKo: '가상신청일', nameEn: 'Apply One', email: 'apply1@example.com', phone: '010-0000-0101',
        countryCity: '한국 / 서울', ageGroup: '30대', gender: '여', concern: '비즈니스 회화 · 실무 이메일', duration: '50분', weekly: '주 2회', term: '12주',
        desiredTime: '', wishGrid: [{ weekday: 2, from: '19:00', to: '22:00' }, { weekday: 4, from: '19:00', to: '22:00' }], startWish: wishStart, payerName: '가상신청일',
      },
      '화 19–22시, 목 19–22시 (체크)',
    ),
    raw(
      {
        ref: '응답 #129', submittedAt: `${addDays(today, -1)} 09:05`, nameKo: '가상신청이', nameEn: 'Apply Two', email: 'apply2@example.com', phone: 'kakao: apply_two',
        countryCity: '영국 / 런던', ageGroup: '20대', gender: '남', concern: '여행 회화', duration: '40분', weekly: '주 3회', term: '4주',
        desiredTime: '', wishGrid: [1, 3, 5].map((weekday) => ({ weekday, from: '10:00', to: '13:00' })), startWish: addDays(today, 10), payerName: 'Apply Two',
      },
      '월·수·금 10–13시 (런던 현지, 체크)',
    ),
    raw(
      {
        ref: '응답 #121 (예전 형식)', submittedAt: `${addDays(today, -6)} 22:41`, nameKo: '가상신청삼', nameEn: 'Apply Three', email: 'apply3@example.com', phone: '010-0000-0103',
        countryCity: '미국', ageGroup: '40대', gender: '여', concern: '발음 교정', duration: '50분', weekly: '주 1회', term: '3개월',
        desiredTime: '평일 저녁 아무 때나, 가능하면 늦게', wishGrid: null, startWish: '다음 달 초', payerName: '가상신청삼',
      },
      '평일 저녁 아무 때나, 가능하면 늦게',
    ),
  ];
}

export function fakeRegTutors(now: Date): RegTutor[] {
  const dir = fakeDirectory(now);
  const today = instantToKstDate(now);
  const from = addDays(weekOf(today)[0], -7);
  const until = addDays(today, 200);
  const busy = new Map<string, Busy[]>(dir.tutors.map((t) => [t.id, []]));
  // 수강 중 학생의 정규 수업: 기간 끝까지 매주 (가상 학생 기간이 짧아도 등록 기간 전체 검사를 보이려고 넉넉히)
  for (const s of dir.students) {
    if (!s.tutorId) continue;
    const end = s.status === 'ending' ? s.periodEnd : until;
    for (let d = from; d <= end; d = addDays(d, 1)) {
      for (const slot of s.slots.filter((x) => x.weekday === weekdayOf(d))) {
        const startsAt = kstToInstant(d, slot.time);
        busy.get(s.tutorId)!.push({ id: `${s.code}-${d}`, startsAt, endsAt: new Date(startsAt.getTime() + Number(s.product.slice(0, 2)) * 60000), kind: 'regular', label: s.name });
      }
    }
  }
  for (const l of dir.lessons.filter((x) => x.kind === 'makeup' && x.state !== 'canceled')) {
    busy.get(l.tutorId)!.push({ id: l.id, startsAt: l.startsAt, endsAt: new Date(l.startsAt.getTime() + l.minutes * 60000), kind: 'makeup', label: '보강' });
  }
  // Alex: 다음다음 주 화 20:00 보강 (그날만)
  const tue = addDays(weekOf(today)[0], 15);
  busy.get('t-alex')!.push({ id: 'mk-alex', startsAt: kstToInstant(tue, '20:00'), endsAt: kstToInstant(tue, '20:50'), kind: 'makeup', label: '보강 (가상학생팔)' });
  // Blair: 3주 뒤 목요일 하루 휴무
  const thu = addDays(weekOf(today)[0], 24);
  busy.get('t-blair')!.push({ id: 'off-blair', startsAt: kstToInstant(thu, '00:00'), endsAt: kstToInstant(addDays(thu, 1), '00:00'), kind: 'time_off', label: '휴무' });

  const win = (tz: string, days: number[], startLocal: string, endLocal: string) =>
    days.map((weekday) => ({ weekday, startLocal, endLocal, timezone: tz, effectiveFrom: '2026-01-01', effectiveTo: null }));
  const avail: Record<string, RegTutor['availability']> = {
    // 시드니 저녁 19–24시 = 한국 17–22시 (호주 서머타임 중)
    't-alex': win('Australia/Sydney', [1, 2, 3, 4, 5], '19:00', '24:00'),
    // 토론토 아침 5–10시 = 한국 18–23시 (11/1 서머타임 끝나면 19–24시)
    't-blair': win('America/Toronto', [2, 3, 4, 5, 6], '05:00', '10:00'),
    // 런던 10–14시 = 한국 18–22시 (10/25 서머타임 끝나면 19–23시)
    't-chloe': win('Europe/London', [1, 2, 3, 4, 5, 6], '10:00', '14:00'),
  };
  return dir.tutors.map((t) => ({ id: t.id, name: t.name, country: t.country, timezone: t.timezone, availability: avail[t.id] ?? [], busy: (busy.get(t.id) ?? []).sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime()) }));
}
