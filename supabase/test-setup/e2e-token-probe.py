#!/usr/bin/env python3
"""
시험용 Supabase 실제 로그인 토큰 끝단 점검 (5-4, D-27 승인) — edgeenglish-lms-test 전용

사용: python3 -I supabase/test-setup/e2e-token-probe.py            (점검 실행 + 끝나면 정리)
      python3 -I supabase/test-setup/e2e-token-probe.py --check    (키 연결만 확인, 아무것도 만들지 않음)

하는 일
  1. 서버 키로 가상 로그인 계정 7개 생성 (authz-e2e-…@example.com, 무작위 비밀번호, email_confirm=true → 메일 발송 없음)
  2. app_users 연결: 학생 A·B = 기존 가상학생일·이, 강사 X·Y = 기존 가상강사 Alex·Blair, 운영자(대표 owner) 1, 운영직원(staff) 1, 미등록 1
     운영자·직원은 실제 Supabase MFA API로 TOTP를 등록·인증해 aal2 토큰을 받는다 (migration 800 확인).
     같은 대표 계정의 TOTP 전(aal1) 토큰은 '운영자(TOTP 전)' 으로 따로 점검 → 아무것도 못 봐야 함
     (학생·수업·결제 데이터는 새로 만들지 않음)
  3. 각 계정으로 실제 로그인(비밀번호) → 받은 토큰으로 REST API를 거쳐 읽기·쓰기·함수 확인
  4. 성공·실패와 관계없이 마지막에 연결 6줄과 계정 6개 삭제 (변경 이력 audit_log 몇 줄은 남음 — 지울 수 없게 설계됨)

서버 키 (둘 중 하나, 값은 절대 출력하지 않음)
  - 환경 변수 SUPABASE_SERVICE_ROLE_KEY (sb_secret_… 또는 레거시 service_role JWT)
  - 네트워크 시크릿: 작업 환경의 관문(프록시)이 시험용 주소로 가는 요청에 키 헤더를 넣어 주는 방식.
    이 경우 컨테이너 안에는 키가 없으므로 스크립트는 헤더 없이 관리 API를 불러 보고 200이면 '주입됨'으로 판단한다.
    주입된 키가 학생 토큰 요청까지 덮어써 결과가 왜곡되는지 '안전장치'로 먼저 확인하고, 왜곡되면 아무것도 만들지 않고 멈춘다.
"""
import base64
import hashlib
import hmac
import json
import os
import struct
import time
import secrets
import ssl
import sys
import urllib.error
import urllib.request

TEST_HOST = "kyeimjozkcqbgkepwrnv.supabase.co"
URL = os.environ.get("NEXT_PUBLIC_SUPABASE_URL", "").rstrip("/")
PUB = os.environ.get("NEXT_PUBLIC_SUPABASE_ANON_KEY", "")
SECRET = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")

STUDENT_A = "00000000-7e57-0000-0000-00000000b001"  # 가상학생일 (seed_fake)
STUDENT_B = "00000000-7e57-0000-0000-00000000b002"  # 가상학생이
TUTOR_X = "00000000-7e57-0000-0000-00000000a001"    # 가상강사 Alex
TUTOR_Y = "00000000-7e57-0000-0000-00000000a002"    # 가상강사 Blair (가상학생사 재등록 통보 담당)

results = []  # (ok, label)


def stop(msg):
    print(f"중단: {msg}")
    sys.exit(2)


def check(ok, label):
    results.append((bool(ok), label))
    print(f"  {'통과' if ok else '실패'}  {label}")


