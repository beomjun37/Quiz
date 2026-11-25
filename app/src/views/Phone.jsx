import { useEffect, useRef, useState } from 'react'
import {
  Users, X as CloseIcon,
  AlertCircle, ArrowDown, ArrowUp, Beer, Check, Clock, Crown, Dices, Flame, Gift, LogIn, Medal,
  MessageCircle, Minus, Sparkles, Split, Trophy, UserRound, Vote, Zap,
} from 'lucide-react'
import { rpc } from '../lib/supabase'
import { useCountdown, useView } from '../lib/useView'
import { errText, fmt, options, randomNick, trap, REACT_EMOJI, revealOf, isCorrect, scrollToTop } from '../lib/ui'
import { serverNow } from '../lib/clock'
import { fx, unlockAudio } from '../lib/fx'

const KEY = 'hq-player'

// 게임 중 화면이 꺼지지 않게(지원하는 브라우저만). 다른 앱에 다녀오면 다시 요청한다.
export function useWakeLock() {
  useEffect(() => {
    let lock = null
    const req = async () => { try { if (document.visibilityState === 'visible') lock = await navigator.wakeLock?.request('screen') } catch { /* 미지원 */ } }
    req(); document.addEventListener('visibilitychange', req)
    return () => { document.removeEventListener('visibilitychange', req); try { lock?.release() } catch { /* noop */ } }
  }, [])
}
const load = () => { try { return localStorage.getItem(KEY) } catch { return null } }
const store = (v) => { try { v ? localStorage.setItem(KEY, v) : localStorage.removeItem(KEY) } catch { /* 사생활 모드 */ } }

// 스크린 없이 폰만으로 진행한다: 문제·제출 현황·응답 분포·순위·시상·추첨이 전부 여기 나온다.
export default function Phone() {
  const [pid, setPid] = useState(load)
  const { view, error, refetch } = useView(pid, 2000)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState(null)
  const [kicked, setKicked] = useState(false)
  const [roster, setRoster] = useState(false)

  // 진행자가 새 게임을 시작해 내 기록이 사라졌으면 입장부터 다시
  useEffect(() => { if (view && pid && view._for === pid && !view.me) { store(null); setPid(null); setKicked(true) } }, [view, pid])
  useEffect(() => { setMsg(null); scrollToTop() }, [view?.phase, view?.qi])
  useWakeLock()
  useEffect(() => {
    const f = () => unlockAudio()
    addEventListener('pointerdown', f); return () => removeEventListener('pointerdown', f)
  }, [])

  async function act(fn) {
    if (busy) return
    setBusy(true); setMsg(null)
    try { await fn(); await refetch() } catch (e) { setMsg(errText(e.message)) } finally { setBusy(false) }
  }

  if (!view) return (
    <div className="phone"><div className="center"><div className="big-icon"><Beer size={38} /></div>
      <p className="title">한잔 퀴즈</p><p className="lead">{error ? '연결 중이에요…' : '불러오는 중…'}</p></div></div>
  )

  if (!pid) return <Join view={view} act={act} busy={busy} onJoined={(id) => { setKicked(false); store(id); setPid(id) }}
    msg={msg || (kicked ? '새 게임이 시작됐어요. 닉네임을 입력하고 다시 들어와 주세요' : null)} />

  const me = view.me
  if (!me) return <Waiting icon={<Beer size={38} />} title="입장하는 중…" text="잠시만요" />

  const body = {
    lobby: <Lobby view={view} me={me} act={act} busy={busy} leave={() => { store(null); setPid(null) }} />,
    bet: <Bet me={me} act={act} busy={busy} />,
    q: <Question view={view} me={me} act={act} busy={busy} />,
    answer: <Result view={view} me={me} />,
    final: <Final view={view} me={me} />,
    draw: <Draw view={view} />,
    end: <End view={view} me={me} />,
  }[view.phase]

  return (
    <div className="phone">
      <div className="statusbar">
        <div className="me-chip"><UserRound size={20} color="var(--mute)" /><span>{me.name}</span>
          {me.streak >= 2 && <span className="streak"><Flame size={15} />{me.streak}</span>}</div>
        <button className="score-chip num" onClick={() => setRoster(true)} aria-label="참가자 명단과 순위 보기">{fmt(me.score)}<small>점 · {me.rank}위 · <Users size={13} style={{ verticalAlign: -2 }} />{view.players}</small></button>
      </div>
      {roster && <RosterSheet view={view} onClose={() => setRoster(false)} />}
      {body}
      {msg && <div className="err" role="alert"><AlertCircle size={20} />{msg}</div>}
    </div>
  )
}

