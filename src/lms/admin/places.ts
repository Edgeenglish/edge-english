// 사는 곳(국가·도시) → 시간대 (2026-10-18 대표 확정 A안: 칸 안에서 바로 검색)
// - 국가·도시는 한국어·영어로 검색해서 고르고, 목록에 없으면 친 그대로 저장
// - 도시를 고르면 그 도시 시간대, 시간대가 하나뿐인 나라는 국가만으로 추천. 여럿인 나라(미국·캐나다·호주 등)는 도시를 골라야 추천
// - 학생이 많은 나라·도시만 넣어 둠. 늘릴 때는 COUNTRIES 에 한 줄 추가

/** [한국어, 영어, 다른 이름(검색용), 나라 시간대(하나뿐일 때), 도시들 '한국어|영어(다른 이름)|시간대(없으면 나라 시간대)'] */
const COUNTRIES: [string, string, string, string, string[]][] = [
  ['한국', 'South Korea', '대한민국 korea', 'Asia/Seoul', ['서울|Seoul', '부산|Busan', '인천|Incheon', '대구|Daegu', '대전|Daejeon', '광주|Gwangju', '제주|Jeju']],
  ['미국', 'United States', 'usa us america 미합중국', '', ['뉴욕|New York|America/New_York', '보스턴|Boston|America/New_York', '워싱턴 D.C.|Washington DC|America/New_York', '애틀랜타|Atlanta|America/New_York', '마이애미|Miami|America/New_York', '필라델피아|Philadelphia|America/New_York', '뉴저지|New Jersey|America/New_York', '시카고|Chicago|America/Chicago', '댈러스|Dallas|America/Chicago', '휴스턴|Houston|America/Chicago', '오스틴|Austin|America/Chicago', '덴버|Denver|America/Denver', '피닉스|Phoenix|America/Phoenix', '로스앤젤레스|Los Angeles LA 엘에이|America/Los_Angeles', '어바인|Irvine|America/Los_Angeles', '샌디에이고|San Diego|America/Los_Angeles', '샌프란시스코|San Francisco|America/Los_Angeles', '산호세|San Jose|America/Los_Angeles', '시애틀|Seattle|America/Los_Angeles', '포틀랜드|Portland|America/Los_Angeles', '라스베이거스|Las Vegas|America/Los_Angeles', '호놀룰루|Honolulu Hawaii 하와이|Pacific/Honolulu', '앵커리지|Anchorage Alaska 알래스카|America/Anchorage']],
  ['캐나다', 'Canada', '', '', ['토론토|Toronto|America/Toronto', '오타와|Ottawa|America/Toronto', '몬트리올|Montreal|America/Toronto', '밴쿠버|Vancouver 벤쿠버|America/Vancouver', '빅토리아|Victoria|America/Vancouver', '캘거리|Calgary|America/Edmonton', '에드먼턴|Edmonton|America/Edmonton', '위니펙|Winnipeg|America/Winnipeg', '리자이나|Regina|America/Regina', '핼리팩스|Halifax|America/Halifax']],
  ['호주', 'Australia', '오스트레일리아', '', ['시드니|Sydney|Australia/Sydney', '캔버라|Canberra|Australia/Sydney', '멜버른|Melbourne 멜번|Australia/Melbourne', '브리즈번|Brisbane|Australia/Brisbane', '골드코스트|Gold Coast|Australia/Brisbane', '퍼스|Perth|Australia/Perth', '애들레이드|Adelaide|Australia/Adelaide', '호바트|Hobart|Australia/Hobart', '다윈|Darwin|Australia/Darwin', '케언즈|Cairns|Australia/Brisbane', '투움바|Toowoomba|Australia/Brisbane', '타운즈빌|Townsville|Australia/Brisbane']],
  ['뉴질랜드', 'New Zealand', 'nz', 'Pacific/Auckland', ['오클랜드|Auckland', '웰링턴|Wellington', '크라이스트처치|Christchurch']],
  ['영국', 'United Kingdom', 'uk england 잉글랜드', 'Europe/London', ['런던|London', '맨체스터|Manchester', '버밍엄|Birmingham', '에든버러|Edinburgh']],
  ['일본', 'Japan', '', 'Asia/Tokyo', ['도쿄|Tokyo', '오사카|Osaka', '교토|Kyoto', '나고야|Nagoya', '후쿠오카|Fukuoka', '삿포로|Sapporo']],
  ['중국', 'China', '', 'Asia/Shanghai', ['베이징|Beijing', '상하이|Shanghai', '광저우|Guangzhou', '선전|Shenzhen', '칭다오|Qingdao']],
  ['홍콩', 'Hong Kong', '', 'Asia/Hong_Kong', ['홍콩|Hong Kong']],
  ['대만', 'Taiwan', '', 'Asia/Taipei', ['타이베이|Taipei']],
  ['싱가포르', 'Singapore', '', 'Asia/Singapore', ['싱가포르|Singapore']],
  ['베트남', 'Vietnam', '', 'Asia/Ho_Chi_Minh', ['호찌민|Ho Chi Minh 호치민', '하노이|Hanoi', '다낭|Da Nang']],
  ['태국', 'Thailand', '', 'Asia/Bangkok', ['방콕|Bangkok']],
  ['필리핀', 'Philippines', '', 'Asia/Manila', ['마닐라|Manila', '세부|Cebu']],
  ['말레이시아', 'Malaysia', '', 'Asia/Kuala_Lumpur', ['쿠알라룸푸르|Kuala Lumpur']],
  ['인도네시아', 'Indonesia', '', '', ['자카르타|Jakarta|Asia/Jakarta', '발리|Bali|Asia/Makassar']],
  ['아랍에미리트', 'United Arab Emirates', 'uae', 'Asia/Dubai', ['두바이|Dubai', '아부다비|Abu Dhabi']],
  ['독일', 'Germany', '', 'Europe/Berlin', ['베를린|Berlin', '프랑크푸르트|Frankfurt', '뮌헨|Munich']],
  ['프랑스', 'France', '', 'Europe/Paris', ['파리|Paris']],
  ['네덜란드', 'Netherlands', '', 'Europe/Amsterdam', ['암스테르담|Amsterdam']],
  ['스페인', 'Spain', '', 'Europe/Madrid', ['마드리드|Madrid', '바르셀로나|Barcelona']],
  ['아일랜드', 'Ireland', '', 'Europe/Dublin', ['더블린|Dublin']],
  ['폴란드', 'Poland', '', 'Europe/Warsaw', ['바르샤바|Warsaw', '크라쿠프|Krakow']],
];
const POPULAR = ['한국', '미국', '캐나다', '호주', '뉴질랜드', '영국', '일본', '싱가포르'];

