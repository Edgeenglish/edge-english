'use client';

// 날짜 칸 공통 부품 (QA A-02, 2026-11-06)
// 브라우저 날짜 칸은 PC 에서 연도를 한 자리씩 치는 동안 '0002-11-20' 같은 중간값을 그대로 보낸다.
// 그 값이 상태로 들어가면 날짜 계산이 '존재하지 않는 날짜' 오류로 화면 전체가 멈춤 → 완성된 실제 날짜(2000~2099)만 바깥에 알리고,
// 치는 중인 값은 이 칸 안에서만 들고 있다. 비우면 '' 를 알림. 상태와 저장값이 늘 같은 값이 되게 하는 장치
import { useEffect, useRef, useState, type InputHTMLAttributes } from 'react';
import { isKstDate, type KstDate } from '@/lms/rules/dates';

type Props = Omit<InputHTMLAttributes<HTMLInputElement>, 'type' | 'value' | 'onChange'> & {
  value: KstDate | '';
  onChange: (v: KstDate | '') => void;
  /** 치는 중(미완성)인지 바깥에 알림 — '날짜를 다시 선택해 주세요' 안내용 */
  onPartial?: (partial: boolean) => void;
};

/** '0026-11-12' → '2026-11-12' (두 자리 연도 10~99만) */
const short = (v: string) => (/^00[1-9]\d-/.test(v) ? `20${v.slice(2)}` : v);

export default function DateInput({ value, onChange, onPartial, ...rest }: Props) {
  const [raw, setRaw] = useState<string>(value);
  const last = useRef<string>(value);
  // 바깥에서 값이 바뀌면(원래대로·후보 선택) 칸도 따라감. 치는 중이던 값은 버림
  useEffect(() => {
    if (value !== last.current) {
      last.current = value;
      setRaw(value);
      onPartial?.(false);
    }
  }, [value]); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <input
      {...rest}
      type="date"
      value={raw}
      onChange={(e) => {
        const raw2 = e.target.value;
        setRaw(raw2);
        // 연도를 두 자리만 쳐도(26 → 0026) 2026으로 (대표 11/9). 칸 글자는 치는 중이면 그대로 두고 칸을 떠날 때 바꿈
        const v = short(raw2);
        if (v === '' || isKstDate(v)) {
          last.current = v;
          onPartial?.(false);
          onChange(v);
        } else onPartial?.(true);
      }}
      onBlur={(e) => {
        const v = short(raw);
        if (v !== raw && isKstDate(v)) setRaw(v);
        rest.onBlur?.(e);
      }}
    />
  );
}
