import { expect, it } from 'vitest';
import { cantOpenHelp } from './time-status';

it('uses the permitted start times and their tutor timezone, not the viewing timezone', () => {
  expect(cantOpenHelp(['06:00', '22:30'], 'Asia/Seoul')).toBe("Striped = can't open: outside 6:00 AM–10:30 PM KST (classes can only start in these hours).");
  expect(cantOpenHelp(['06:00', '22:30'], 'Australia/Sydney')).toContain('6:00 AM–10:30 PM Sydney Time');
  expect(cantOpenHelp(['07:30', '21:00'], 'America/Toronto')).toContain('7:30 AM–9:00 PM Toronto Time');
});
