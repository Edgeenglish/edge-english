import { CANT_OPEN_BACKGROUND, TIME_COLORS } from '@/lms/tutor/time-status';

export default function TimeStatusLegend({ onHelp }: { onHelp: () => void }) {
  return (
    <div className="mb-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-[12px] text-[#6b6880]">
      {(['Open', 'Closed', 'Class'] as const).map((label) => (
        <span key={label} className="inline-flex items-center gap-1">
          <i aria-hidden className="inline-block h-[12px] w-[14px] rounded-[3px]" style={{ background: TIME_COLORS[label.toLowerCase() as keyof typeof TIME_COLORS] }} />
          {label}
        </span>
      ))}
      <button type="button" aria-haspopup="dialog" onClick={onHelp} className="inline-flex min-h-[32px] items-center gap-1 rounded px-1 focus-visible:outline focus-visible:outline-2 focus-visible:outline-[#5b3fe0]">
        <i aria-hidden className="inline-block h-[12px] w-[14px] rounded-[3px]" style={{ background: CANT_OPEN_BACKGROUND }} />
        Can't open ⓘ
      </button>
    </div>
  );
}
