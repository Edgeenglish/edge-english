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
    const applications = form.getResponses().map(function(response) {
      return {
        id: response.getId(), submittedAt: response.getTimestamp().toISOString(), email: response.getRespondentEmail() || '',
        items: response.getItemResponses().map(function(itemResponse) {
          const item = itemResponse.getItem();
          const result = { id: String(item.getId()), title: item.getTitle(), type: String(item.getType()), value: itemResponse.getResponse() };
          if (item.getType() === FormApp.ItemType.CHECKBOX_GRID) result.rows = item.asCheckboxGridItem().getRows();
          return result;
        }),
      };
    });
    return lmsApplicationsJson_({ applications: applications });
  } catch (_) { return lmsApplicationsJson_({ error: 'Unable to read applications' }); }
}
function lmsApplicationsJson_(value) { return ContentService.createTextOutput(JSON.stringify(value)).setMimeType(ContentService.MimeType.JSON); }
