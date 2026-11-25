# 배경음악: 직접 합성한 잔잔한 피아노풍 반주 (저작권 걱정 없음). 결과 music.wav
import numpy as np,wave
SR=44100;DUR=115;BPM=88;beat=60/BPM
out=np.zeros(int(SR*DUR))
def note(f,t,d,g):
    n=int(SR*d);x=np.arange(n)/SR
    env=np.exp(-x*3.0)*np.minimum(1,x/0.01)
    s=(np.sin(2*np.pi*f*x)+0.35*np.sin(4*np.pi*f*x)+0.1*np.sin(6*np.pi*f*x))*env*g
    i=int(t*SR);m=min(n,len(out)-i)
    if m>0: out[i:i+m]+=s[:m]
def hz(m): return 440*2**((m-69)/12)
# C - G - Am - F (한 마디 4박)
prog=[[48,55,60,64,67],[43,55,59,62,67],[45,57,60,64,69],[41,53,57,60,65]]
arp=[2,3,4,3,2,3,4,3]
t=0;bar=0
while t<DUR:
    ch=prog[bar%4]
    note(hz(ch[0]),t,beat*4,0.22)            # 베이스
    for k,a in enumerate(arp):               # 8분음표 아르페지오
        note(hz(ch[a]+12),t+k*beat/2,beat*1.5,0.07 if k%2 else 0.09)
    t+=beat*4;bar+=1
fade=np.ones_like(out);fi=int(SR*1.5);fo=int(SR*3)
fade[:fi]=np.linspace(0,1,fi);fade[-fo:]=np.linspace(1,0,fo)
out=out*fade;out=out/np.abs(out).max()*0.16   # 타이핑 소리보다 작게
pcm=(np.repeat(out[:,None],2,1)*32767).astype(np.int16)
w=wave.open('music.wav','wb');w.setnchannels(2);w.setsampwidth(2);w.setframerate(SR);w.writeframes(pcm.tobytes());w.close()
