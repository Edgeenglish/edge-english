import { describe, expect, it } from 'vitest';
import { manyZones, parseCountryCity, searchCities, searchCountries, searchZones, suggestTimezone, zoneName } from './places';

describe('사는 곳 검색', () => {
  it('국가: 한국어·영어·다른 이름, 빈 검색은 자주 쓰는 나라', () => {
    expect(searchCountries('호주').map((c) => c.ko)).toEqual(['호주']);
    expect(searchCountries('australia').map((c) => c.ko)).toEqual(['호주']);
    expect(searchCountries('오스트레일리아').map((c) => c.ko)).toEqual(['호주']);
    expect(searchCountries('')[0].ko).toBe('한국');
  });
  it('도시: 띄어쓰기 무시, 고른 나라 안에서만', () => {
    expect(searchCities('new york', '').map((c) => c.ko)).toEqual(['뉴욕']);
    expect(searchCities('NewYork', '').map((c) => c.ko)).toEqual(['뉴욕']);
    expect(searchCities('멜버', '').map((c) => c.country)).toEqual(['호주']);
    expect(searchCities('', '뉴질랜드').map((c) => c.ko)).toEqual(['오클랜드', '웰링턴', '크라이스트처치']);
    expect(searchCities('', '남아공').length).toBeGreaterThan(20); // 목록에 없는 나라면 전체
  });
  it('시간대: 한국어 도시·나라, 영어, IANA 이름', () => {
    expect(searchZones('멜버른').rows.map((r) => r.timezone)).toEqual(['Australia/Melbourne']);
    expect(searchZones('melbourne').rows.map((r) => r.timezone)).toEqual(['Australia/Melbourne']);
    expect(searchZones('호주').rows).toHaveLength(7);
    expect(searchZones('australia').rows).toHaveLength(7);
    expect(searchZones('Africa/Johan').more).toContain('Africa/Johannesburg');
    expect(zoneName('Australia/Sydney')).toBe('시드니·캔버라 (호주)');
    expect(zoneName('Africa/Johannesburg')).toBe('Africa/Johannesburg');
  });
});

describe('시간대 추천', () => {
  it('도시 우선, 시간대가 하나인 나라는 국가만으로, 여럿이면 비움', () => {
    expect(suggestTimezone('호주', '퍼스').timezone).toBe('Australia/Perth');
    expect(suggestTimezone('일본', '').timezone).toBe('Asia/Tokyo');
    expect(suggestTimezone('한국', '').why).toBe('한국은 시간대가 하나라 자동 추천');
    expect(suggestTimezone('미국', '').timezone).toBe('');
    expect(suggestTimezone('미국', '시골마을').timezone).toBe('');
    expect(manyZones('미국')).toBe(true);
    expect(manyZones('영국')).toBe(false);
  });
});

describe('신청서 한 칸 나누기', () => {
  it.each([
    ['호주 / 멜버른', '호주', '멜버른'],
    ['Canada, Calgary', '캐나다', '캘거리'],
    ['미국', '미국', ''],
    ['멜버른', '호주', '멜버른'],
    ['USA / new york', '미국', '뉴욕'],
    ['남아공 / 케이프타운', '남아공', '케이프타운'],
    ['', '', ''],
  ])('%s', (text, country, city) => {
    expect(parseCountryCity(text)).toEqual({ country, city });
  });
});
