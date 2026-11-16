import type { LegalSection } from '@/lms/auth/legal';
import { effectiveDateText } from '@/lms/auth/legal';

export function LegalSections({ sections, compact = false }: { sections: LegalSection[]; compact?: boolean }) {
  return (
    <div className={compact ? 'grid gap-3' : 'grid gap-6'}>
      {sections.map((s) => (
        <section key={s.title}>
          <h2 className={compact ? 'text-[13px] font-bold text-[#1d1b2b]' : 'text-[17px] font-bold text-[#1d1b2b]'}>{s.title}</h2>
          {s.body.map((line) => (
            <p key={line} className={compact ? 'mt-1 text-[13px] leading-relaxed text-[#55526a]' : 'mt-2 text-[15px] leading-relaxed text-[#55526a]'}>
              {line}
            </p>
          ))}
        </section>
      ))}
    </div>
  );
}

export default function LegalDoc({ title, intro, sections }: { title: string; intro?: string; sections: LegalSection[] }) {
  return (
    <div className="mx-auto max-w-[800px] px-4 py-15 max-md:py-10">
      <h1 className="text-[28px] font-bold text-[#1d1b2b] max-md:text-[22px]">{title}</h1>
      {intro && <p className="mt-4 text-[15px] leading-relaxed text-[#55526a]">{intro}</p>}
      <div className="mt-8">
        <LegalSections sections={sections} />
      </div>
      <p className="mt-10 text-[14px] text-[#55526a]">시행일: {effectiveDateText()}</p>
    </div>
  );
}