def http(method, path, *, headers=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(URL + path, data=data, method=method, headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, context=ssl.create_default_context(), timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw) if raw else None
        except ValueError:
            return e.code, raw[:200].decode(errors="replace")


# ---------- 서버 키 헤더 (값은 출력하지 않음) ----------
def admin_headers():
    if not SECRET:
        return {}  # 네트워크 시크릿 모드: 관문이 넣어 줌
    h = {"apikey": SECRET}
    if SECRET.startswith("eyJ"):  # 레거시 service_role JWT 는 Authorization 도 필요. sb_secret_ 는 JWT가 아니라 apikey 만
        h["Authorization"] = f"Bearer {SECRET}"
    return h


def user_headers(token=None):
    h = {"apikey": PUB}
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h


def admin(method, path, body=None, extra=None):
    return http(method, path, headers={**admin_headers(), **(extra or {})}, body=body)


def as_user(token, method, path, body=None, extra=None):
    return http(method, path, headers={**user_headers(token), **(extra or {})}, body=body)


def rows(token, table, query="select=*"):
    code, data = as_user(token, "GET", f"/rest/v1/{table}?{query}")
    if code == 200 and isinstance(data, list):
        return data
    return None  # 거절(401/403) — 0건과 같게 봄


def denied(code, data):
    return code in (401, 403) or (isinstance(data, dict) and data.get("code") == "42501")


# ---------- 0. 사전 확인 ----------
def preflight():
    host = URL.split("://", 1)[-1].split("/", 1)[0]
    if host != TEST_HOST:
        stop("NEXT_PUBLIC_SUPABASE_URL 이 시험용 프로젝트가 아님 (운영 프로젝트에 실행 금지)")
    if not PUB.startswith("sb_publishable_"):
        stop("publishable key 형식이 아님")
    mode = "환경 변수" if SECRET else "네트워크 시크릿(관문 주입)"
    if SECRET and not (SECRET.startswith("sb_secret_") or SECRET.startswith("eyJ")):
        stop("SUPABASE_SERVICE_ROLE_KEY 형식을 알 수 없음 (sb_secret_… 이어야 함, 값은 출력하지 않음)")
    if SECRET.startswith("sb_publishable_"):
        stop("SUPABASE_SERVICE_ROLE_KEY 에 publishable key 가 들어 있음")

    code, _ = admin("GET", "/auth/v1/admin/users?page=1&per_page=1")
    print(f"서버 키 방식: {mode} → 관리 API 응답 {code}")
    if code != 200:
        stop("서버 키가 인정되지 않음 — 키를 넣었는지, 새 세션인지, 네트워크 시크릿의 주소·헤더가 맞는지 확인")

    # 안전장치: 공개키만 보낸 요청이 서버 권한으로 바뀌지 않는지 (네트워크 시크릿이 모든 요청을 덮어쓰는 경우 대비)
    code, data = http("GET", "/rest/v1/students?select=id&limit=1", headers=user_headers())
    if code == 200 and isinstance(data, list) and len(data) > 0:
        stop("공개키 요청에 서버 권한이 섞여 들어감 (관문이 키를 모든 요청에 넣는 것으로 보임) → 결과가 왜곡되므로 "
             "네트워크 시크릿 대신 환경 변수 방식으로 바꿔 주세요")
    code, _ = http("GET", "/auth/v1/admin/users?page=1&per_page=1", headers=user_headers())
    if code == 200:
        stop("공개키로 관리 API가 열림 (서버 키가 모든 요청에 주입됨) → 환경 변수 방식으로 바꿔 주세요")
    print("안전장치 통과: 공개키 요청은 서버 권한 없이 처리됨")


# ---------- 1. 계정 만들기·연결 ----------
PERSONAS = [
    ("미등록", None, None, None, None),
    ("학생A", "student", STUDENT_A, None, None),
    ("학생B", "student", STUDENT_B, None, None),
    ("강사X", "tutor", None, TUTOR_X, None),
    ("강사Y", "tutor", None, TUTOR_Y, None),
    ("운영자", "admin", None, None, "owner"),
    ("운영직원", "admin", None, None, "staff"),
]


def setup(created):
    tag = secrets.token_hex(3)
    for name, role, sid, tid, level in PERSONAS:
        email = f"authz-e2e-{tag}-{len(created)}@example.com"
        password = secrets.token_urlsafe(24)
        code, data = admin("POST", "/auth/v1/admin/users", {"email": email, "password": password, "email_confirm": True})
        if code not in (200, 201) or not isinstance(data, dict) or "id" not in data:
            raise RuntimeError(f"{name} 계정 생성 실패 ({code})")
        created.append({"name": name, "id": data["id"], "email": email, "password": password, "linked": False})
        if role:
            row = {"auth_user_id": data["id"], "role": role, "student_id": sid, "tutor_id": tid}
            if level:
                row["admin_level"] = level
            code, _ = admin("POST", "/rest/v1/app_users", row, {"Prefer": "return=minimal"})
            if code not in (200, 201, 204):
                raise RuntimeError(f"{name} app_users 연결 실패 ({code})")
            created[-1]["linked"] = True
    print(f"가상 로그인 계정 {len(created)}개 생성·연결 완료 (메일 발송 없음)")


def login(p):
    code, data = http("POST", "/auth/v1/token?grant_type=password", headers=user_headers(), body={"email": p["email"], "password": p["password"]})
    if code != 200 or "access_token" not in (data or {}):
        raise RuntimeError(f"{p['name']} 로그인 실패 ({code})")
    return data["access_token"]


def totp_code(secret_b32, at=None):
    """RFC 6238 (SHA1, 30초, 6자리) — 인증 앱이 만드는 숫자와 같음"""
    key = base64.b32decode(secret_b32.upper() + "=" * (-len(secret_b32) % 8))
    counter = int((at or time.time()) // 30)
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    off = digest[-1] & 0x0F
    return f"{(struct.unpack('>I', digest[off:off + 4])[0] & 0x7FFFFFFF) % 1_000_000:06d}"


def jwt_aal(token):
    body = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4))).get("aal")


