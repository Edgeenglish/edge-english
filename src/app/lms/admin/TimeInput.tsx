'use client';

// 시각 입력칸: 숫자로 바로 침 ('1730' → 17:30). 칸을 떠나면 'HH:MM'으로 정리. 값은 'HH:MM' 또는 ''(못 읽음)

import { useEffect, useState } from 'react';
import { parseTimeText } from '@/lms/admin/time-text';

type Props = { value: string; onChange: (v: string) => void; id?: string; disabled?: boolean; className?: string; 'aria-label'?: string };

export default function TimeInput({ value, onChange, id, disabled, className, 'aria-label': label }: Props) {
  const [text, setText] = useState(value);
  useEffect(() => {
    // 밖에서 값이 바뀌면(다른 줄 시각 자동 맞춤 등) 따라감. 치는 중인 글자가 같은 시각이면 그대로 둠
    if (parseTimeText(text) !== value) setText(value);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value]);
  const bad = text.trim() !== '' && parseTimeText(text) === null;
  return (
    <input
      id={id}
      aria-label={label}
      type="text"
      inputMode="numeric"
      autoComplete="off"
      placeholder="00:00"
      value={text}
      disabled={disabled}
      onChange={(e) => {
        setText(e.target.value);
        onChange(parseTimeText(e.target.value) ?? '');
      }}
      onBlur={() => {
        const v = parseTimeText(text);
        if (v) setText(v);
      }}
      aria-invalid={bad || undefined}
      className={`${className ?? ''} ${bad ? '!border-[#e8a39e]' : ''}`}
    />
  );
}