function Waiting({ icon, title, text, children }) {
  return <div className="center" style={{ flex: 1, alignContent: 'center' }}>
    <div className="big-icon">{icon}</div><p className="title">{title}</p>{text && <p className="lead">{text}</p>}{children}
  </div>
}

function Join({ view, act, msg, busy, onJoined }) {
  const [name, setName] = useState('')
  const ref = useRef(null)
  const joinId = useRef(crypto.randomUUID())
  const live = { lobby: '곧 시작해요', bet: '마지막 베팅 중', q: `${view.qi + 1}번 문제 푸는 중`, answer: `${view.qi + 1}번 정답 공개 중`, final: '최종 순위 발표 중', draw: '행운상 추첨 중', end: '게임이 끝났어요' }[view.phase]

  function submit(e) {
    e.preventDefault()
    unlockAudio()
    act(async () => {
      // 한글 조합 중에 눌러도 비지 않게 입력창 값을 직접 읽는다
      const n = (ref.current?.value ?? name).trim()
      if (!n) { ref.current?.focus(); throw new Error('BAD_NAME') }
      const r = await rpc('hq_join', { p_name: n, p_id: joinId.current })
      onJoined(r.id)
    })
  }

  return (
    <form className="phone" onSubmit={submit}>
      <div className="live" style={{ paddingTop: 6 }}><i className="dot" /><span>지금 <b>{live}</b> · <b className="num">{view.players}</b>명 참여 중</span></div>
      <div style={{ display: 'grid', gap: 10, marginTop: 24 }}>
        <div className="big-icon"><Beer size={38} /></div>
        <h1 className="title">한잔 퀴즈</h1>
        <p className="lead">닉네임 하나면 바로 참여해요. 오늘은 개인전, 1등은 단 한 명!</p>
      </div>
      <label style={{ display: 'grid', gap: 8, marginTop: 8 }}>
        <span style={{ fontWeight: 700 }}>내 닉네임</span>
        <div className="field">
          <input ref={ref} autoFocus maxLength={12} autoComplete="off" enterKeyHint="go"
            placeholder="예: 소맥 비율 연구소장" value={name} onChange={(e) => setName(e.target.value)} />
          <button type="button" className="icon-btn" aria-label="닉네임 추천" onClick={() => { setName((v) => randomNick(v)); ref.current?.focus() }}><Dices size={28} /></button>
        </div>
        <span className="lead" style={{ fontSize: 15 }}>고민되면 주사위를 눌러 보세요</span>
      </label>
      {view.phase !== 'lobby' && view.phase !== 'end' && <div className="panel late">
        <Clock size={20} /><span>게임이 이미 시작됐어요. 지금 들어오면 <b>{view.phase === 'q' ? `${view.qi + 1}번` : `${view.qi + 2}번`} 문제부터</b> 참여해요. 점수는 0점에서 시작하지만, 하위권 역전 보너스가 있어요!</span>
      </div>}
      {msg && <div className="err" role="alert"><AlertCircle size={20} />{msg}</div>}
      <button className="primary" style={{ marginTop: 'auto' }} disabled={busy}><LogIn size={24} />{busy ? '들어가는 중…' : '입장하기'}</button>
    </form>
  )
}

