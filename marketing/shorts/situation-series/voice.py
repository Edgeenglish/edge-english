#!/usr/bin/env python3
"""학습 화면 진행자 음성 만들기 (Supertonic, 무료·오프라인·한국어+영어 같은 목소리).
준비: pip install supertonic soundfile  (처음 실행 때 모델을 huggingface.co 에서 자동으로 받음)
사용: python3 voice.py voices/edge-host-female.json episodes/ep02-voice.json audio/ep02-outro
 → audio/ep02-outro.wav + audio/ep02-outro.timing.json (줄별 시작·끝 초)
대본 JSON: {"lines":[{"lang":"ko","text":"...","pair":true}, ...]}  pair=true 면 앞 줄과 붙여 짧은 간격
"""
import json, sys
import numpy as np
import soundfile as sf
from supertonic import TTS

preset, script, out = sys.argv[1], sys.argv[2], sys.argv[3]
P = json.load(open(preset, encoding="utf-8"))
L = json.load(open(script, encoding="utf-8"))["lines"]
tts = TTS(model=P["model"]) if P.get("model") else TTS()
st = tts.get_voice_style(P["voice_style"])
sr = tts.sample_rate
th = 10 ** (P["trim_db"] / 20)


def trim(a):
    idx = np.where(np.abs(a) > th)[0]
    if len(idx) == 0:
        return a
    s, e = max(idx[0] - int(0.02 * sr), 0), min(idx[-1] + int(0.06 * sr), len(a))
    return a[s:e]


parts, timing, t = [], [], 0.0
for i, ln in enumerate(L):
    w, _ = tts.synthesize(ln["text"], voice_style=st, lang=ln["lang"], speed=ln.get("speed", P["speed"]), total_steps=P["total_steps"])
    w = np.asarray(w, dtype=np.float32).reshape(-1)
    w = trim(w)
    if i > 0:
        gap = P["gap_same_pair"] if ln.get("pair") else P["gap_between"]
        parts.append(np.zeros(int(gap * sr), dtype=np.float32))
        t += gap
    timing.append({"i": i, "text": ln["text"], "start": round(t, 3), "end": round(t + len(w) / sr, 3)})
    parts.append(w)
    t += len(w) / sr
audio = np.concatenate(parts)
audio = audio / max(1e-6, np.abs(audio).max()) * 0.6
sf.write(out + ".wav", audio, sr)
json.dump(timing, open(out + ".timing.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(json.dumps(timing, ensure_ascii=False, indent=1))