def totp_login(p, aal1_token):
    """실제 Supabase MFA API: TOTP 등록 → 확인 요청 → 코드 인증 → aal2 토큰 (비밀값·코드는 출력하지 않음)"""
    code, f = as_user(aal1_token, "POST", "/auth/v1/factors", {"factor_type": "totp", "friendly_name": "authz-e2e"})
    if code != 200 or "id" not in (f or {}):
        raise RuntimeError(f"{p['name']} TOTP 등록 실패 ({code}) — Supabase Authentication → MFA 의 TOTP 가 켜져 있는지 확인")
    code, ch = as_user(aal1_token, "POST", f"/auth/v1/factors/{f['id']}/challenge", {})
    if code != 200 or "id" not in (ch or {}):
        raise RuntimeError(f"{p['name']} TOTP 확인 요청 실패 ({code})")
    code, s = as_user(aal1_token, "POST", f"/auth/v1/factors/{f['id']}/verify", {"challenge_id": ch["id"], "code": totp_code(f["totp"]["secret"])})
    if code != 200 or "access_token" not in (s or {}):
        raise RuntimeError(f"{p['name']} TOTP 인증 실패 ({code})")
    return s["access_token"]


def cleanup(created):
    ids = [p["id"] for p in created if p.get("linked")]
    ok = True
    if ids:
        code, _ = admin("DELETE", f"/rest/v1/app_users?auth_user_id=in.({','.join(ids)})", extra={"Prefer": "return=minimal"})
        ok &= code in (200, 204)
    for p in created:
        code, _ = admin("DELETE", f"/auth/v1/admin/users/{p['id']}")
        ok &= code in (200, 204)
    print(f"정리: 연결 {len(ids)}줄·계정 {len(created)}개 삭제 {'완료' if ok else '— 일부 실패, Claude에게 알려 주세요'}")
    return ok


