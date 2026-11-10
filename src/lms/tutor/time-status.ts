import { timeText, toMin } from './hours';
import { cityTime } from './hours-view';

/** Display only: availability and booking policy remain in their existing handlers. */
export const TIME_COLORS = { open: '#dff3e9', closed: '#E9E8EF', class: '#5b3fe0' } as const;
export const CANT_OPEN_BACKGROUND = 'repeating-linear-gradient(-45deg,#e3e1ea,#e3e1ea 2px,#fafafd 2px,#fafafd 7px)';

export function cantOpenHelp(times: string[], tutorZone: string): string {
  if (!times.length) return 'Striped = can\'t open: outside your permitted class start times.';
  return `Striped = can't open: outside ${timeText(toMin(times[0]))}–${timeText(toMin(times[times.length - 1]))} ${cityTime(tutorZone)} (classes can only start in these hours).`;
}