export type Country = { ko: string; en: string; alias: string; timezone: string };
export type City = { ko: string; en: string; country: string; timezone: string };
export type ZoneRow = { timezone: string; cities: string[]; countries: string[]; en: string[] };

export const COUNTRY_LIST: Country[] = COUNTRIES.map(([ko, en, alias, timezone]) => ({ ko, en, alias, timezone }));
export const CITY_LIST: City[] = COUNTRIES.flatMap(([country, , , tz, cities]) =>
  cities.map((s) => {
    const [ko, en, timezone] = s.split('|');
    return { ko, en, country, timezone: timezone || tz };
  }),
);
/** 시간대 하나에 그 시간대를 쓰는 도시들을 묶음 (검색·표시용) */
export const ZONE_ROWS: ZoneRow[] = (() => {
  const by = new Map<string, ZoneRow>();
  for (const c of CITY_LIST) {
    const r = by.get(c.timezone) ?? { timezone: c.timezone, cities: [], countries: [], en: [] };
    r.cities.push(c.ko);
    r.en.push(c.en);
    if (!r.countries.includes(c.country)) r.countries.push(c.country);
    by.set(c.timezone, r);
  }
  return [...by.values()];
})();

// 띄어쓰기·대소문자·기호 무시: 'new york' = 'NewYork', '워싱턴 D.C.' = '워싱턴dc'
const norm = (s: string) => s.toLowerCase().replace(/[\s._\-/·,()]/g, '');
const hit = (q: string, ...xs: string[]) => {
  const n = norm(q);
  return !n || xs.some((x) => norm(x).includes(n));
};

export const findCountry = (name: string) => COUNTRY_LIST.find((c) => c.ko === name);
export const findCity = (name: string, country = '') => CITY_LIST.find((c) => c.ko === name && (!country || c.country === country));

