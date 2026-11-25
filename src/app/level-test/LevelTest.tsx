'use client';

// 홈페이지 무료 레벨테스트 (시안 sian-v1 확정본, 정책 원본 H26(219))
// 시작 → 문제 1장씩 → 결과(레벨·추천) → 틀린 문제 복습(1문제씩, 2·4·6번째 뒤 홍보 카드) → 결과 저장(가입) → 홍보(못 본 것만) → 카톡 상담
import { Fragment, useEffect, useRef, useState } from 'react';
import { supabaseBrowser } from '@/lms/auth/client';
import { LEVELS, QUESTIONS } from '@/lib/level-test/data';
import { PROMO_CHEER, audioUrl, cheer, fill, levelOf, reviewSteps, scoreOf, validPicks, wrongOf } from '@/lib/level-test/logic';
import { claimTaken, readTaken, writeTaken } from '@/lib/level-test/saved';
import './level-test.css';

const KAKAO = 'https://pf.kakao.com/_blxgib/friend';
const CAMP = 'https://tangerineenglish.imweb.me/?idx=13';
const LOGIN = '/lms/login';
const TUTORS: [string, string][] = [
  ['Grace', '/images/tutor/data/grace_main.jpg'],
  ['Kai', '/images/tutor/data/kai_main.jpeg'],
  ['Maria', '/images/tutor/data/maria_main.jpeg'],
  ['Benny', '/images/tutor/data/benny_main.jpeg'],
  ['Leslie', '/images/tutor/data/leslie_main_2.jpeg'],
  ['Olivia', '/images/tutor/data/olivia_main.png'],
];

type Phase = 'start' | 'q' | 'result';
type Account = 'checking' | 'out' | 'in';

function Blank({ s }: { s: string }) {
  const parts = s.split('___');
  return (
    <>
      {parts.map((p, i) => (
        <Fragment key={i}>
          {p}
          {i < parts.length - 1 && <span className="blank">&nbsp;</span>}
        </Fragment>
      ))}
    </>
  );
}

function Promo({ i }: { i: number }) {
  if (i === 0)
    return (
      <div className="pcard">
        <div className="tgrid">
          {TUTORS.map(([n, src]) => (
            <figure key={n}>
              <img src={src} alt={`${n} 강사`} loading="lazy" />
              <figcaption>{n}</figcaption>
            </figure>
          ))}
        </div>
        <div className="pbody">
          <span className="ptag">원어민 강사</span>
          <h3>100% 미국·캐나다·호주 원어민</h3>
          <p>영어를 잘하는 사람이 아니라, <b>잘 가르치는 사람</b>만 뽑아요. 모든 강사가 TESOL·TEFL·CELTA 또는 교육 관련 학위를 갖고 있어요.</p>
        </div>
      </div>
    );
  if (i === 1)
    return (
      <div className="pcard">
        <div className="lt-note" aria-hidden="true">
          <div className="note-top"><span className="dot" /><span className="dot" /><span className="dot" /><span className="note-t">Class Notes</span></div>
          <div className="note-d">Nov 25 · Free Talking</div>
          <div className="note-s">New expressions</div>
          <div className="note-l">I&apos;m down! <span className="muted ko">나도 콜!</span></div>
          <div className="note-l">It&apos;s on me. <span className="muted ko">이건 내가 쏠게.</span></div>
          <div className="note-s">Let&apos;s fix this</div>
          <div className="note-l"><s>I&apos;m so boring.</s></div>
          <div className="note-l good">I&apos;m so bored. <span className="muted ko">나 너무 심심해</span></div>
          <div className="note-l"><s>I went to there.</s></div>
          <div className="note-l good">I went there. <span className="muted ko">거기 갔어</span></div>
        </div>
        <div className="pbody">
          <span className="ptag">수업 노트</span>
          <h3>매 수업, 강사가 노트를 적어 드려요</h3>
          <p>새로 배운 표현과 고친 문장이 <b>내 수업 노트</b>에 계속 쌓여요. 수업이 끝나도 언제든 다시 보며 복습할 수 있어요.</p>
        </div>
      </div>
    );
  return (
    <div className="pcard">
      <div className="pbody">
        <span className="ptag">강사 선발</span>
        <h3>운영진 둘이 직접 면접 보고 골라요</h3>
        <p>모든 강사를 운영진 두 명이 직접 만나고, 고민 끝에 뽑아요.</p>
      </div>
      <ol className="lt-steps">
        <li><i>1</i><span><b>서면 인터뷰</b></span></li>
        <li><i>2</i><span><b>서류 심사</b> 자격증·학위·경력 확인</span></li>
        <li><i>3</i><span><b>2:1 심층 면접</b> 운영진 둘이 직접</span></li>
        <li><i>4</i><span><b>데모 레슨</b> 티칭 실력·책임감·인성 확인</span></li>
        <li><i>5</i><span><b>채용 후 교육</b> 운영진이 직접 교육 · 2개월 집중 모니터링, 이 기간에도 탈락할 수 있어요</span></li>
      </ol>
    </div>
  );
}

