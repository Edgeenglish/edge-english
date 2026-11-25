import sys, json, soundfile as sf
from kokoro_onnx import Kokoro
M="/tmp/claude-0/kk/"; D=sys.argv[1]
k=Kokoro(M+"kokoro-v1.0.onnx",M+"voices-v1.0.bin")
lines=json.load(open(D+"/lines.json"))
for i,t in enumerate(lines):
    s,sr=k.create(t,voice="af_heart",speed=1.0,lang="en-us"); sf.write(f"{D}/a{i}.wav",s,sr)
print("ok",len(lines))