// 대기 화면: 규칙을 미리 알려 준다(진행자가 말로 설명하지 않아도 되게)
function Lobby({ view, me, act, busy, leave }) {
  return <>
    <div className="center" style={{ paddingBottom: 8 }}>
      <div className="big-icon"><Beer size={38} /></div>
      <p className="title">입장 완료!</p>
      <p className="lead"><b className="num" style={{ color: 'var(--fg)' }}>{view.players}명</b>이 함께하고 있어요. 곧 첫 문제가 열려요.</p>
    </div>
    <div className="panel who">
      <h3><Users size={18} />지금 들어온 사람 <b className="num">{view.players}명</b></h3>
      <div className="who-list">{(view.roster ?? []).map((p) => <span key={p.name} className={p.is_me ? 'me' : ''}>{p.name}</span>)}</div>
    </div>
    <div className="panel howto">
      <h3>이렇게 하면 돼요</h3>
      <ol>
        <li>문제가 뜨면 <b>보기 버튼 하나만 꾹</b> 누르세요</li>
        <li>정답은 <b>내 폰</b>에 바로 떠요 (초록색이 정답)</li>
        <li>빨리 누를수록 점수 UP · 한 번 누르면 못 바꿔요</li>
      </ol>
      <Practice />
    </div>
    <div className="panel rules">
      <h3>점수 따는 법</h3>
      <div><Zap size={20} /><span><b>빨리 맞힐수록</b> 최대 1,000점</span></div>
      <div><Flame size={20} /><span><b>3연속 정답</b>부터 맞힐 때마다 +200</span></div>
      <div><Sparkles size={20} /><span><b>찬스 카드 1장</b>: 50:50 또는 점수 2배</span></div>
      <div><ArrowUp size={20} /><span>하위권이 맞히면 <b>역전 보너스</b> +50%</span></div>
      <div><Trophy size={20} /><span><b>1·2·3등</b> 상품 + 나머지 중 <b>행운상</b> 추첨</span></div>
    </div>
    <button className="link" disabled={busy}
      onClick={() => act(async () => { await rpc('hq_leave', { p_player: me.id }); leave() })}>닉네임 바꾸기</button>
  </>
}

// 사진 연출(제한 시간 동안 점점 쉬워진다). 정답 공개 화면에서는 원본 그대로.
//   zoom 4배 확대 → 원래 크기 / blur 흐림 → 선명 / pixel 모자이크 → 선명 / silhouette 그림자 → 원본
export function QImage({ q, left, src: given }) {
  const [fetched, setSrc] = useState(null)
  const src = given ?? fetched
  const canvas = useRef(null)
  useEffect(() => {
    let dead = false
    setSrc(null)
    if (q.has_image && given === undefined) rpc('hq_image', { p_idx: q.idx }).then((d) => { if (!dead) setSrc(d) }).catch(() => {})
    return () => { dead = true }
  }, [q.idx, q.has_image])
  const t = left == null ? 0 : Math.max(0, Math.min(1, left / q.limit_sec))  // 1 → 0
  const rv = revealOf(q)
  const pixel = rv.mode === 'pixel' && t > 0
  // 모자이크: 작은 캔버스에 그린 뒤 부드럽게 하지 않고 키운다. 칸 크기 48px → 1px
  useEffect(() => {
    if (!pixel || !src || !canvas.current) return
    const img = new Image()
    img.onload = () => {
      const c = canvas.current; if (!c) return
      const w = img.width, h = img.height, block = Math.max(1, Math.round(72 * t * t))
      c.width = w; c.height = h
      const sw = Math.max(1, Math.round(w / block)), sh = Math.max(1, Math.round(h / block))
      const tmp = document.createElement('canvas'); tmp.width = sw; tmp.height = sh
      tmp.getContext('2d').drawImage(img, 0, 0, sw, sh)
      const ctx = c.getContext('2d'); ctx.imageSmoothingEnabled = false
      ctx.drawImage(tmp, 0, 0, sw, sh, 0, 0, w, h)
    }
    img.src = src
  }, [pixel, src, Math.round(t * 40)]) // eslint-disable-line
  if (!q.has_image) return null
  if (!src) return <div className="qimg"><span className="lead">사진 불러오는 중…</span></div>
  if (pixel) return <div className="qimg"><canvas ref={canvas} aria-label="모자이크 문제 사진" /></div>
  // 확대: 8배에서 시작해 진행자가 고른 부위(귀·눈 등)만 보이다가, 시간이 갈수록 천천히 전체가 드러난다
  const style = rv.mode === 'zoom' ? { transform: `scale(${1 + 7 * Math.pow(t, 1.4)})`, transformOrigin: `${rv.x * 100}% ${rv.y * 100}%` }
    : rv.mode === 'blur' ? { filter: `blur(${Math.round(24 * t)}px)` }
    // 그림자: 흑백 고대비로 윤곽만 보이다가(처음 60%), 남은 시간 동안 원래 색으로 돌아온다
    : rv.mode === 'silhouette' && t > 0 ? (() => { const k = t > 0.4 ? 1 : t / 0.4
        return { filter: `grayscale(${k}) contrast(${1 + 11 * k}) brightness(${1 - 0.35 * k})` } })() : undefined
  return <div className="qimg"><img src={src} alt="문제 사진" style={style} /></div>
}

