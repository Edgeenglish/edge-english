// 홈 '엣지영어에서는 이런 선생님들과 수업해요' 영상 6개 (대표 11/25)
// 대표가 유튜브 재생목록에서 영상과 순서를 직접 관리 → 재생 가능한 영상 중 재생목록 순서대로 위 6개를 홈에 보여 줌.
// 공식 YouTube Data API v3 사용. 설정은 Vercel 환경변수 YOUTUBE_API_KEY · YOUTUBE_PLAYLIST_ID (서버에서만 읽음, 브라우저에 노출 안 됨)
// 둘 중 하나라도 없으면 섹션을 숨김.

export type TeacherVideo = { id: string; title: string; thumb: string };

const REVALIDATE_SECONDS = 3600; // 1시간마다 갱신 (대표 11/25)
export const TEACHER_VIDEO_LIMIT = 6;

type PlaylistItem = {
  snippet?: {
    title?: string;
    resourceId?: { videoId?: string };
    thumbnails?: Record<string, { url?: string } | undefined>;
  };
  status?: { privacyStatus?: string };
};
type VideoStatus = { id?: string; status?: { embeddable?: boolean; privacyStatus?: string; uploadStatus?: string } };

const PLAYABLE_PRIVACY = ['public', 'unlisted'];

function thumbOf(item: PlaylistItem, id: string): string {
  const t = item.snippet?.thumbnails ?? {};
  return t.maxres?.url ?? t.standard?.url ?? t.high?.url ?? t.medium?.url ?? `https://i.ytimg.com/vi/${id}/hqdefault.jpg`;
}

/**
 * 재생목록 순서를 그대로 두고, 홈페이지 안에서 재생할 수 없는 영상(비공개·삭제·외부 재생 제한·처리 중)을 빼고 위에서 limit 개.
 * statuses = videos.list(part=status) 결과 (영상 번호별 상태)
 */
export function pickPlayableVideos(items: PlaylistItem[], statuses: VideoStatus[], limit = TEACHER_VIDEO_LIMIT): TeacherVideo[] {
  const byId = new Map(statuses.filter((s) => s.id).map((s) => [s.id as string, s]));
  const out: TeacherVideo[] = [];
  const seen = new Set<string>();
  for (const item of items) {
    const id = item.snippet?.resourceId?.videoId;
    const title = (item.snippet?.title ?? '').trim();
    if (!id || !title || seen.has(id)) continue;
    if (title === 'Private video' || title === 'Deleted video') continue;
    if (item.status?.privacyStatus && !PLAYABLE_PRIVACY.includes(item.status.privacyStatus)) continue;
    const st = byId.get(id);
    if (!st?.status) continue; // 상태를 못 받은 영상(삭제 등)은 뺌
    if (st.status.embeddable !== true) continue;
    if (!PLAYABLE_PRIVACY.includes(st.status.privacyStatus ?? '')) continue;
    if (st.status.uploadStatus && st.status.uploadStatus !== 'processed') continue;
    seen.add(id);
    out.push({ id, title, thumb: thumbOf(item, id) });
    if (out.length >= limit) break;
  }
  return out;
}

async function api<T>(path: string, params: Record<string, string>, key: string): Promise<T> {
  const base = process.env.YOUTUBE_API_BASE ?? 'https://www.googleapis.com/youtube/v3'; // YOUTUBE_API_BASE 는 로컬 시험용(가짜 서버)
  const url = `${base}/${path}?${new URLSearchParams(params).toString()}`;
  const res = await fetch(url, {
    headers: { 'x-goog-api-key': key },
    next: { revalidate: REVALIDATE_SECONDS, tags: ['teacher-videos'] },
  });
  if (!res.ok) throw new Error(`YouTube API 응답 오류: ${res.status}`);
  return (await res.json()) as T;
}

export async function getTeacherVideos(): Promise<TeacherVideo[]> {
  const key = process.env.YOUTUBE_API_KEY;
  const playlistId = process.env.YOUTUBE_PLAYLIST_ID;
  if (!key || !playlistId) return [];

  try {
    const list = await api<{ items?: PlaylistItem[] }>('playlistItems', { part: 'snippet,status', playlistId, maxResults: '50' }, key);
    const items = list.items ?? [];
    const ids = [...new Set(items.map((i) => i.snippet?.resourceId?.videoId).filter((v): v is string => !!v))].slice(0, 50);
    if (ids.length === 0) return [];
    const vids = await api<{ items?: VideoStatus[] }>('videos', { part: 'status', id: ids.join(',') }, key);
    return pickPlayableVideos(items, vids.items ?? []);
  } catch (error) {
    // 배포(빌드) 중 유튜브가 응답하지 않으면 이 섹션만 숨기고 빌드를 이어감
    if (process.env.NEXT_PHASE === 'phase-production-build') {
      console.error(error);
      return [];
    }
    // 운영 중에는 오류를 던져, 마지막으로 정상 생성된 페이지(영상 6개)가 계속 보이게 함 (후기 연동과 같은 방식)
    throw error;
  }
}
