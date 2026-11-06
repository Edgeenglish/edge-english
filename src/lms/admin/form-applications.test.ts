import { describe, expect, it } from 'vitest';
import { applicationDate, applicationFromGoogle, type GoogleApplication } from './form-applications';
import { draftFromForm } from './registration';
import { withinAvailability } from '../rules/booking';
const response: GoogleApplication = { id: 'response-1', submittedAt: '2026-10-31T16:00:00Z', email: 'student@example.com', items: [
  {id:'name',title:'성함을 적어주세요.',type:'TEXT',value:'김하준'},
  {id:'city',title:'사는 도시',type:'TEXT',value:'멜버른'},
  {id:'country',title:'지금 사는 나라',type:'MULTIPLE_CHOICE',value:'호주'},
  {id:'duration',title:'수업 길이를 선택해주세요.',type:'MULTIPLE_CHOICE',value:'40분(인기)'},
  {id:'weekly',title:'수업 횟수를 선택해주세요.',type:'MULTIPLE_CHOICE',value:'주 2회'},
  {id:'term',title:'  수강 기간',type:'MULTIPLE_CHOICE',value:'3개월 (5% 할인)'},
  {id:'grid',title:'희망 수업 시작 시각 (지금 사는 곳의 시각 기준)',type:'CHECKBOX_GRID',rows:['오전 12:00','오후 12:30','오후 7:30'],value:[[],['월'],['화','목']]},
]};
describe('Google Forms applications',()=> {
  it('maps questions to a reusable student draft without spreadsheet column positions',()=> {
    const form=applicationFromGoogle(response);
    expect(draftFromForm(form)).toMatchObject({nameKo:'김하준',email:'student@example.com',country:'호주',city:'멜버른',timezone:'Australia/Melbourne',durationMin:40,weeklyCount:2,weeks:12});
    expect(form.wishGrid).toEqual([{weekday:1,from:'12:30',to:'12:30',startOnly:true},{weekday:2,from:'19:30',to:'19:30',startOnly:true},{weekday:4,from:'19:30',to:'19:30',startOnly:true}]);
  });
  it('groups year/month/day by Korean submission date at year boundaries',()=> {
    expect(applicationDate(response)).toBe('2026-11-01');
    expect(applicationDate({submittedAt:'2026-12-31T16:00:00Z'})).toBe('2027-01-01');
    expect(applicationDate({submittedAt:'2025-10-03 11:00'})).toBe('2025-10-03');
  });
  it('uses an exact selected start for 50 minute lessons, without adding adjacent starts',()=> {
    const windows=[{weekday:2,startLocal:'19:30',endLocal:'19:30',timezone:'Asia/Seoul',effectiveFrom:'2026-01-01',effectiveTo:null,startOnly:true}];
    const start=new Date('2026-11-03T19:30:00+09:00');
    expect(withinAvailability(start,new Date(start.getTime()+50*60000),windows)).toBe(true);
    expect(withinAvailability(new Date(start.getTime()+30*60000),new Date(start.getTime()+80*60000),windows)).toBe(false);
  });
  it('leaves unknown answers blank rather than inventing defaults',()=> {
    const form=applicationFromGoogle({...response,items:[]});
    expect(draftFromForm(form)).toMatchObject({nameKo:'',durationMin:null,weeklyCount:null,weeks:null,timezone:''});
  });
});