# ---------- 2. 실제 토큰으로 점검 ----------
def probe(tokens):
    print("1. 토큰이 본인으로 인정되는지")
    for p, t in tokens:
        code, data = as_user(t, "GET", "/auth/v1/user")
        check(code == 200 and (data or {}).get("id") == p["id"], f"{p['name']}: /auth/v1/user 가 본인 계정")

    print("2. 읽기")
    tk = {p["name"]: t for p, t in tokens}
    for name in ("미등록", "학생A", "학생B", "강사X", "강사Y", "운영자(TOTP 전)"):
        for table in ("payments", "refunds", "audit_log", "app_users", "notifications"):
            r = rows(tk[name], table, "select=*&limit=50")
            # app_users: 본인 행 정책이 없으므로 0건이어야 함
            check(not r, f"{name}: {table} 0건")
    check(not rows(tk["미등록"], "students"), "미등록: students 0건")
    check(not rows(tk["미등록"], "enrollments"), "미등록: enrollments 0건")
    check(not rows(tk["운영자(TOTP 전)"], "students"), "운영자(TOTP 전): students 0건 (POL-AC-05)")
    check(not rows(tk["운영자(TOTP 전)"], "enrollments"), "운영자(TOTP 전): enrollments 0건")
    for name, me, other in (("학생A", STUDENT_A, STUDENT_B), ("학생B", STUDENT_B, STUDENT_A)):
        s = rows(tk[name], "students", "select=id")
        check(s is not None and [x["id"] for x in s] == [me], f"{name}: students 본인 1명만")
        e = rows(tk[name], "enrollments", "select=student_id") or []
        check(len(e) >= 1 and all(x["student_id"] == me for x in e), f"{name}: enrollments 본인 것만 ({len(e)}건)")
        check(not rows(tk[name], "enrollments", f"select=id&student_id=eq.{other}"), f"{name}: 다른 학생 수강등록 0건 (번호를 알아도)")
        check(not rows(tk[name], "admin_tasks"), f"{name}: 운영 업무 0건")
        check(not rows(tk[name], "tutors"), f"{name}: 강사 원본 표 0건")
    for name in ("강사X", "강사Y"):
        check(not rows(tk[name], "students"), f"{name}: 학생 원본 표(휴대폰·실명) 0건")
        check(not rows(tk[name], "enrollments"), f"{name}: 수강등록 0건")
    ty = rows(tk["강사Y"], "admin_tasks", "select=kind,tutor_id") or []
    check(all(x["kind"] == "renewal_tutor_notice" and x["tutor_id"] == TUTOR_Y for x in ty), f"강사Y: 본인에게 온 재등록 통보만 ({len(ty)}건)")
    check(not rows(tk["강사X"], "admin_tasks", f"select=id&tutor_id=eq.{TUTOR_Y}"), "강사X: 다른 강사 업무 0건")
    code, all_students = admin("GET", "/rest/v1/students?select=id")
    adm = rows(tk["운영자"], "students", "select=id") or []
    check(code == 200 and len(adm) == len(all_students or []), f"운영자: 학생 전체 읽기 ({len(adm)}명)")
    stf = rows(tk["운영직원"], "students", "select=id") or []
    check(code == 200 and len(stf) == len(all_students or []), f"운영직원: 학생 읽기 ({len(stf)}명, 직원 읽기 범위는 미결정 → 지금은 운영자와 같음)")

    print("3. 쓰기 (모두 거절돼야 통과)")
    for p, t in tokens:
        n = p["name"]
        c, d = as_user(t, "POST", "/rest/v1/app_users", {"auth_user_id": p["id"], "role": "admin"}, {"Prefer": "return=minimal"})
        check(denied(c, d), f"{n}: 스스로 운영자 등록 거절 ({c})")
        c, d = as_user(t, "PATCH", f"/rest/v1/students?id=eq.{STUDENT_B}", {"admin_memo": "변조"}, {"Prefer": "return=minimal"})
        check(denied(c, d), f"{n}: 학생 정보 수정 거절 ({c})")
        c, d = as_user(t, "POST", "/rest/v1/reward_ledger", {"student_id": STUDENT_A, "kind": "grant_admin", "amount": 999999, "note": "x"}, {"Prefer": "return=minimal"})
        check(denied(c, d), f"{n}: 적립금 직접 지급 거절 ({c})")

    print("4. 함수")
    for name in ("미등록", "학생A", "학생B", "강사X", "강사Y", "운영자(TOTP 전)"):
        c, d = as_user(tk[name], "POST", "/rest/v1/rpc/is_admin", {})
        check(c == 200 and d is False, f"{name}: is_admin() = false")
    for name, want_admin, want_owner in (("운영자", True, True), ("운영직원", True, False), ("운영자(TOTP 전)", False, False)):
        c, d = as_user(tk[name], "POST", "/rest/v1/rpc/is_admin", {})
        check(c == 200 and d is want_admin, f"{name}: is_admin() = {str(want_admin).lower()}")
        c, d = as_user(tk[name], "POST", "/rest/v1/rpc/is_owner", {})
        check(c == 200 and d is want_owner, f"{name}: is_owner() = {str(want_owner).lower()} (대표 전용 권한, POL-AC-07)")
    c, d = as_user(tk["학생A"], "POST", "/rest/v1/rpc/reward_balance", {"p_student": STUDENT_B})
    check(c == 200 and (d or 0) == 0, "학생A: 학생B 적립금 잔액 조회 → 0")


def main():
    preflight()
    if "--check" in sys.argv:
        print("키 연결 확인만 완료 (계정을 만들지 않음)")
        return 0
    created = []
    try:
        setup(created)
        tokens = []
        for p in created:
            t = login(p)
            if p["name"] in ("운영자", "운영직원"):
                check(jwt_aal(t) == "aal1", f"{p['name']}: 이메일·비밀번호만 통과한 토큰은 aal1")
                if p["name"] == "운영자":
                    tokens.append(({"name": "운영자(TOTP 전)", "id": p["id"]}, t))
                t = totp_login(p, t)
                check(jwt_aal(t) == "aal2", f"{p['name']}: TOTP 인증 후 토큰은 aal2")
            tokens.append((p, t))
        probe(tokens)
    except Exception as e:  # 오류가 나도 정리는 반드시
        check(False, f"점검 중 오류: {e}")
    finally:
        cleaned = cleanup(created)
    bad = [label for ok, label in results if not ok]
    print(f"\n결과: {'모두 통과' if not bad else f'실패 {len(bad)}건'} ({len(results)}개 확인)" + ("" if cleaned else " — 정리 일부 실패"))
    return 0 if not bad and cleaned else 1


if __name__ == "__main__":
    sys.exit(main())
