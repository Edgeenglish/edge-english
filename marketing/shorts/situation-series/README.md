# 엣지영어 상황극 쇼츠·릴스 시리즈 (재사용 편집 프로젝트)

같은 제목·이중 자막·마지막 학습 화면 디자인으로 새 편을 만드는 프로젝트.

## 새 편 만들기
1. 원본 영상을 `source/` 에 넣는다.
2. `episodes/ep01-uh-good.json` 을 복사해 제목·자막(시작/끝 초)·(뇌 정지) 같은 작은 자막·확대 구간·마지막 화면 문구만 바꾼다.
3. 실행:
```bash
python3 build.py episodes/ep02-xxx.json --src source/ep02.mp4 --out output
```
- 필요: ffmpeg, Pillow. Pretendard 글꼴은 처음 실행 때 `fonts/` 로 자동 내려받음(OFL 무료 글꼴).
- 자막 시각은 `pip install pocketsphinx` 로 음성 단어 시각을 뽑아 맞췄다(ep01 기준).

## 디자인 기준 (홈페이지 색)
- 보라 `#7D5FFF` · 연보라 `#AA96FF` · 남색 `#140F33` · 강조 노랑 `#FFD401`
- 제목: Pretendard Black 80, 흰 글씨 + 검은 외곽선, 강조 부분 노랑, 위에서 128px
- 영어 자막: ExtraBold 66(최대 폭 800), 한국어: Bold 50, 위에서 1120px (쇼츠·릴스 아래 글·오른쪽 버튼 피함)
- 마지막 학습 화면 5초: 연보라 바탕 + 흰 카드(학습 표현이 가장 크게) → 구독 → 레벨테스트 버튼 → EDGE ENGLISH

## 편 목록
| 편 | 파일 | 길이 |
|---|---|---|
| ep01 영어 못 알아들었는데 일단 대답하는 한국인 특 | output/ep01-uh-good.mp4 | 15초 |
