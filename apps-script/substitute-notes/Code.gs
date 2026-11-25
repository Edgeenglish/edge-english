/**
 * 대체 강사 수업 노트 자동 만들기 (support@edgeenglish.kr 계정, migration 20261125090000)
 * - 1분마다 LMS(시험·운영)에서 만들 노트 목록을 가져와 Google Docs '학생_대체강사' 를 만든다
 * - 대체 강사: 새 노트 편집 / 원래 노트 보기(이미 권한이 있으면 그대로) · 새 노트는 링크 있는 누구나 보기
 * - 공유 알림 메일은 보내지 않는다 (sendNotificationEmail=false)
 * - 처음 한 번: 함수 'setup' 실행 → 권한 허용. 그 뒤로는 자동
 * 토큰은 저장소에 적지 않는다 (__TEST_TOKEN__·__PROD_TOKEN__ 자리에 넣어 Drive 의 프로젝트에만 둠)
 */
const LMS = [
  { name: 'test', url: 'https://kyeimjozkcqbgkepwrnv.supabase.co', key: 'sb_publishable_gOfJycvYqjgSnZlGZQzgvA_HWmh9RuW',
    token: '__TEST_TOKEN__', folderId: '1cddboJqTlt5QA26oGw5pkiJUxi7ZVguz' },
  { name: 'prod', url: 'https://mfamixejxydodclhglbc.supabase.co', key: 'sb_publishable_uAeAGNOW1KZ3I-0KFLbdmQ_UYGW6-V0',
    token: '__PROD_TOKEN__', folderId: '' },
];

function setup() {
  ScriptApp.getProjectTriggers().forEach(function (t) { if (t.getHandlerFunction() === 'run') ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('run').timeBased().everyMinutes(1).create();
  run();
}

function run() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(1000)) return;
  try {
    LMS.forEach(function (c) {
      try { pull_(c); } catch (e) { console.log(c.name + ': ' + e); }
    });
  } finally { lock.releaseLock(); }
}

function pull_(c) {
  const jobs = rpc_(c, 'lms_note_jobs', { p_token: c.token });
  if (!Array.isArray(jobs)) return;
  const props = PropertiesService.getScriptProperties();
  jobs.forEach(function (j) {
    // 문서를 만든 뒤 결과 저장이 실패해도 다음 번에 같은 문서를 다시 씀
    let docId = j.doc_id || props.getProperty('job_' + j.id);
    const errors = [];
    try {
      if (!docId) {
        docId = DocumentApp.create(j.title).getId();
        props.setProperty('job_' + j.id, docId);
        if (c.folderId) DriveApp.getFileById(docId).moveTo(DriveApp.getFolderById(c.folderId));
      }
      DriveApp.getFileById(docId).setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);
      if (j.tutor_email) {
        try { share_(docId, j.tutor_email, 'writer', true); } catch (e) { errors.push('new note: ' + e); }
        if (j.original_doc_id) {
          try { share_(j.original_doc_id, j.tutor_email, 'reader', false); } catch (e) { errors.push('original note: ' + e); }
        }
      } else {
        errors.push('no tutor email');
      }
      rpc_(c, 'lms_note_job_result', { p_token: c.token, p_id: j.id, p_doc_id: docId, p_error: errors.join(' | ') || null });
      props.deleteProperty('job_' + j.id);
    } catch (e) {
      if (docId) { props.setProperty('job_' + j.id, docId); }
      rpc_(c, 'lms_note_job_result', { p_token: c.token, p_id: j.id, p_doc_id: null, p_error: String(e) });
    }
  });
}

/** 공유 (알림 메일 없음). upgrade=false 이면 이미 권한이 있는 사람은 그대로 둔다 */
function share_(fileId, email, role, upgrade) {
  const base = 'https://www.googleapis.com/drive/v3/files/' + encodeURIComponent(fileId) + '/permissions';
  const auth = { Authorization: 'Bearer ' + ScriptApp.getOAuthToken() };
  const list = UrlFetchApp.fetch(base + '?fields=permissions(id,emailAddress,role)&pageSize=100', { headers: auth, muteHttpExceptions: true });
  if (list.getResponseCode() !== 200) throw new Error('list ' + list.getResponseCode());
  const mine = (JSON.parse(list.getContentText()).permissions || []).filter(function (p) {
    return (p.emailAddress || '').toLowerCase() === email;
  })[0];
  if (mine && (!upgrade || mine.role === 'owner' || mine.role === 'writer' || mine.role === role)) return;
  const res = UrlFetchApp.fetch(base + '?sendNotificationEmail=false', {
    method: 'post', contentType: 'application/json', headers: auth, muteHttpExceptions: true,
    payload: JSON.stringify({ type: 'user', role: role, emailAddress: email }),
  });
  if (res.getResponseCode() >= 300) throw new Error('share ' + res.getResponseCode() + ' ' + res.getContentText().slice(0, 150));
}

function rpc_(c, fn, body) {
  if (!c.token || c.token.indexOf('__') === 0) return null;
  const res = UrlFetchApp.fetch(c.url + '/rest/v1/rpc/' + fn, {
    method: 'post', contentType: 'application/json', muteHttpExceptions: true,
    headers: { apikey: c.key },
    payload: JSON.stringify(body),
  });
  if (res.getResponseCode() === 404) return null; // 아직 함수가 없는 DB (운영 반영 전)
  if (res.getResponseCode() >= 300) throw new Error(fn + ' ' + res.getResponseCode() + ' ' + res.getContentText().slice(0, 150));
  return JSON.parse(res.getContentText());
}

// DriveApp.getFiles() — Drive 권한 요청용 (지우지 말 것)