function Question({ view, me, act, busy }) {
  const q = view.question
  const left = useCountdown(view.q_started_at, q.limit_sec)
  const last = useRef(null)
  useEffect(() => { const s = Math.ceil(left); if (s <= 3 && s > 0 && s !== last.current && me.answer == null) fx.tick(); last.current = s }, [left, me.answer])

  const progress = <div className="sub-live num"><Check size={16} />{view.submitted} / {view.players}명 제출</div>
  if (me.answer != null) {
    const [label] = options(q)[me.answer]
    return <Waiting icon={<Check size={40} />} title="제출 완료" text={`'${label}'(으)로 냈어요.${me.double_now ? ' 2배 카드 적용 중!' : ''}`}>{progress}</Waiting>
  }
  if (left <= 0) return <Waiting icon={<Clock size={38} />} title="시간 종료" text="정답 공개를 기다려 주세요">{progress}</Waiting>

  const ox = q.type === 'ox', poll = q.type === 'poll'
  const hide = me.hide ?? []
  const canCard = !me.card && !poll && !q.is_bet
  return <>
    <div className="qhead">
      <span className="round">{q.is_bet ? <Flame size={18} /> : poll ? <Vote size={18} /> : null}{q.round} · {q.idx + 1}/{view.total_q}</span>
      {progress}
    </div>
    <div className={`timer ${left <= 5 ? 'hurry' : ''}`}>
      <div className="bar"><i style={{ width: `${(left / q.limit_sec) * 100}%` }} /></div>
      <b className="num">{Math.ceil(left)}</b>
    </div>
    <h1 className="title q-title">{q.q}</h1>
    {poll && <p className="lead" style={{ marginTop: -8 }}>정답 없는 투표예요. 점수엔 영향 없어요.</p>}
    {q.music && <div className="music"><span className="eq"><i /><i /><i /><i /></span>진행자가 노래를 틀어요. 잘 들어 보세요!</div>}
    {q.type === 'survey' && <p className="rule-hint"><Vote size={16} />다수결! 가장 많은 사람이 고른 답이 정답이에요</p>}
    {q.type === 'minority' && <p className="rule-hint"><Vote size={16} />소수결! 가장 적은 사람이 고른 답이 정답이에요</p>}
    <QImage q={q} left={left} />
    {me.double_now && <div className="badge-on"><Zap size={18} />2배 카드 사용 중</div>}
    {canCard && <div className="cards">
      {q.type === 'mc' && <button disabled={busy} onClick={() => act(() => rpc('hq_card', { p_player: me.id, p_kind: 'fifty' }))}><Split size={18} />50:50</button>}
      <button disabled={busy} onClick={() => act(() => rpc('hq_card', { p_player: me.id, p_kind: 'double' }))}><Zap size={18} />점수 2배</button>
      {q.idx <= 1 && <small>찬스 카드는 게임 전체에서 딱 1장! 50:50은 오답 2개 지우기, 2배는 맞히면 점수 두 배.</small>}
    </div>}
    <div className={`choices ${ox ? 'ox' : ''} ${!ox && options(q).every(([l]) => String(l).length <= 7) ? 'two' : ''}`}>
      {options(q).map(([label, k, bg, dark], i) => hide.includes(i)
        ? <div key={i} className="choice gone"><span className="k">{k}</span>{label}</div>
        : <button key={i} className={`choice ${dark ? 'dark' : ''}`} style={{ background: bg }} disabled={busy}
            onClick={() => act(() => rpc('hq_answer', { p_player: me.id, p_choice: i }))}>
            {ox ? label : <><span className="k">{k}</span>{label}</>}
          </button>)}
    </div>
  </>
}

