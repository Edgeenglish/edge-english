import { describe, expect, it } from 'vitest';
import { pickPlayableVideos } from './teacher-videos';

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
