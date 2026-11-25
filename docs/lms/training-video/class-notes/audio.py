# 효과음: 장면·글머리 클릭음(blip.wav) + 글자마다 타이핑 소리
import json,subprocess,sys,wave,numpy as np
T=json.loads(subprocess.check_output(['node','-e','console.log(JSON.stringify(require("./tl.js")))']))
SR=44100;DUR=T['total'];out=np.zeros(SR*DUR)
def load(p):
    w=wave.open(p);a=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16).reshape(-1,w.getnchannels()).mean(1)/32768;return a
blip=load(sys.argv[1]) if len(sys.argv)>1 else None
def put(t,snd,g=1.0):
    i=int(t*SR);n=min(len(snd),len(out)-i)
    if n>0: out[i:i+n]+=snd[:n]*g
rng=np.random.default_rng(7)
def key():
    # 부드러운 '톡' 소리 (대표 11/25 '너무 시끄러워'): 높은 잡음 빼고 낮은 소리 + 짧은 여운
    n=int(SR*0.045);x=np.arange(n)/SR
    f=rng.uniform(520,760)
    body=np.sin(2*np.pi*f*x)*np.exp(-x*140)
    tick=np.convolve(rng.standard_normal(n),np.ones(24)/24,'same')*np.exp(-x*400)  # 잡음은 부드럽게 걸러 아주 조금
    att=np.minimum(1,x/0.002)
    return (0.8*body+0.25*tick)*att*0.10
ev=[T['why_start'],T['doc_start']]+[x['start'] for x in T['secs'][1:]]+[T['rules_start'],T['thanks_start']]+[b['at'] for b in T['why']+T['rules']]
for t in ev: put(t,blip)
lines=[(T['date_at'],T['date'])]+[(l['at'],''.join(s[1] for s in l['segs'])) for s in T['secs'] for l in s['lines']]
for at,txt in lines:
    for i,c in enumerate(txt):
        put(at+(i+1)/T['cps'],key(),0.55 if c==' ' else rng.uniform(0.8,1.1))
out=np.clip(out,-1,1);pcm=(np.repeat(out[:,None],2,1)*32767).astype(np.int16)
w=wave.open('audio.wav','wb');w.setnchannels(2);w.setsampwidth(2);w.setframerate(SR);w.writeframes(pcm.tobytes());w.close()
