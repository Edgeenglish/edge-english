// 수강생 안내 시간대 한국어 이름: 화면(카톡 문구)과 DB 메일이 같은 표를 쓰는지 대조 (대표 2026-11-08 '템플릿 통일')
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { koAt } from './lesson-change';
import { ZONE_ROWS, koZoneCity } from './places';

describe('수강생 안내 시각 모양', () => {
  it('한국 거주 = 한국 시간, 해외 = [도시 시간] / [한국 시간], 도시 이름은 한국어', () => {
    const at = new Date('2026-11-13T00:00:00Z');
    expect(koAt(at, 'Asia/Seoul')).toBe('11월 13일(금) 오전 9시 [한국 시간]');
    expect(koAt(at, 'Australia/Melbourne')).toBe('11월 13일(금) 오전 11시 [멜버른 시간] / 오전 9시 [한국 시간]');
    expect(koAt(at, 'America/Detroit')).toBe('11월 12일(목) 오후 7시 [디트로이트 시간] / 11월 13일(금) 오전 9시 [한국 시간]');
    expect(koZoneCity('Asia/Singapore')).toBe('싱가포르');
  });
  it('DB 메일 표(20261108100000 lms_mail_ko_zone)가 화면 표와 같음', () => {
    const sql = readFileSync('supabase/migrations/20261108100000_lms_mail_time_zone_label.sql', 'utf8');
    const map = new Map([...sql.matchAll(/when '([^']+)' then '([^']+)'/g)].map((m) => [m[1], m[2]]));
    for (const r of ZONE_ROWS.filter((x) => x.timezone !== 'Asia/Seoul')) expect([r.timezone, map.get(r.timezone)]).toEqual([r.timezone, koZoneCity(r.timezone)]);
    expect(map.size).toBe(ZONE_ROWS.length - 1);
  });
});
