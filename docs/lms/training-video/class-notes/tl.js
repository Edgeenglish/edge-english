// timeline
const L=(at,...segs)=>({at,segs});
module.exports={cps:28,why_start:4,doc_start:16,rules_start:97,zoom_at:93.5,date:'Wed, 11/25/2026',date_at:17.2,
why:[{at:4.8,text:'Students review this Google Doc *after every class*.'},{at:6.8,text:"It's an *essential part* of our classes."},{at:8.8,text:'Share your screen and keep the Doc on screen *for the whole class*.'},{at:10.8,text:'We make the Doc for you. Find the link *in the LMS*.'}],
rules:[{at:97.8,text:'*Never use AI* for class notes. Write only what the student *actually said* and your own corrections.'},{at:99.8,text:'*One or two* good examples per class are enough.'},{at:101.8,text:"Only use the Google Doc we give you. *Don't copy notes* to your personal account."}],
secs:[
{n:'0',start:16,title:'Write the date first',desc:'At the start of every class, type the date at the top. Use the *same Doc* for the same student every class.',lines:[]},
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
