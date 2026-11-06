// 홈페이지 강사 소개(src/data/tutors.json)에서 LMS 강사 이름으로 찾기 — 운영자가 보고 싶을 때만 펼쳐 보는 용도
// 홈페이지 이름은 'Grace(그레이스)' 형식 → 괄호 앞 영문 이름이 LMS tutors.name 과 같으면 같은 강사로 본다
// 사진·평점 등을 새로 만들지 않고, 홈페이지에 이미 공개된 내용만 보여 준다

import raw from '../../data/tutors.json';

export type HomepageProfile = { name: string; desc: string; tags: string[]; img: string; career: string; intro: string; videoUrl: string };

const key = (s: string) => s.split('(')[0].trim().toLowerCase();

export function homepageProfile(lmsName: string): HomepageProfile | null {
  const t = (raw as { name: string; desc: string; tags: string[]; img: string; career: string; introduce1: string; videoUrl: string }[]).find((x) => key(x.name) === key(lmsName));
  return t ? { name: t.name, desc: t.desc, tags: t.tags, img: t.img, career: t.career, intro: t.introduce1, videoUrl: t.videoUrl } : null;
}