function RankDelta({ me }) {
  const d = me.prev_rank ? me.prev_rank - me.rank : 0
  if (d > 0) return <span className="up"><ArrowUp size={22} />{d}</span>
  if (d < 0) return <span className="down"><ArrowDown size={22} />{-d}</span>
  return <span style={{ color: 'var(--mute)' }}><Minus size={22} /></span>
}

function Dist({ view, me }) {
  const q = view.question, total = Math.max(1, (view.dist ?? []).reduce((a, b) => a + b, 0))
  return <div className="dist">
    {options(q).map(([label, k, bg], i) => {
      const n = view.dist?.[i] ?? 0, win = isCorrect(q, i)
      return <div key={i} className={`dist-row ${win ? 'win' : q.answer != null ? 'dim' : ''}`}>
        <div className="dist-label"><span>{win && <Check size={18} className="win-check" />}{q.type !== 'ox' && <b className="num">{k}</b>} {label}{win && <strong className="win-tag">정답</strong>}{me.answer === i && <em>내 선택</em>}</span><b className="num">{n}명</b></div>
        <div className="dist-bar"><i style={{ width: `${(n / total) * 100}%`, background: bg }} /></div>
      </div>
    })}
  </div>
}

function Top5({ view, title = '지금 TOP 5' }) {
  return <div className="panel top5">
    <h3><Crown size={18} />{title}</h3>
    {view.ranking.slice(0, 5).map((p) => (
      <div key={p.name} className={`mini-row ${p.is_me ? 'me' : ''}`}>
        <b className="num">{p.rank}</b><span>{p.name}</span>
        <small className="num">{p.gain > 0 ? `+${fmt(p.gain)}` : ''}</small><b className="num">{fmt(p.score)}</b>
      </div>))}
  </div>
}

