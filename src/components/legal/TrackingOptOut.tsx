'use client';

// 처리방침 9번 '거부 방법' — 방문 통계 끄기/켜기 (대표 11/26). 바꾸면 새로고침해 바로 적용
import { useEffect, useState } from 'react';
import { readConsent, setConsent, type Consent } from '@/lib/tracking';

export default function TrackingOptOut() {
  const [c, setC] = useState<Consent | undefined>(undefined);
  useEffect(() => setC(readConsent()), []);
  if (c === undefined) return null;
  const yes = c !== 'no';
  return (
    <div className="mt-6 flex items-center justify-between gap-3 rounded-[12px] border border-[#e2e0ee] px-4 py-3 text-[15px]">
      <span className="text-[#3d3a52]">방문 통계: {yes ? '켜짐' : '꺼짐'}</span>
      <button
        type="button"
        onClick={() => {
          setConsent(yes ? 'no' : 'yes');
          window.location.reload();
        }}
        className="min-h-[44px] shrink-0 rounded-[10px] border border-[#5b3df0] px-4 text-[14px] font-bold text-[#5b3df0]"
      >
        {yes ? '방문 통계 끄기' : '방문 통계 켜기'}
      </button>
    </div>
  );
}
