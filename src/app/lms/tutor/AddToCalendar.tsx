'use client';

import { googleCalendarUrl, icsUrl, type CalendarEvent } from '@/lms/calendar/add';

/** Reuse the existing Google template and ICS export; no calendar writes. */
export default function AddToCalendar({ event }: { event: CalendarEvent }) {
  return (
    <details className="text-[13px] text-[#6b6880]">
      <summary className="w-fit cursor-pointer rounded-[8px] py-2 font-semibold">Add to calendar</summary>
      <div className="flex flex-wrap gap-x-4 gap-y-1 pb-2">
        <a href={googleCalendarUrl(event)} target="_blank" rel="noreferrer" className="inline-flex min-h-[36px] items-center underline">Google Calendar</a>
        <a href={icsUrl(event)} className="inline-flex min-h-[36px] items-center underline">Apple / Samsung Calendar</a>
      </div>
    </details>
  );
}
