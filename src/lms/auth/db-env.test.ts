import { describe, expect, it } from 'vitest';
import { dbEnv } from './db-env';

describe('화면 맨 위 DB 표시', () => {
  it('운영 프로젝트 주소만 운영', () => {
    expect(dbEnv('https://mfamixejxydodclhglbc.supabase.co')).toBe('prod');
    expect(dbEnv('https://mfamixejxydodclhglbc.supabase.co/')).toBe('prod');
  });
  it('다른 주소·비슷한 주소는 시험용', () => {
    expect(dbEnv('https://abcdtest.supabase.co')).toBe('test');
    expect(dbEnv('https://mfamixejxydodclhglbc.supabase.co.evil.com')).toBe('test');
    expect(dbEnv('잘못된 값')).toBe('test');
  });
  it('주소가 없으면 표시 안 함', () => {
    expect(dbEnv(undefined)).toBeNull();
    expect(dbEnv('')).toBeNull();
  });
});
