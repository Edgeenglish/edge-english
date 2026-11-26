'use client';

// 처리방침 9번 '거부·철회 방법' — 방문 통계 동의 상태를 보이고 바꿈 (대표 11/26). 바꾸면 새로고침해 바로 적용
import { useEffect, useState } from 'react';
import { readConsent, setConsent, type Consent } from '@/lib/tracking';

export default function TrackingOptOut() {
  const [c, setC] = useState<Consent | undefined>(undefined);
  useEffect(() => setC(readConsent()), []);
  if (c === undefined) return null;
  const yes = c === 'yes';
  return (
    <div className="mt-6 flex items-center justify-between gap-3 rounded-[12px] border border-[#e2e0ee] px-4 py-3 text-[15px]">
      <span className="text-[#3d3a52]">방문 통계: {yes ? '동의함' : '동의 안 함'}</span>
      <button
        type="button"
        onClick={() => {
          setConsent(yes ? 'no' : 'yes');
          window.location.reload();
        }}
        className="min-h-[44px] shrink-0 rounded-[10px] border border-[#5b3df0] px-4 text-[14px] font-bold text-[#5b3df0]"
      >
        {yes ? '방문 통계 동의 철회' : '방문 통계 동의하기'}
      </button>
    </div>
  );
}
