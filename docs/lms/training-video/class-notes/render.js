const {chromium}=require('playwright');const fs=require('fs');const {spawn}=require('child_process');
const TL=require('./tl.js');const FPS=30,DUR=115;const only=process.argv[2];
(async()=>{const b=await chromium.launch();const p=await b.newPage({viewport:{width:1280,height:720},deviceScaleFactor:1.5});
await p.addInitScript(`window.TL=${JSON.stringify(TL)}`);await p.goto('file://'+__dirname+'/video.html');await p.evaluate(()=>document.fonts.ready);
if(only){for(const t of only.split(',')){await p.evaluate(x=>{for(let s=Math.max(0,x-6);s<=x;s+=1/30)render(s)},+t);await p.screenshot({path:`chk_${t}.png`})}await b.close();return}
const ff=spawn('ffmpeg',['-y','-f','image2pipe','-framerate',''+FPS,'-i','-','-vf','scale=1920:1080:flags=lanczos','-c:v','libx264','-pix_fmt','yuv420p','-crf','20','-preset','medium','silent.mp4'],{stdio:['pipe','ignore','inherit']});
for(let f=0;f<FPS*DUR;f++){await p.evaluate(x=>render(x),f/FPS);const buf=await p.screenshot({type:'jpeg',quality:92});if(!ff.stdin.write(buf))await new Promise(r=>ff.stdin.once('drain',r));}
ff.stdin.end();await new Promise(r=>ff.on('close',r));await b.close();})();
