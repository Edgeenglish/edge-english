# 효과음: 장면·글머리 클릭음(blip.wav) + 글자마다 타이핑 소리
import json,subprocess,sys,wave,numpy as np
T=json.loads(subprocess.check_output(['node','-e','console.log(JSON.stringify(require("./tl.js")))']))
SR=44100;DUR=115;out=np.zeros(SR*DUR)
def load(p):
    w=wave.open(p);a=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16).reshape(-1,w.getnchannels()).mean(1)/32768;return a
blip=load(sys.argv[1]) if len(sys.argv)>1 else None
def put(t,snd,g=1.0):
    i=int(t*SR);n=min(len(snd),len(out)-i)
    if n>0: out[i:i+n]+=snd[:n]*g
rng=np.random.default_rng(7)
def key():
    n=int(SR*0.035);e=np.exp(-np.linspace(0,9,n));noise=rng.standard_normal(n)
    hp=np.diff(noise,prepend=0)  # 높은 소리 쪽
    body=np.sin(2*np.pi*rng.uniform(1600,2400)*np.arange(n)/SR)*np.exp(-np.linspace(0,25,n))
    return (0.6*hp*e+0.5*body)*0.18
ev=[4,16,24,43,57,72,85,97]+[b['at'] for b in T['why']+T['rules']]
for t in ev: put(t,blip)
lines=[(T['date_at'],T['date'])]+[(l['at'],''.join(s[1] for s in l['segs'])) for s in T['secs'] for l in s['lines']]
for at,txt in lines:
    for i,c in enumerate(txt):
        put(at+(i+1)/T['cps'],key(),0.55 if c==' ' else rng.uniform(0.8,1.1))
out=np.clip(out,-1,1);pcm=(np.repeat(out[:,None],2,1)*32767).astype(np.int16)
w=wave.open('audio.wav','wb');w.setnchannels(2);w.setsampwidth(2);w.setframerate(SR);w.writeframes(pcm.tobytes());w.close()
