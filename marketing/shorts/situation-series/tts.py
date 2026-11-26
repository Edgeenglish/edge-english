#!/usr/bin/env python3
"""마지막 학습 화면 원어민 발음 음성 만들기 (Kokoro TTS, 무료·오프라인, Apache-2.0).
준비: pip install kokoro-onnx soundfile
      모델 2개 (GitHub thewh1teagle/kokoro-onnx 릴리스 model-files-v1.0): kokoro-v1.0.onnx, voices-v1.0.bin
사용: python3 tts.py "Sorry, could you say that again?" audio/ep01-sorry.wav --model-dir 모델폴더
기본 목소리 af_heart(미국 여성), 속도 0.95 — 시리즈 통일용.
"""
import argparse, os, subprocess, tempfile
from kokoro_onnx import Kokoro
import soundfile as sf
ap = argparse.ArgumentParser()
ap.add_argument("text"); ap.add_argument("out")
ap.add_argument("--model-dir", default=".")
ap.add_argument("--voice", default="af_heart"); ap.add_argument("--speed", type=float, default=0.95)
a = ap.parse_args()
k = Kokoro(os.path.join(a.model_dir, "kokoro-v1.0.onnx"), os.path.join(a.model_dir, "voices-v1.0.bin"))
s, sr = k.create(a.text, voice=a.voice, speed=a.speed, lang="en-us")
tmp = tempfile.mktemp(suffix=".wav"); sf.write(tmp, s, sr)
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", tmp, "-ar", "48000", a.out], check=True)
print(a.out)
