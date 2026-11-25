import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { getTeacherVideos, pickPlayableVideos } from './teacher-videos';

const item = (id: string, title = `영상 ${id}`, privacy = 'public') => ({
  snippet: { title, resourceId: { videoId: id }, thumbnails: { high: { url: `https://img/${id}.jpg` } } },
  status: { privacyStatus: privacy },
});
const ok = (id: string) => ({ id, status: { embeddable: true, privacyStatus: 'public', uploadStatus: 'processed' } });

describe('홈 강사 영상 고르기 (대표 11/25)', () => {
  it('재생목록 순서 그대로 위에서 6개', () => {
    const ids = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];
    const r = pickPlayableVideos(ids.map((i) => item(i)), ids.map(ok));
    expect(r.map((v) => v.id)).toEqual(['a', 'b', 'c', 'd', 'e', 'f']);
    expect(r[0].thumb).toBe('https://img/a.jpg');
  });
  it('비공개·삭제·외부 재생 제한·처리 중 영상은 빼고 재생 가능한 것 중 위에서 6개', () => {
    const items = [item('a'), item('b', 'Private video', 'private'), item('c', 'Deleted video'), item('d'), item('e'), item('f'), item('g'), item('h'), item('i')];
    const st = [ok('a'), { id: 'd', status: { embeddable: false, privacyStatus: 'public', uploadStatus: 'processed' } }, ok('e'), ok('f'), ok('g'), { id: 'h', status: { embeddable: true, privacyStatus: 'public', uploadStatus: 'uploaded' } }, ok('i')];
    expect(pickPlayableVideos(items, st).map((v) => v.id)).toEqual(['a', 'e', 'f', 'g', 'i']);
  });
  it('일부 공개(unlisted)는 포함, 비공개는 제외', () => {
    const items = [item('a', '영상 a', 'unlisted'), item('b', '영상 b', 'private')];
    const st = [{ id: 'a', status: { embeddable: true, privacyStatus: 'unlisted', uploadStatus: 'processed' } }, { id: 'b', status: { embeddable: true, privacyStatus: 'private', uploadStatus: 'processed' } }];
    expect(pickPlayableVideos(items, st).map((v) => v.id)).toEqual(['a']);
  });
  it('같은 영상이 두 번 있으면 한 번만, 상태를 못 받은 영상은 뺌', () => {
    const items = [item('a'), item('a'), item('z')];
    expect(pickPlayableVideos(items, [ok('a')]).map((v) => v.id)).toEqual(['a']);
  });
  it('썸네일 정보가 없으면 영상 번호로 기본 주소', () => {
    const it = { snippet: { title: '영상', resourceId: { videoId: 'x1' } }, status: { privacyStatus: 'public' } };
    expect(pickPlayableVideos([it], [ok('x1')])[0].thumb).toBe('https://i.ytimg.com/vi/x1/hqdefault.jpg');
  });
  it('재생 가능한 영상이 없으면 빈 목록', () => {
    expect(pickPlayableVideos([item('a')], [])).toEqual([]);
  });
});

// 연동 실패와 대표가 재생목록에서 일부러 영상을 지운 경우를 구분 (대표 11/25)
describe('getTeacherVideos: 실패 vs 의도적 삭제', () => {
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });
  const withList = (ids: string[]) =>
    vi.fn(async (url: string) =>
      String(url).includes('/playlistItems')
        ? json({ items: ids.map((i) => item(i)) })
        : json({ items: ids.map(ok) }),
    );
  beforeEach(() => {
    process.env.YOUTUBE_API_KEY = 'k';
    process.env.YOUTUBE_PLAYLIST_ID = 'PL1';
    delete process.env.NEXT_PHASE;
  });
  afterEach(() => {
    vi.unstubAllGlobals();
    delete process.env.YOUTUBE_API_KEY;
    delete process.env.YOUTUBE_PLAYLIST_ID;
    delete process.env.NEXT_PHASE;
  });

  it('영상을 지우면(정상 응답) 목록에서도 빠짐', async () => {
    vi.stubGlobal('fetch', withList(['a', 'b', 'c']));
    expect((await getTeacherVideos()).map((v) => v.id)).toEqual(['a', 'b', 'c']);
    vi.stubGlobal('fetch', withList(['a', 'c']));
    expect((await getTeacherVideos()).map((v) => v.id)).toEqual(['a', 'c']);
  });
  it('재생목록을 비우면(정상 응답) 섹션이 사라짐(빈 목록)', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => json({ items: [] })));
    expect(await getTeacherVideos()).toEqual([]);
  });
  it('유튜브 오류(500)면 던져서 마지막 정상 페이지를 유지', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => json({ error: 'x' }, 500)));
    await expect(getTeacherVideos()).rejects.toThrow('YouTube API 응답 오류: 500');
  });
  it('네트워크 오류도 던짐', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('network'); }));
    await expect(getTeacherVideos()).rejects.toThrow('network');
  });
  it('빌드 중 오류는 섹션만 숨기고 빌드를 이어감', async () => {
    process.env.NEXT_PHASE = 'phase-production-build';
    vi.stubGlobal('fetch', vi.fn(async () => json({}, 500)));
    expect(await getTeacherVideos()).toEqual([]);
  });
  it('환경변수가 없으면 호출하지 않고 숨김', async () => {
    delete process.env.YOUTUBE_API_KEY;
    const f = vi.fn();
    vi.stubGlobal('fetch', f);
    expect(await getTeacherVideos()).toEqual([]);
    expect(f).not.toHaveBeenCalled();
  });
});
