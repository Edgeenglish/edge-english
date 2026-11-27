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

## 🚫 대표 목소리(학습 음성)는 절대 자르지 않는다 (대표 11/27 매우 강하게 지시)
- 대표가 준 음성 파일은 문장·단어·앞뒤 어느 부분도 마음대로 잘라 내거나 순서를 바꾸지 않는다. 속도도 바꾸지 않는다
- '도입을 짧게' 같은 요청이 와도 음성을 자르지 말고, 자르는 것이 필요해 보이면 먼저 대표에게 묻는다

## ✅ 기본 템플릿 (EP03부터, 대표 11/27 지시) — `outro.style: "learn"`
- 대표가 올린 EP02 최종본(`reference/ep02-final-uploaded.mp4`) 학습 화면을 픽셀 단위로 재서 그대로 만든 것
- 흐린 상황극 배경(블러 40·밝기 0.65) / 위 노란 둥근 제목(#FED100, 250~341px) / 점 3개(y430) / 한국어 흰 글씨(y757) → 영어(87, 강조 단어 노랑, 0.2초 페이드) → 한글 발음(y1058) / 마지막: 흰 글씨 2줄 + 노란 버튼 + 엣지영어
- 편마다 바꾸는 것: 원본 영상, 제목(`title`), 코믹 자막(`badges`), 학습 제목(`outro.label`), 도입 문구, 표현 3개(뜻·영어·강조·발음), 음성 파일과 문장별 시각(`audio/*.timing.json`), 마지막 CTA(`end`의 lines·button — 편마다 다르게 시험)
- 음성: 대표가 준 학습 음성 파일을 그대로 씀(속도 바꾸지 않음)

## 움직이는 코믹 자막 · 대사 자막 (EP03~)
- 코믹 자막 크기 68(EP02의 58보다 약 17% 큼)
- `badges[].track`: [[초, x, y], ...] 를 넣으면 자막이 그 위치를 따라 움직임(머리 위·손가락 옆). 위치는 OpenCV 로 얼굴(Haar)·손가락(CSRT 추적)을 프레임마다 찾아 만든다
- 대사 자막은 `subs[].top` 으로 높이 지정(제목 띠가 있으면 1440 정도)
- 학습 화면 글씨 배율 `outro.text_scale` (EP03 = 1.15)

## 🚩 제목 위치 규칙 (대표 11/27 지시 — 다음 편부터 기본)
- 제목을 화면 맨 위에 얇게 두지 않는다(채널 Shorts 목록·미리보기에서 잘려 안 보임).
- 다른 잘 되는 쇼츠처럼 **위쪽 검은 띠(높이 420px) + 큰 제목(Black 104, 흰색·노랑 강조)**, 영상은 띠 아래로 내린다.
- 편집 설정 JSON 에 `"title_band": 420` 을 넣으면 적용된다(EP01·EP02 는 이전 방식 그대로).

## 디자인 기준 (홈페이지 색)
- 보라 `#7D5FFF` · 연보라 `#AA96FF` · 남색 `#140F33` · 강조 노랑 `#FFD401`
- 제목: Pretendard Black 80, 흰 글씨 + 검은 외곽선, 강조 부분 노랑, 위에서 128px
- 영어 자막: ExtraBold 66(최대 폭 800), 한국어: Bold 50, 위에서 1120px (쇼츠·릴스 아래 글·오른쪽 버튼 피함)
- 마지막 학습 화면 5초: 연보라 바탕 + 흰 카드(학습 표현 Black 92, 가장 크게) → 구독(Bold 57) → 레벨테스트 질문(SemiBold 55)·버튼(ExtraBold 57) → EDGE ENGLISH
- 학습 표현 원어민 음성: 학습 화면 시작 0.6초 뒤 1번. `tts.py` (Kokoro TTS, 무료·오프라인, 미국 여성 af_heart, 속도 0.95)로 만들어 `audio/` 에 두고 JSON `outro.voice` 에 적는다
- 작은 반응 자막: JSON `badges` (예: '(뇌 정지)' 흰 44, 상대 반응 '???' 흰 76 머리 옆)

## 학습 화면 여러 단계 + 진행자 음성 (EP02부터 기본)
- 진행자 목소리 고정 설정: `voices/edge-host-female.json` (Supertonic-3 무료·오프라인, OpenRAIL 상업 이용 가능, 여성 F1, 속도 1.15, 줄 사이 간격 최소). 한국어·영어를 같은 목소리로 읽음
- 대본: `episodes/epXX-voice.json` → `python3 voice.py voices/edge-host-female.json episodes/epXX-voice.json audio/epXX-outro` (wav + 줄별 시각 timing.json)
- 편집 설정 `outro.steps`: question(질문) → expr(1/3·2/3·3/3: 한국어 뜻·영어 가장 크게·한글 발음) → recap(정리). 각 단계는 대본 줄 번호(`line`)에 맞춰 자동으로 바뀜. `outro_duration: "auto"` = 음성 끝 + 1.2초
- 처음 실행 때 모델을 huggingface.co 에서 받음(환경 허용 주소에 huggingface.co·us.aws.cdn.hf.co·cas-server.xethub.hf.co 등 추가해 둠)

## 깔끔한 학습 화면 (EP02 확정 디자인, `outro.style: "clean"`)
- 한 화면에 하나씩: intro(큰 글씨 2줄) → expr(흰 카드: 한국어 뜻 · 영어 가장 크게 · 한글 발음) → end(마무리 2줄 + '무료 레벨테스트 · 프로필 링크' 버튼만)
- 번호(1/3)·구독 문구·정리 화면 없음

## 구간별 화질 보정 (`grade`)
- 필요한 장면 구간에만 필터 적용(전체 적용 금지). 약한 샤프닝(unsharp 0.45 / cas 0.3~0.45), 어두운 장면만 밝기 소폭(eq)
- 보정 전후 같은 프레임을 비교해 깨짐·피부 뭉개짐·얼굴 변형이 없을 때만 넣는다

## 편 목록
| 편 | 파일 | 길이 |
|---|---|---|
| ep01 영어 못 알아들었는데 일단 대답하는 한국인 특 | output/ep01-uh-good.mp4 | 15초 |
| ep02 한국인에게 영어로 주말에 뭐 했냐고 물어보면 | output/ep02-nothing.mp4 (실제 올린 것: reference/ep02-final-uploaded.mp4) | 24.7초 |
| ep03 오션뷰 예약했는데 이게 맞아..? | output/ep03-hotel-oceanview.mp4 | 27.2초 |