/** 국가 검색. 빈 검색어면 자주 쓰는 나라 */
export function searchCountries(q: string): Country[] {
  if (!norm(q)) return POPULAR.map((k) => findCountry(k)!);
  return COUNTRY_LIST.filter((c) => hit(q, c.ko, c.en, c.alias));
}

/** 도시 검색. 목록에 있는 나라를 골랐으면 그 나라 도시만, 아니면 전체 (도시를 고르면 나라도 같이 채움) */
export function searchCities(q: string, country: string): City[] {
  const only = findCountry(country) ? country : '';
  return CITY_LIST.filter((c) => (!only || c.country === only) && hit(q, c.ko, c.en)).slice(0, 40);
}

/** 시간대 검색: 한국어 도시·나라 이름, 영어 이름, 'Australia/Melbourne' 같은 이름 모두. 목록에 없는 시간대도 영어 이름 3글자 이상이면 찾아 줌 */
export function searchZones(q: string): { rows: ZoneRow[]; more: string[] } {
  const rows = ZONE_ROWS.filter(
    (r) => hit(q, ...r.cities, ...r.en, ...r.countries, r.timezone) || r.countries.some((k) => { const c = findCountry(k); return !!c && norm(q) !== '' && hit(q, c.en, c.alias); }),
  );
  const all = typeof Intl.supportedValuesOf === 'function' ? Intl.supportedValuesOf('timeZone') : [];
  const more = norm(q).length >= 3 ? all.filter((z) => !rows.some((r) => r.timezone === z) && hit(q, z)).slice(0, 15) : [];
  return { rows, more };
}

/** 시간대 이름: 'Australia/Melbourne' → '멜버른 (호주)'. 목록에 없으면 그대로 */
export function zoneName(timezone: string): string {
  const r = ZONE_ROWS.find((x) => x.timezone === timezone);
  return r ? `${r.cities.slice(0, 3).join('·')} (${r.countries.join('·')})` : timezone;
}

/** 국가·도시로 시간대 추천. 모르면 '' (운영자가 고름) */
export function suggestTimezone(country: string, city: string): { timezone: string; why: string } {
  const c = findCity(city, findCountry(country) ? country : '');
  if (c) return { timezone: c.timezone, why: `${c.ko} 기준 자동 추천` };
  const k = findCountry(country);
  if (k?.timezone) return { timezone: k.timezone, why: `${eunNeun(k.ko)} 시간대가 하나라 자동 추천` };
  return { timezone: '', why: '' };
}

/** 시간대가 여럿인 나라인지 (도시를 골라야 추천 가능) */
export const manyZones = (country: string) => {
  const k = findCountry(country);
  return !!k && !k.timezone;
};

/** 신청서의 한 칸 '호주 / 멜버른', 'Canada, Calgary', '미국' → 목록 이름으로 나누기. 못 알아보면 친 그대로 */
export function parseCountryCity(text: string): { country: string; city: string } {
  const [a = '', ...rest] = text.split(/[/,·]/).map((x) => x.trim());
  const cityText = rest.filter(Boolean).join(' ');
  const k = norm(a) ? COUNTRY_LIST.find((c) => [c.ko, c.en, ...c.alias.split(' ')].some((x) => x && norm(x) === norm(a))) : undefined;
  const sameCity = (c: City, t: string) => norm(c.ko) === norm(t) || (norm(t).length >= 3 && norm(c.en).startsWith(norm(t)));
  // 나라 칸에 도시만 쓴 경우: '멜버른'
  if (!k && !cityText) {
    const only = CITY_LIST.find((c) => sameCity(c, a));
    if (only) return { country: only.country, city: only.ko };
  }
  const city = cityText ? CITY_LIST.find((c) => (!k || c.country === k.ko) && sameCity(c, cityText)) : undefined;
  return { country: k?.ko ?? a, city: city?.ko ?? cityText };
}

/** '한국' → '한국은', '호주' → '호주는' */
export function eunNeun(w: string): string {
  const c = w.charCodeAt(w.length - 1) - 0xac00;
  return w + (c >= 0 && c < 11172 && c % 28 ? '은' : '는');
}
