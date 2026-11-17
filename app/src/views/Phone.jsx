import { useEffect, useRef, useState } from 'react'
import {
  AlertCircle, ArrowDown, ArrowUp, Beer, Check, Clock, Crown, Dices, Flame, Gift, LogIn, Medal,
  MessageCircle, Minus, Sparkles, Split, Trophy, UserRound, Vote, Zap,
} from 'lucide-react'
import { rpc } from '../lib/supabase'
import { useCountdown, useView } from '../lib/useView'
import { errText, fmt, options, randomNick } from '../lib/ui'
import { serverNow } from '../lib/clock'
import { fx, unlockAudio } from '../lib/fx'

const KEY = 'hq-player'
const load = () => { try { return localStorage.getItem(KEY) } catch { return null } }
const store = (v) => { try { v ? localStorage.setItem(KEY, v) : localStorage.removeItem(KEY) } catch { /* 사생활 모드 */ } }

// 스크린 없이 폰만으로 진행한다: 문제·제출 현황·응답 분포·순위·시상·추첨이 전부 여기 나온다.
export default function Phone() {
  const [pid, setPid] = useState(load)
  const { view, error, refetch } = useView(pid, 2000)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState(null)
  const [kicked, setKicked] = useState(false)

  // 진행자가 새 게임을 시작해 내 기록이 사라졌으면 입장부터 다시
  useEffect(() => { if (view && pid && view._for === pid && !view.me) { store(null); setPid(null); setKicked(true) } }, [view, pid])
  useEffect(() => { setMsg(null) }, [view?.phase, view?.qi])
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
  }[view.phase]

  return (
    <div className="phone">
      <div className="statusbar">
        <div className="me-chip"><UserRound size={20} color="var(--mute)" /><span>{me.name}</span>
          {me.streak >= 2 && <span className="streak"><Flame size={15} />{me.streak}</span>}</div>
        <div className="score-chip num">{fmt(me.score)}<small>점 · {me.rank}위</small></div>
      </div>
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
  const live = { lobby: '곧 시작해요', bet: '마지막 베팅 중', q: `${view.qi + 1}번 문제 푸는 중`, answer: `${view.qi + 1}번 정답 공개 중`, final: '최종 순위 발표 중', draw: '행운상 추첨 중' }[view.phase]

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

function QImage({ q }) {
  const [src, setSrc] = useState(null)
  useEffect(() => {
    let dead = false
    setSrc(null)
    if (q.has_image) rpc('hq_image', { p_idx: q.idx }).then((d) => { if (!dead) setSrc(d) }).catch(() => {})
    return () => { dead = true }
  }, [q.idx, q.has_image])
  if (!q.has_image) return null
  return <div className="qimg">{src ? <img src={src} alt="문제 사진" /> : <span className="lead">사진 불러오는 중…</span>}</div>
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
    <h1 className="title">{q.q}</h1>
    {poll && <p className="lead" style={{ marginTop: -8 }}>정답 없는 투표예요. 점수엔 영향 없어요.</p>}
    <QImage q={q} />
    {me.double_now && <div className="badge-on"><Zap size={18} />2배 카드 사용 중</div>}
    {canCard && <div className="cards">
      {q.type === 'mc' && <button disabled={busy} onClick={() => act(() => rpc('hq_card', { p_player: me.id, p_kind: 'fifty' }))}><Split size={18} />50:50</button>}
      <button disabled={busy} onClick={() => act(() => rpc('hq_card', { p_player: me.id, p_kind: 'double' }))}><Zap size={18} />점수 2배</button>
      <small>찬스 카드 · 한 게임에 1장</small>
    </div>}
    <div className={`choices ${ox ? 'ox' : ''}`}>
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
      const n = view.dist?.[i] ?? 0, win = q.answer === i
      return <div key={i} className={`dist-row ${q.answer != null && !win ? 'dim' : ''}`}>
        <div className="dist-label"><span>{q.type !== 'ox' && <b className="num">{k}</b>} {label}{me.answer === i && <em>내 선택</em>}</span><b className="num">{n}명</b></div>
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
  const none = me.answer == null, ok = !none && me.answer === q.answer
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
          <div className="gain num">{me.gain > 0 ? '+' : ''}{fmt(me.gain)}</div>
          {chips.length > 0 && <div className="chips">{chips.map(([icon, t], i) => <span key={i}>{icon}{t}</span>)}</div>}
        </div>}
    {!poll && <div className="stat-row">
      <div className="stat"><small>지금 순위</small><b className="num">{me.rank}위 <RankDelta me={me} /></b></div>
      <div className="stat"><small>연속 정답</small><b className="num">{me.streak > 0 ? <><Flame size={22} color="var(--beer)" />{me.streak}</> : '-'}</b></div>
    </div>}
    <Dist view={view} me={me} />
    {q.note && <div className="panel note"><MessageCircle size={22} color="var(--beer)" /><span>{q.note}</span></div>}
    {!poll && <Top5 view={view} />}
  </>
}

function Bet({ me, act, busy }) {
  const opts = [[0, '안 걸기', '점수 그대로'], [50, '반만 걸기', `${fmt(Math.round(me.score / 2))}점`], [100, '올인', `${fmt(me.score)}점 전부`]]
  return <>
    <div className="round"><Flame size={18} />마지막 베팅</div>
    <h1 className="title">내 점수, 얼마나 걸까요?</h1>
    <p className="lead">맞히면 건 만큼 더 받고, 틀리면 건 만큼 잃어요. 마감 전까지 바꿀 수 있어요.</p>
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
      <span>{me.rank <= 3 ? `축하해요! ${me.rank}등 상품의 주인공이에요` : '아쉽지만, 이제 행운상 추첨이 남았어요'}</span>
    </div>
    {view.ranking.length > 3 && <Top5 title="4등부터" view={{ ...view, ranking: view.ranking.slice(3, 8) }} />}
  </>
}

// 서버가 뽑은 당첨자를 모든 폰에서 동시에 3초간 룰렛으로 돌린 뒤 공개
function Draw({ view }) {
  const [shown, setShown] = useState(null)
  useEffect(() => {
    if (!view.winner) { setShown(null); return }
    const names = view.spin?.length ? view.spin : [view.winner.name]
    const started = Date.parse(view.drawn_at)
    let k = 0
    const t = setInterval(() => {
      if (serverNow() - started > 3000) { setShown('done'); clearInterval(t); if (view.winner.is_me) fx.fanfare() }
      else setShown(names[k++ % names.length])
    }, 85)
    return () => clearInterval(t)
  }, [view.drawn_at]) // eslint-disable-line
  const done = shown === 'done'
  return <div className="center" style={{ flex: 1, alignContent: 'center' }}>
    <div className="big-icon"><Gift size={38} /></div>
    <p className="round" style={{ justifyContent: 'center' }}>행운상 추첨 · 4등 이하 대상</p>
    <div className={`wheel-phone ${done ? 'done' : ''}`}>{!view.winner ? '두근두근' : done ? view.winner.name : shown}</div>
    {done && <p className="title" style={{ fontSize: 24 }}>{view.winner.is_me ? '당첨! 앞으로 나와 주세요' : '축하합니다!'}</p>}
    {!view.winner && <p className="lead">진행자가 곧 추첨을 시작해요</p>}
    {view.drawn > 0 && <p className="lead num">지금까지 {view.drawn}명 당첨</p>}
  </div>
}