function Drill({ s, o, a, k }: { s: string; o: string[]; a: number; k: string }) {
  const [picked, setPicked] = useState<number | null>(null);
  return (
    <div className="drill">
      <span className="lt-s en"><Blank s={s} /></span>
      <div className="dopts">
        {o.map((x, m) => (
          <button key={m} type="button" disabled={picked !== null}
            className={`dopt${picked !== null && m === a ? ' right' : ''}${picked === m && m !== a ? ' wrong' : ''}`}
            onClick={() => setPicked(m)}>
            {x}
          </button>
        ))}
      </div>
      <span className="fb" aria-live="polite">
        {picked !== null && (picked === a ? <span className="lt-o">맞았어요</span> : <span className="lt-x">정답은 {o[a]}</span>)}
        {picked !== null && <span className="muted ko" style={{ display: 'block' }}>{k}</span>}
      </span>
    </div>
  );
}

let playing: HTMLAudioElement | null = null;
function play(k: number) {
  playing?.pause();
  playing = new Audio(audioUrl(k));
  playing.play().catch(() => {});
}

function Review({ k, pick }: { k: number; pick: number }) {
  const q = QUESTIONS[k];
  const right = fill(q.q, q.o[q.a]);
  return (
    <div className="rv">
      <div className="head"><span className="lt-tag">{q.tag}</span><span className="muted small num">{k + 1}번</span></div>
      <div className="ans en">
        <span className="lt-x">✗ {fill(q.q, q.o[pick])}</span>
        <span className="lt-o">✓ {right}</span>
        <span className="muted ko">{q.ko}</span>
      </div>
      <div className="exp">{q.e.map((t) => <p key={t}>{t}</p>)}</div>
      <details>
        <summary>연습 문제 {q.d.length}개 풀고 기억에 콕 박아 두세요</summary>
        {q.d.map((d, j) => <Drill key={j} {...d} />)}
      </details>
      <div className="say">
        <h4>소리 내어 읽어 보세요</h4>
        <div className="lt-line">
          <button type="button" className="play" onClick={() => play(k)}>▶ 듣기</button>
          <span className="en">{right}</span>
        </div>
      </div>
    </div>
  );
}

