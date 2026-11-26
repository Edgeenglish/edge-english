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
- 마지막 학습 화면 5초: 연보라 바탕 + 흰 카드(학습 표현 Black 92, 가장 크게) → 구독(Bold 57) → 레벨테스트 질문(SemiBold 55)·버튼(ExtraBold 57) → EDGE ENGLISH
- 학습 표현 원어민 음성: 학습 화면 시작 0.6초 뒤 1번. `tts.py` (Kokoro TTS, 무료·오프라인, 미국 여성 af_heart, 속도 0.95)로 만들어 `audio/` 에 두고 JSON `outro.voice` 에 적는다
- 작은 반응 자막: JSON `badges` (예: '(뇌 정지)' 흰 44, 상대 반응 '???' 흰 76 머리 옆)

## 학습 화면 여러 단계 + 진행자 음성 (EP02부터 기본)
- 진행자 목소리 고정 설정: `voices/edge-host-female.json` (Supertonic-3 무료·오프라인, OpenRAIL 상업 이용 가능, 여성 F1, 속도 1.15, 줄 사이 간격 최소). 한국어·영어를 같은 목소리로 읽음
- 대본: `episodes/epXX-voice.json` → `python3 voice.py voices/edge-host-female.json episodes/epXX-voice.json audio/epXX-outro` (wav + 줄별 시각 timing.json)
- 편집 설정 `outro.steps`: question(질문) → expr(1/3·2/3·3/3: 한국어 뜻·영어 가장 크게·한글 발음) → recap(정리). 각 단계는 대본 줄 번호(`line`)에 맞춰 자동으로 바뀜. `outro_duration: "auto"` = 음성 끝 + 1.2초
- 처음 실행 때 모델을 huggingface.co 에서 받음(환경 허용 주소에 huggingface.co·us.aws.cdn.hf.co·cas-server.xethub.hf.co 등 추가해 둠)

## 편 목록
| 편 | 파일 | 길이 |
|---|---|---|
| ep01 영어 못 알아들었는데 일단 대답하는 한국인 특 | output/ep01-uh-good.mp4 | 15초 |
| ep02 한국인에게 영어로 주말에 뭐 했냐고 물어보면 | output/ep02-nothing.mp4 | 24.7초 |
