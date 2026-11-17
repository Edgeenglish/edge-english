#!/usr/bin/env bash
# 운영 배포 직후 점검 (2026-11-17 대표 긴급): 로그인 전 화면에 내부용 표시가 보이면 실패
# 사용: bash scripts/check-public-pages.sh [사이트 주소, 기본 https://edgeenglish.kr]
set -u
BASE="${1:-https://edgeenglish.kr}"
PAGES=(/ /lms/login /price /faq /privacy /terms)
BAD='운영 DB|시험용 DB|가상 데이터|실제 수강생 등록·수업 일정이 저장되는 환경'
fail=0
for p in "${PAGES[@]}"; do
  html=$(curl -sL -m 30 "$BASE$p")
  if [ -z "$html" ]; then echo "확인 못 함: $p (응답 없음)"; fail=1; continue; fi
  hit=$(printf '%s' "$html" | grep -oE "$BAD" | sort -u | tr '\n' ' ')
  if [ -n "$hit" ]; then echo "내부용 표시 발견: $p → $hit"; fail=1; else echo "통과: $p"; fi
done
exit $fail
