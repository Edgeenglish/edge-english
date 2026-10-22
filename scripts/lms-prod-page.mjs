// 운영 DB 만들기 복사 버튼 페이지 생성 (대표 안내용, 휴대폰·PC)
// 사용: node scripts/lms-prod-page.mjs → docs/lms/previews/prod-setup.html (SQL 파일을 고치면 다시 만들고 다시 발행)
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

export function buildPage(root) {
  const sql = (p) => readFileSync(join(root, p), 'utf8').trimEnd();
  const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

  let n = 0;
  const step = (title, body, copy) => {
    n += 1;
    const id = `s${n}`;
    return `<section class="step">
    <h2><span class="n">${n}</span>${title}</h2>
    ${body}
    ${copy ? `<button type="button" class="copy" data-target="${id}">복사</button>
    <textarea id="${id}" readonly rows="3" aria-label="${title} SQL">${esc(copy)}</textarea>` : ''}
  </section>`;
  };

  const guardTest = `${sql('supabase/migrations/20261022001100_lms_backup_guard.sql')}

-- 이 DB의 프로젝트 이름 (시험용)
insert into lms_backup.project (name) values ('edgeenglish-lms-test') on conflict do nothing;
select name as 프로젝트_이름, (select count(*) from students) as 학생수 from lms_backup.project;`;

  const steps = [
    step('먼저 시험용 DB에 복구 안전장치', `<p class="expect">붙여 넣는 곳: 프로젝트 <b>edgeenglish-lms-test</b> → SQL Editor → New query → Run.<br>정상: <b>edgeenglish-lms-test · 6</b> 한 줄. 기존 데이터는 그대로예요. 문제 없으면 바로 2번으로</p>`, guardTest),
    step('프로젝트 만들기', `<ol>
      <li>(Pro로 정했으면) 왼쪽 위 조직 메뉴 → <b>New organization</b> → 이름 <code>EdgeEnglish LMS</code> → 요금제 <b>Pro</b>. 시험용 조직은 그대로 둠</li>
      <li><b>New project</b> → 이름 <code>edgeenglish-lms</code> · 지역 <b>Northeast Asia (Seoul)</b></li>
      <li>Database password → <b>Generate</b> → 비밀번호 관리 앱에만 저장 (Claude에게 보내지 않음)</li>
      <li>Data API는 켜 둔 채로 <b>Create</b> → 2~3분 기다림</li></ol>`),
    `<div class="where">여기부터 SQL은: 새 프로젝트 <b>edgeenglish-lms</b> → 왼쪽 <b>SQL Editor</b> → <b>New query</b> → 붙여 넣기 → <b>Run</b>. 단계마다 새 query 하나씩. <b>화면 위쪽 프로젝트 이름이 edgeenglish-lms 인지 꼭 확인</b></div>`,
    step('빈 프로젝트인지 확인', '<p class="expect">정상: 표_개수 <b>0</b> — 41이면 시험용에 들어온 것, 멈추고 Claude에게</p>', sql('supabase/prod-setup/00-empty-check.sql')),
    step('표 만들기 (길어요)', '<p class="expect">정상: Success. No rows returned — 오류면 아무것도 안 만들어짐, 오류 첫 줄만 Claude에게</p>', sql('supabase/prod-setup/01-schema.sql')),
    step('확인 (읽기만)', '<p class="expect">정상: 8줄 모두 <b>통과</b></p>', sql('supabase/prod-setup/02-check.sql')),
    step('로그인 설정 (화면)', `<p class="expect">시험용 프로젝트와 똑같이</p><ol>
      <li>Authentication → Sign In / Providers → <b>Allow new users to sign up: 끄기</b></li>
      <li>Email: Confirm email 켬 · Email OTP Length <b>6</b> · OTP Expiration <b>600</b></li>
      <li>Multi-Factor: <b>TOTP 켜짐</b> 확인</li>
      <li>Resend → API Keys → 새 키 <code>supabase-prod</code> (Sending access · edgeenglish.kr) → Supabase Authentication → Emails → <b>SMTP Settings</b>: Host <code>smtp.resend.com</code> · Port <code>465</code> · Username <code>resend</code> · Password = 그 키 · Sender <code>support@edgeenglish.kr</code> · 이름 <code>엣지영어</code></li>
      <li>Emails → Templates → <b>Magic Link</b>: 시험용 프로젝트의 제목·본문을 그대로 복사해 붙여 넣기</li></ol>`),
    step('대표 계정 만들기 (화면)', `<ol>
      <li>Authentication → Users → <b>Add user</b> → <b>Create new user</b></li>
      <li>이메일 <code>support@edgeenglish.kr</code> · 비밀번호는 아무 긴 값 (쓰지 않음) · <b>Auto Confirm User 체크</b></li>
      <li>Send invitation은 쓰지 않음 (가입을 끄면 초대 계정은 로그인이 안 됨)</li></ol>`),
    step('대표 계정을 운영자(대표)로 연결', '<p class="expect">정상: support@edgeenglish.kr · admin · owner 한 줄 (0줄이면 7번을 먼저)</p>', sql('supabase/prod-setup/03-owner.sql')),
    step('Claude에게 알려 주기', `<ol>
      <li>왼쪽 <b>Database → Backups</b> 화면 캡처 (요금제별 자동 백업이 실제로 어떻게 보이는지 확인용)</li>
      <li>Project Settings → Data API → Project URL 의 <code>xxxx.supabase.co</code> 부분 (비밀 아님)</li>
      <li>Secret key·DB 비밀번호는 보내지 않음</li></ol>`),
  ];

  const backup = sql('supabase/backup/backup.sql');

  // Artifact 발행용: 문서 뼈대(doctype·head·body)는 발행할 때 붙으므로 넣지 않음
  const html = `<title>운영 DB 만들기</title>
<meta name="claude:viewport-fit-sides" content="cover">
<style>
:root { --bg:#f6f5fa; --card:#ffffff; --line:#e6e3ef; --fg:#1d1b2b; --sub:#6b6880; --accent:#7d5fff; --ok:#1f6b44; --okbg:#e3f6ea; --warnbg:#fff8d6; --warn:#5c4a00; color-scheme:light; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg:#15141c; --card:#232130; --line:#3a374c; --fg:#f1effa; --sub:#aaa6c0; --accent:#8f76ff; --ok:#9be0b5; --okbg:#17301f; --warnbg:#3d3210; --warn:#ffe08a; color-scheme:dark } }
:root[data-theme="dark"] { --bg:#15141c; --card:#232130; --line:#3a374c; --fg:#f1effa; --sub:#aaa6c0; --accent:#8f76ff; --ok:#9be0b5; --okbg:#17301f; --warnbg:#3d3210; --warn:#ffe08a; color-scheme:dark }
body { margin:0; background:var(--bg); color:var(--fg); font-family:-apple-system,'Apple SD Gothic Neo','Noto Sans KR',system-ui,sans-serif; font-size:15px; line-height:1.55; }
.wrap { max-width:640px; margin:0 auto; padding-block:20px 48px; padding-left:max(16px, env(safe-area-inset-left, 0px)); padding-right:max(16px, env(safe-area-inset-right, 0px)); }
h1 { font-size:21px; margin:0 0 6px; }
h3 { font-size:17px; margin:28px 0 4px; }
.lead { color:var(--sub); margin:0 0 16px; }
.where { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:12px 14px; margin-top:12px; }
.step { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:14px; margin-top:12px; }
.step h2 { font-size:16px; margin:0; display:flex; align-items:center; }
.step ol { margin:8px 0 0; padding-left:20px; }
.step li { margin-bottom:4px; }
.n { display:inline-flex; width:26px; height:26px; border-radius:50%; background:var(--accent); color:#fff; font-size:14px; align-items:center; justify-content:center; margin-right:8px; flex-shrink:0; }
.expect { color:var(--sub); font-size:14px; margin:6px 0 10px; }
code { font-family:ui-monospace,Menlo,monospace; font-size:13px; background:var(--bg); border:1px solid var(--line); border-radius:6px; padding:0 4px; overflow-wrap:anywhere; }
.copy { width:100%; min-height:50px; border:0; border-radius:12px; background:var(--accent); color:#fff; font-size:16px; font-weight:700; font-family:inherit; cursor:pointer; }
.copy.done { background:var(--okbg); color:var(--ok); }
.copy:focus-visible { outline:3px solid var(--fg); outline-offset:2px; }
textarea { width:100%; box-sizing:border-box; margin-top:8px; border:1px solid var(--line); border-radius:10px; background:var(--bg); color:var(--sub); font-family:ui-monospace,Menlo,monospace; font-size:11.5px; padding:8px; resize:vertical; }
.note { background:var(--warnbg); color:var(--warn); border-radius:12px; padding:10px 12px; margin-top:12px; font-size:14px; }
</style>
<div class="wrap">
  <h1>운영 DB 만들기 · edgeenglish-lms</h1>
  <p class="lead">번호 순서대로. 약 20분, PC 권장. 1번만 시험용(edgeenglish-lms-test)에서, 나머지는 새 운영 프로젝트에서 해요.</p>
  <p class="note">시작 전: 요금제(Free / Pro)를 채팅에서 먼저 정해 주세요. 운영 DB에는 가상 데이터를 넣지 않고, 실제 학생 입력·홈페이지 연결은 다음 단계예요.</p>
  ${steps.join('\n  ')}
  <p class="note">오류가 나면 오류 첫 줄만 Claude에게 보내 주세요. 1·4번은 한 묶음이라 오류가 나면 아무것도 바뀌지 않아요.</p>

  <h3>운영 DB를 바꾸기 직전 — 매번 백업</h3>
  <p class="lead">읽기만 하는 SQL이에요. 데이터를 바꾸지 않아요.</p>
  <section class="step">
  <h2><span class="n">B</span>직접 백업 받기</h2>
  <ol>
    <li>[복사] → edgeenglish-lms SQL Editor → New query → 붙여 넣기 → Run</li>
    <li>결과 표 오른쪽 위 <b>Export → Download CSV</b></li>
    <li>파일 이름 앞에 날짜 (예: <code>2026-10-25_적용전_lms-backup.csv</code>) → 구글 드라이브 <b>LMS 백업</b> 폴더</li>
    <li>실제 개인정보가 든 파일이라 채팅·GitHub에 올리지 않아요. 복구가 필요할 때만 Claude에게</li>
  </ol>
  <p class="expect">정상: 맨 위 _meta, 그 아래 표 41줄, 맨 아래 _sequences · _auth_users</p>
  <button type="button" class="copy" data-target="bk">복사</button>
  <textarea id="bk" readonly rows="3" aria-label="백업 SQL">${esc(backup)}</textarea>
  </section>
  <p class="note">연습: 같은 SQL을 <b>시험용</b>(edgeenglish-lms-test)에서 한 번 실행해 CSV를 Claude에게 올려 주시면 복구 연습을 해 둘게요 (시험용은 가상 데이터라 올려도 괜찮아요).</p>
</div>
<script>
document.querySelectorAll('.copy').forEach(function (btn) {
  btn.addEventListener('click', function () {
    var ta = document.getElementById(btn.dataset.target);
    function ok() { btn.textContent = '복사됨 ✓ — Supabase에 붙여 넣기'; btn.classList.add('done'); }
    function fallback() { ta.focus(); ta.select(); try { if (document.execCommand('copy')) return ok(); } catch (e) {} btn.textContent = '자동 복사가 안 돼요 — 아래 글을 길게 눌러 전체 선택·복사'; }
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(ta.value).then(ok, fallback); else fallback();
  });
});
</script>
  `;
  return html;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const root = join(import.meta.dirname, '..');
  writeFileSync(join(root, 'docs/lms/previews/prod-setup.html'), buildPage(root));
  console.log('docs/lms/previews/prod-setup.html 생성');
}
