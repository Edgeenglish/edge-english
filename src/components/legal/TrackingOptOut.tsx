'use client';

// 처리방침 9번 '거부 방법' — 누르면 이 브라우저에서 GA4·Clarity 를 안 불러옴 (다시 누르면 켬, 대표 11/26)
import { useEffect, useState } from 'react';
import { setTrackingOff, trackingOff } from '@/lib/tracking';

export default function TrackingOptOut() {
  const [off, setOff] = useState<boolean | null>(null);
  useEffect(() => setOff(trackingOff()), []);
  if (off === null) return null;
  return (
    <button
      type="button"
      onClick={() => {
        setTrackingOff(!off);
        setOff(!off);
      }}
      className={`mx-auto mt-6 block min-h-[44px] w-full max-w-[800px] rounded-[10px] px-4 text-[15px] font-bold ${off ? 'bg-[#e7e5ee] text-[#69667c]' : 'bg-[#5b3df0] text-white'}`}
    >
      {off ? '방문 통계 꺼짐 ✓' : '방문 통계 끄기'}
    </button>
  );
}
