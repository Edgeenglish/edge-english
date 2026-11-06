-- 읽기 전용 검증: 지역·서머타임 주에 관계없이 현지 06:00~22:30 시작만 반환.
with cases(zone, monday) as (
  values ('Asia/Seoul', date '2026-11-02'), ('Asia/Manila', date '2026-11-02'),
         ('America/New_York', date '2026-10-26'), ('America/New_York', date '2026-11-02'),
         ('Australia/Melbourne', date '2026-09-28'), ('Australia/Melbourne', date '2026-10-05')
), results as (
  select zone, monday, array(select public.lms_hours_times(zone, monday)) as slots from cases
)
select zone, monday,
       cardinality(slots) = 34 and slots[1] = time '06:00' and slots[34] = time '22:30'
       and not (time '05:30' = any(slots)) and not (time '23:00' = any(slots)) as passed
from results;