export default function LevelTest() {
  const [phase, setPhase] = useState<Phase>('start');
  const [i, setI] = useState(0);
  const [picks, setPicks] = useState<(number | null)[]>(() => Array(QUESTIONS.length).fill(null));
  const [rp, setRp] = useState(0);
  const [seen, setSeen] = useState<Set<number>>(new Set());
  const [account, setAccount] = useState<Account>('checking');
  const [saved, setSaved] = useState(false);
  const [adminView, setAdminView] = useState(false);
  const rvRef = useRef<HTMLDivElement>(null);

  // 처음 열 때: 운영자 보기(?student=) · 로그인돼 있으면 안 붙인 결과를 계정에 붙이고 최근 결과 보여 주기 · 아니면 이 브라우저의 마지막 결과
  useEffect(() => {
    const student = new URLSearchParams(window.location.search).get('student');
    const sb = supabaseBrowser();
    const local = readTaken();
    const showLocal = () => {
      if (local) {
        setPicks(local.picks);
        setPhase('result');
      }
    };
    if (!sb) {
      setAccount('out');
      return showLocal();
    }
    void (async () => {
      const { data } = await sb.auth.getSession();
      if (!data.session) {
        setAccount('out');
        return showLocal();
      }
      setAccount('in');
      if (student) setAdminView(true);
      else await claimTaken(sb).catch(() => false);
      const r = await sb.rpc('level_test_mine', { p_student: student });
      const last = Array.isArray(r.data) ? (r.data[0] as { picks: number[] } | undefined) : undefined;
      if (last && validPicks(last.picks)) {
        setPicks(last.picks);
        setSaved(true);
        setPhase('result');
      } else if (!student) showLocal();
    })();
  }, []);

  const toTop = () => window.scrollTo(0, 0);
  const restart = () => {
    setPicks(Array(QUESTIONS.length).fill(null));
    setI(0);
    setRp(0);
    setSeen(new Set());
    setSaved(false);
    setPhase('start');
    toTop();
  };

  if (phase === 'start')
    return (
      <div className="lt"><div className="frame">
        <div className="lt-card lt-stack">
          <h1>내 영어 레벨, <span className="lt-free">무료</span>로 테스트하고<br />부족한 부분만 콕 짚어 드려요</h1>
          <div className="facts"><span>20문제</span><span>약 10분</span></div>
          <div className="gift">
            <div className="gift-h">끝나면 <b>이걸 다</b> 드려요</div>
            <ul>
              <li><i>✓</i><span><b>내 영어 레벨</b> 입문·초급·중급·고급 중 어디인지</span></li>
              <li><i>✓</i><span><b>딱 맞는 교재 추천</b> 지금 레벨에서 시작하기 좋은 책</span></li>
              <li><i>✓</i><span><b>틀린 문제 쉬운 설명</b> 왜 틀렸는지 두 줄로</span></li>
              <li><i>✓</i><span><b>맞춤 연습 문제</b> 틀린 문제마다 3개씩</span></li>
              <li><i>✓</i><span><b>원어민 발음 듣기</b> 듣고 소리 내어 따라 하기</span></li>
              <li><i>✓</i><span><b>결과 저장</b> 가입하면 언제든 다시 보며 복습</span></li>
            </ul>
          </div>
          <button type="button" className="lt-btn" onClick={() => { setI(0); setPhase('q'); toTop(); }}>테스트 시작</button>
        </div>
      </div></div>
    );

  if (phase === 'q') {
    const q = QUESTIONS[i];
    const pick = picks[i];
    const last = i === QUESTIONS.length - 1;
    return (
      <div className="lt"><div className="frame lt-stack">
        <div className="lt-top"><span><span className="num">{i + 1}</span> / {QUESTIONS.length}</span><span>약 {Math.max(1, Math.ceil((QUESTIONS.length - i) * 0.5))}분 남음</span></div>
        <div className="bar"><i style={{ width: `${(i / QUESTIONS.length) * 100}%` }} /></div>
        <div className="lt-card lt-stack">
          <span><span className="sit">{q.sit}</span></span>
          <p className="lt-q en"><Blank s={q.q} /></p>
          <div className="opts">
            {q.o.map((o, j) => (
              <button key={j} type="button" className="opt" aria-pressed={pick === j}
                onClick={() => setPicks((p) => p.map((x, n) => (n === i ? j : x)))}>{o}</button>
            ))}
          </div>
        </div>
        <div className="lt-row">
          <button type="button" className="lt-btn ghost" disabled={i === 0} onClick={() => setI(i - 1)}>이전</button>
          <button type="button" className="lt-btn" disabled={pick === null} onClick={() => {
            if (pick === null) return;
            if (!last) return setI(i + 1);
            const t = { picks: picks as number[], takenAt: new Date().toISOString() };
            writeTaken(t);
            setPhase('result');
            setRp(0);
            setSeen(new Set());
            toTop();
            const sb = supabaseBrowser();
            if (sb && account === 'in') void claimTaken(sb).then((ok) => ok && setSaved(true)).catch(() => {});
          }}>{last ? '결과 보기' : '다음'}</button>
        </div>
      </div></div>
    );
  }

  // 결과
  const full = picks as number[];
  const score = scoreOf(full);
  const L = levelOf(score);
  const wrong = wrongOf(full);
  const steps = reviewSteps(wrong);
  const doneReview = !wrong.length || rp >= steps.length;
  const go = (d: number) => {
    const nx = rp + d;
    const st = steps[nx];
    if (st && st.t === 'p') setSeen((s) => new Set(s).add(st.i));
    setRp(nx);
    rvRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };
  const item = steps[rp];
  const qBefore = steps.slice(0, rp).filter((x) => x.t === 'q').length;
  const shown = item?.t === 'q' ? qBefore + 1 : qBefore;
  const left = [0, 1, 2].filter((n) => !seen.has(n));

  return (
    <div className="lt"><div className="frame lt-stack res">
      <div className="lt-card lt-stack main">
        <h1 className="rtitle">테스트 결과</h1>
        <div className="lt-level">
          <div className="lt-score"><div><b>{score}</b><small>/ {QUESTIONS.length}</small></div></div>
          <div style={{ minWidth: 0 }}>
            <h1>{L.name} <span className="muted" style={{ fontSize: 17, fontWeight: 500 }}>{L.en}</span></h1>
            <p style={{ margin: '4px 0 0' }}>{L.desc}</p>
          </div>
        </div>
        <div className="ladder" aria-label="레벨 단계">{LEVELS.map((l) => <div key={l.name} className={l === L ? 'on' : ''}>{l.name}</div>)}</div>
        {wrong.length > 0 && (
          <div className="rec">
            <h3>내가 부족한 부분 <span className="muted num" style={{ fontWeight: 500 }}>{wrong.length}개</span></h3>
            <ul className="weak">
              {wrong.map((k) => (
                <li key={k}>
                  <button type="button" onClick={() => { setRp(steps.findIndex((x) => x.t === 'q' && x.k === k)); rvRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }); }}>
                    <span>{QUESTIONS[k].tag}</span><span className="muted small num">{k + 1}번 ›</span>
                  </button>
                </li>
              ))}
            </ul>
          </div>
        )}
      </div>

      {kakaoCard(true)}

      <div className="lt-card lt-stack soft">
        <h2>화상영어 1:1 추천</h2>
        <p style={{ margin: 0 }}>{L.talk}</p>
        <div className="books">{L.books.map((b) => <span key={b}>{b}</span>)}</div>
        <a className="lt-link" href="/books">교재 자세히 보기 ›</a>
        {L.camp && (
          <div className="camp">
            <h3 style={{ margin: '0 0 4px', fontSize: 16 }}>영붙캠(영어가 입에 붙는 캠프) 초급반도 잘 맞아요</h3>
            <p style={{ margin: '0 0 6px' }} className="small">온라인 그룹수업으로 같은 레벨 친구들과 함께 기초를 다져요.</p>
            <a className="lt-link" href={CAMP} target="_blank" rel="noopener noreferrer">영붙캠 자세히 보기 ›</a>
          </div>
        )}
      </div>

      <div className="lt-card lt-stack" ref={rvRef} style={{ scrollMarginTop: 80 }}>
        <h2>틀린 문제 복습 <span className="muted num" style={{ fontWeight: 500 }}>{wrong.length}개</span></h2>
        {!wrong.length ? (
          <p className="allok">다 맞혔어요!</p>
        ) : doneReview ? (
          <>
            <div className="cheer done"><b>복습 끝!</b><span>오늘 본 {wrong.length}개는 이제 내 거예요. 다음엔 안 틀릴 거예요. 응원해요!</span></div>
            <button type="button" className="lt-btn ghost" onClick={() => { setRp(0); rvRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }); }}>처음부터 다시 보기</button>
          </>
        ) : (
          <>
            <div className="rvprog"><span className="num">{shown} / {wrong.length}</span><div className="bar"><i style={{ width: `${(shown / wrong.length) * 100}%` }} /></div></div>
            {item.t === 'q' ? (
              <Fragment key={`q${rp}`}>
                <div className="cheer">{cheer(qBefore, wrong.length)}</div>
                <Review k={item.k} pick={full[item.k]} />
              </Fragment>
            ) : (
              <Fragment key={`p${rp}`}>
                <div className="cheer">{PROMO_CHEER[item.i]}</div>
                <Promo i={item.i} />
              </Fragment>
            )}
            <div className="lt-row">
              <button type="button" className="lt-btn ghost" disabled={rp === 0} onClick={() => go(-1)}>이전</button>
              <button type="button" className="lt-btn" onClick={() => go(1)}>{rp === steps.length - 1 ? '복습 끝내기' : '다음 ›'}</button>
            </div>
          </>
        )}
      </div>

      {doneReview && (
        <>
          {left.length > 0 && (
            <div className="promo">
              <h2 className="promo-h">엣지영어는 이렇게 가르쳐요</h2>
              {left.map((n) => <Promo key={n} i={n} />)}
            </div>
          )}
          {wrong.length > 0 && kakaoCard(false)}
          {!adminView && <button type="button" className="lt-btn ghost" onClick={restart}>테스트 다시 하기</button>}
        </>
      )}
    </div></div>
  );

  // 카톡 채널 추가 + 1:1 상담 (대표 11/25: 회원가입보다 채널 추가가 메인). 회원가입은 맨 위 카드에만 작은 글 한 줄
  function kakaoCard(withSignup: boolean) {
    return (
      <div className="lt-card lt-stack talk">
        <h2>내 결과로 1:1 상담받기</h2>
        <p className="small" style={{ margin: 0 }}>결과 화면을 캡처해서 카톡으로 보내 주시면, 내 레벨에 맞는 수업과 교재를 바로 알려 드려요. 정확한 레벨도 상담에서 봐 드려요.</p>
        <a className="lt-btn kakao" href={KAKAO} target="_blank" rel="noopener noreferrer">카톡 채널 추가하고 상담받기</a>
        {withSignup && !adminView && (saved ? (
          <p className="small" style={{ margin: 0, textAlign: 'center' }}>✓ 내 계정에 결과를 저장했어요</p>
        ) : account === 'out' ? (
          <a className="signup" href={`${LOGIN}?signup=1`}>결과를 사이트에 저장하려면 회원가입 ›</a>
        ) : null)}
      </div>
    );
  }
}
