/** LMS 신규 등록 신청서 읽기 전용 연결. 폼·응답·시트를 수정하지 않음.
 * POST only; Supabase is_admin (운영자 + aal2)를 확인한 뒤에만 응답을 읽는다.
 * 서비스 역할 키·장기 토큰·공개 응답 피드 없음. 전달받은 세션은 저장·로그하지 않음.
 * 기존 Code.gs와 별도 파일로 추가. 기존 미리보기/적용 함수를 실행하지 말 것.
 */
function doGet() { return lmsApplicationsJson_({ error: 'POST required' }); }
function doPost(e) {
  try {
    const p = JSON.parse(e.postData.contents);
    const allowed = ['https://kyeimjozkcqbgkepwrnv.supabase.co', 'https://mfamixejxydodclhglbc.supabase.co'];
    if (allowed.indexOf(p.supabaseUrl) < 0 || typeof p.accessToken !== 'string' || typeof p.anonKey !== 'string') {
      return lmsApplicationsJson_({ error: 'Unauthorized' });
    }
    const auth = UrlFetchApp.fetch(p.supabaseUrl + '/rest/v1/rpc/is_admin', {
      method: 'post', contentType: 'application/json', payload: '{}', muteHttpExceptions: true,
      followRedirects: false, headers: { apikey: p.anonKey, Authorization: 'Bearer ' + p.accessToken },
    });
    if (auth.getResponseCode() !== 200 || auth.getContentText().trim() !== 'true') {
      return lmsApplicationsJson_({ error: 'Unauthorized' });
    }
    const form = FormApp.openById('163rAf9Jn-bCxNN8Px38G2BgUTfK-AeixxIlTLedjXNs');
    // 질문 제목·유형·그리드 행은 응답마다 다시 읽지 않고 한 번만 읽는다.
    const metadata = {};
    form.getItems().forEach(function(item) {
      const m = { id: String(item.getId()), title: item.getTitle(), type: String(item.getType()) };
      if (item.getType() === FormApp.ItemType.CHECKBOX_GRID) m.rows = item.asCheckboxGridItem().getRows();
      metadata[m.id] = m;
    });
    const applications = form.getResponses().map(function(response) {
      return {
        id: response.getId(), submittedAt: response.getTimestamp().toISOString(), email: response.getRespondentEmail() || '',
        items: response.getItemResponses().map(function(itemResponse) {
          const item = itemResponse.getItem();
          const id = String(item.getId());
          const m = metadata[id] || { id: id, title: item.getTitle(), type: String(item.getType()) };
          const result = { id: id, title: m.title, type: m.type, value: itemResponse.getResponse() };
          if (m.rows) result.rows = m.rows;
          return result;
        }),
      };
    });
    return lmsApplicationsJson_({ applications: applications });
  } catch (_) { return lmsApplicationsJson_({ error: 'Unable to read applications' }); }
}
function lmsApplicationsJson_(value) { return ContentService.createTextOutput(JSON.stringify(value)).setMimeType(ContentService.MimeType.JSON); }

/** 수동 진단: 개인정보·토큰은 출력하지 않고 읽기/통신 성공 여부만 확인. */
function lmsApplicationsCheck() {
  const form = FormApp.openById('163rAf9Jn-bCxNN8Px38G2BgUTfK-AeixxIlTLedjXNs');
  const responses = form.getResponses();
  const transport = UrlFetchApp.fetch('https://kyeimjozkcqbgkepwrnv.supabase.co/auth/v1/health', { muteHttpExceptions: true });
  console.log(JSON.stringify({ responses: responses.length, transportStatus: transport.getResponseCode() }));
}