function Result({ view, me }) {
  const q = view.question
  const poll = q.type === 'poll'
  const none = me.answer == null, ok = !none && isCorrect(q, me.answer)
  const played = useRef(null)
  useEffect(() => {
    if (poll || none || played.current === q.idx) return
    played.current = q.idx
    ok ? fx.correct() : fx.wrong()
  }, [q.idx]) // eslint-disable-line

  const b = me.bonus ?? {}
  const chips = [
    b.combo && [<Flame size={16} key="i" />, `${b.streak}연속 +${fmt(b.combo)}`],
    b.double && [<Zap size={16} key="i" />, `2배 카드 +${fmt(b.double)}`],
    b.underdog && [<ArrowUp size={16} key="i" />, `역전 보너스 +${fmt(b.underdog)}`],
    b.bet != null && [<Flame size={16} key="i" />, `베팅 ${b.bet > 0 ? '+' : ''}${fmt(b.bet)}`],
  ].filter(Boolean)

  return <>
    {poll
      ? <div className="verdict none"><h2>투표 결과</h2></div>
      : <div className={`verdict ${none ? 'none' : ok ? 'ok' : 'no'}`}>
          <h2>{none ? '시간 초과' : ok ? '정답!' : '아쉽다'}</h2>
          {q.answer != null && <div className="answer-pill"><Check size={20} />정답 <b>{[q.answer, ...(q.alt ?? [])].map((i) => options(q)[i][0]).join(' · ')}</b></div>}
          {!ok && !none && q.answer != null && <p className="verdict-sub">내 답: {options(q)[me.answer][0]}</p>}
          <div className="gain num">{me.gain > 0 ? '+' : ''}{fmt(me.gain)}</div>
          {chips.length > 0 && <div className="chips">{chips.map(([icon, t], i) => <span key={i}>{icon}{t}</span>)}</div>}
        </div>}
    {!poll && <div className="stat-row">
      <div className="stat"><small>지금 순위</small><b className="num">{me.rank}위 <RankDelta me={me} /></b></div>
      <div className="stat"><small>연속 정답</small><b className="num">{me.streak > 0 ? <><Flame size={22} color="var(--beer)" />{me.streak}</> : '-'}</b></div>
    </div>}
    {q.has_image && <QImage q={q} />}
    <Dist view={view} me={me} />
    {(() => { const t = trap(q, view.dist); return t && <div className="trap"><AlertCircle size={18} />오늘의 함정: <b>'{t.label}'</b>에 {t.n}명이 속았어요</div> })()}
    <Reactions view={view} />
    {q.note && <div className="panel note"><MessageCircle size={22} color="var(--beer)" /><span>{q.note}</span></div>}
    {!poll && <Top5 view={view} />}
  </>
}

// 정답 공개 때 리액션. 누를 때마다 서버에 1씩 쌓이고 모두의 폰·진행자 화면에 숫자가 오른다.
function Reactions({ view }) {
  const [mine, setMine] = useState({})
  const r = view.reactions ?? {}
  return <div className="reacts">
    {Object.entries(REACT_EMOJI).map(([k, e]) => (
      <button key={k} aria-label={`리액션 ${e}`} onClick={() => {
        try { navigator.vibrate?.(15) } catch { /* noop */ }
        setMine((m) => ({ ...m, [k]: (m[k] ?? 0) + 1 }))
        rpc('hq_react', { p_kind: k }, { retry: false }).catch(() => {})
      }}><span>{e}</span><b className="num">{Math.max(r[k] ?? 0, mine[k] ?? 0)}</b></button>
    ))}
  </div>
}

function Bet({ me, act, busy }) {
  const opts = [[0, '안 걸기', '점수 그대로'], [50, '반만 걸기', `${fmt(Math.round(me.score / 2))}점`], [100, '올인', `${fmt(me.score)}점 전부`]]
  return <>
    <div className="round"><Flame size={18} />마지막 베팅</div>
    <h1 className="title">내 점수, 얼마나 걸까요?</h1>
    <div className="panel bet-explain">
      <p>마지막 문제를 맞히면 <b>건 점수만큼 더</b> 받고, 틀리거나 못 풀면 <b>건 점수만큼 잃어요.</b> 문제 점수(최대 1,000)는 따로 받아요.</p>
      <p className="num">예) 지금 {fmt(me.score)}점에서 올인 → 맞히면 <b className="up">{fmt(me.score * 2)}점 + 문제 점수</b>, 틀리면 <b className="down">0점</b></p>
    </div>
    <p className="lead" style={{ fontSize: 15 }}>마감 전까지 바꿀 수 있어요. 안 고르면 '안 걸기'예요.</p>
    <div className="bet">
      {opts.map(([v, l, sub]) => (
        <button key={v} disabled={busy} className={`${me.bet === v ? 'on' : ''} ${v === 100 ? 'allin' : ''}`}
          onClick={() => act(() => rpc('hq_bet', { p_player: me.id, p_pct: v }))}>
          <span>{l}</span><small className="num">{me.bet === v ? '선택함' : sub}</small>
        </button>
      ))}
    </div>
  </>
}

