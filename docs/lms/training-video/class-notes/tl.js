// timeline
const L=(at,...segs)=>({at,segs});
module.exports={cps:28,why_start:4,doc_start:12,rules_start:97,zoom_at:93.5,date:'Wed, 11/25/2026',date_at:18.5,
why:[{at:4.8,text:'Students review this Google Doc *after every class*.'},{at:6.8,text:"Our class notes are one of our *biggest selling points*. Students *really love* them."}],
rules:[{at:97.8,text:'*Never use AI* for class notes. Write only what the student *actually said* and your own corrections.'},{at:99.8,text:"Only use the Doc in *LMS > Students > Class notes*. *Don't make your own* notes."}],
secs:[
{n:'0',start:12,title:'Write the date first',desc:"Open the Doc in *LMS > Students > Class notes*. *Don't make your own.*<br><br>Share your screen and keep the Doc on screen *for the whole class*.<br><br>At the start of every class, type the date at the top. Use the *same Doc* for the same student every class.",lines:[]},
{n:'1',start:24,title:'Key mistakes + your correction',desc:"Write the student's sentence, add an *arrow* (--> or >), then your correction. Make the key words *bold or red*, and feel free to use colors. *Only the key* mistakes. Have the student *repeat it*.",lines:[
 L(25.5,['','I go to Starbucks yesterday with my friend.']),L(28,['','--> I '],['r','went'],['',' to Starbucks yesterday with my friend.']),L(31.5,['',"I'm boring today. --> I'm "],['r','bored'],['',' today.']),L(34.5,['','She have two child. --> She '],['r','has'],['',' two '],['r','children'],['','.'])]},
{n:'2',start:43,title:'Vocabulary',desc:'Add a *short definition*, a *simple example*, or both.',lines:[
 L(44.5,['bo','starving'],['',' = very hungry']),L(46.2,['bo','exhausted'],['',' = very tired']),L(47.9,['bo','commute'],['',' = the trip to work or school']),L(49.9,['it','e.g. My commute takes about an hour.']),L(52,['bo','sold out'],['',' = there are none left'])]},
{n:'3',start:57,title:'A more natural way to say it',desc:"If there's a *more natural way* to say something, point it out. Students love phrases they can *use right away*.",lines:[
 L(58.5,['','We became friends really fast. --> '],['r','We hit it off.']),L(61.5,['',"I don't have any money. --> "],['r',"I'm broke."]),L(64,['','I ate too much. My stomach is very full.']),L(66.3,['','--> '],['r',"I'm stuffed."])]},
{n:'4',start:72,title:'Related expressions',desc:'When the student learns one expression, show a few *related ones too.*',lines:[
 L(73.5,['bo','tired'],['',' --> exhausted / worn out / I\'m beat']),L(76.3,['bo','hot'],['',' --> boiling hot / scorching hot / I\'m melting']),L(79.3,['bo','cold'],['',' --> freezing cold / chilly / crisp air'])]},
{n:'5',start:85,title:"Type it when they don't understand",desc:"If the student doesn't understand, *rephrase it in simpler words* first. If that still doesn't help, *type it on the screen*.",lines:[
 L(87.5,['q','How long have you been living in Seoul?'])]}
]};
// 오른쪽 밑줄이 다 그어진 뒤에 왼쪽 타이핑 시작 (대표 11/25)
(()=>{const T=module.exports;T.secs.forEach((s,i)=>{const n=(s.desc.match(/\*/g)||[]).length/2;const ready=s.start+0.8+(n-1)*0.5+0.6+0.4;
 if(i===0){T.date_at=Math.max(T.date_at,ready);return}
 const sh=Math.max(0,ready-s.lines[0].at);s.lines.forEach(l=>l.at=+(l.at+sh).toFixed(2));});})();