function Final({ view, me }) {
  const [a, b, c] = view.ranking
  const done = useRef(false)
  useEffect(() => { if (!done.current) { done.current = true; if (me.rank <= 3) fx.fanfare() } }, []) // eslint-disable-line
  const slot = (p, cls, place) => <div className={`pod ${cls} ${p?.is_me ? 'me' : ''}`}>
    {p ? <><Medal size={26} /><span className="pl num">{place}</span><span className="nm">{p.name}</span><span className="pt num">{fmt(p.score)}</span></> : null}
  </div>
  return <>
    <div className="round"><Trophy size={18} />최종 순위</div>
    <div className="podium-phone">{slot(b, 'p2', 2)}{slot(a, 'p1', 1)}{slot(c, 'p3', 3)}</div>
    <div className={`panel my-final ${me.rank <= 3 ? 'win' : ''}`}>
      <small>내 순위</small>
      <b className="num">{view.players}명 중 {me.rank}위</b>
      <span>{me.rank <= 3 ? `축하해요! ${me.rank}등 상품의 주인공이에요` : '아직 행운상 추첨이 남았어요!'}</span>
    </div>
    {view.ranking.length > 3 && <Top5 title="4등부터" view={{ ...view, ranking: view.ranking.slice(3, 8) }} />}
  </>
}

// 서버가 뽑은 당첨자를 모든 폰에서 동시에 3초간 룰렛으로 돌린 뒤 공개
function Draw({ view }) {
  const [shown, setShown] = useState(null)
  const ws = view.winners ?? []
  useEffect(() => {
    if (!ws.length) { setShown(null); return }
    const names = view.spin?.length ? view.spin : ws.map((w) => w.name)
    const started = Date.parse(view.drawn_at)
    let k = 0
    const t = setInterval(() => {
      if (serverNow() - started > 3000) { setShown('done'); clearInterval(t); if (ws.some((w) => w.is_me)) fx.fanfare() }
      else setShown(names[k++ % names.length])
    }, 85)
    return () => clearInterval(t)
  }, [view.drawn_at]) // eslint-disable-line
  const done = shown === 'done'
  const mine = ws.some((w) => w.is_me)
  return <div className="center" style={{ flex: 1, alignContent: 'center' }}>
    <div className="big-icon"><Gift size={38} /></div>
    <p className="round" style={{ justifyContent: 'center' }}>행운상 추첨 · 4등 이하 대상</p>
    {!ws.length && <><div className="wheel-phone">두근두근</div><p className="lead">진행자가 곧 추첨을 시작해요</p></>}
    {ws.length > 0 && !done && <div className="wheel-phone">{shown}</div>}
    {ws.length > 0 && done && <>
      <div className="winners">{ws.map((w) => <span key={w.name} className={w.is_me ? 'me' : ''}>{w.name}</span>)}</div>
      <p className="title" style={{ fontSize: 24 }}>{mine ? '당첨! 앞으로 나와 주세요' : `${ws.length}명 당첨, 축하합니다!`}</p>
    </>}
    {view.drawn > 0 && <p className="lead num">지금까지 행운상 {view.drawn}명</p>}
  </div>
}

// 마무리 장표: 감사 인사 + 수상자 + 내 기록. 이 화면을 캡처해 단톡방에 올리기 좋게.
function End({ view, me }) {
  const [a, b, c] = view.ranking
  const st = view.end_stats ?? {}
  const total = st.questions ?? 0
  return <>
    <div className="end-hero">
      <Beer size={34} />
      <h1>{view.end_msg}</h1>
      <p className="num">{view.players}명 참여 · {fmt(st.answers)}번 답했어요</p>
    </div>
    <div className="panel end-awards">
      <h3><Trophy size={18} />오늘의 수상자</h3>
      {[a, b, c].map((p, i) => p && <div key={i} className={`award ${p.is_me ? 'me' : ''}`}><Medal size={20} /><b>{i + 1}등</b><span>{p.name}</span><em className="num">{fmt(p.score)}</em></div>)}
      {st.streak_king && st.streak_king.n >= 2 && <div className="award"><Flame size={20} /><b>연속 정답왕</b><span>{st.streak_king.name}</span><em className="num">{st.streak_king.n}연속</em></div>}
      {(view.lucky_all ?? []).length > 0 && <div className="award lucky"><Gift size={20} /><b>행운상</b><span>{view.lucky_all.join(', ')}</span></div>}
    </div>
    <div className="panel end-me">
      <h3><UserRound size={18} />{me.name} 님의 기록</h3>
      <div className="stat-row">
        <div className="stat"><small>최종 순위</small><b className="num">{me.rank}위</b></div>
        <div className="stat"><small>점수</small><b className="num">{fmt(me.score)}</b></div>
        <div className="stat"><small>맞힌 문제</small><b className="num">{me.correct} / {total}</b></div>
        <div className="stat"><small>최고 연속</small><b className="num">{me.max_streak}연속</b></div>
      </div>
    </div>
    <p className="lead" style={{ textAlign: 'center', fontSize: 15 }}>이 화면을 캡처해서 단톡방에 자랑해 보세요</p>
    {view.end_credits && <details className="credits"><summary>사진 출처</summary>{view.end_credits}</details>}
  </>
}


// 참가자 명단 + 순위(누구나 볼 수 있음). 내 자리를 강조한다.
function RosterSheet({ view, onClose }) {
  const list = view.roster ?? []
  const started = list.some((p) => p.score > 0)
  return <div className="sheet-bg" onClick={onClose}>
    <div className="sheet" onClick={(e) => e.stopPropagation()} role="dialog" aria-label="참가자 명단">
      <div className="sheet-head"><b>{started ? '지금 순위' : '참가자 명단'} · <span className="num">{list.length}명</span></b>
        <button onClick={onClose} aria-label="닫기"><CloseIcon size={20} /></button></div>
      <div className="sheet-list">
        {list.map((p, i) => <div key={p.name} className={`roster-row ${p.is_me ? 'me' : ''}`}>
          <b className="num">{started ? p.rank : i + 1}</b><span>{p.name}{p.is_me && <em>나</em>}</span>{started && <small className="num">{fmt(p.score)}</small>}
        </div>)}
      </div>
    </div>
  </div>
}

// 대기 중 연습 한 문제(점수 없음, 서버에 안 보냄): 누르는 법과 정답 화면을 미리 익힌다
function Practice() {
  const [pick, setPick] = useState(null)
  const opts = [['O', 'var(--o)'], ['X', 'var(--x)']]
  return <div className="panel practice">
    <p style={{ margin: '0 0 10px', fontWeight: 800 }}>연습 문제 · 점수 없음</p>
    <p style={{ margin: '0 0 12px', fontSize: 20 }}>"오늘 회식 퀴즈 이름은 한잔 퀴즈다"</p>
    {pick == null
      ? <div className="choices ox" style={{ marginTop: 0 }}>{opts.map(([l, c], i) => <button key={l} className="choice" style={{ background: c, minHeight: 90, fontSize: 44 }} onClick={() => { setPick(i); i === 0 ? fx.correct() : fx.wrong() }}>{l}</button>)}</div>
      : <div className={`verdict ${pick === 0 ? 'ok' : 'no'}`} style={{ padding: '18px 12px' }}>
          <h2 style={{ fontSize: 30 }}>{pick === 0 ? '정답! 이렇게 하면 돼요' : '아쉽다! 정답은 O'}</h2>
          <button className="link" style={{ color: 'inherit' }} onClick={() => setPick(null)}>다시 해 보기</button>
        </div>}
  </div>
}
