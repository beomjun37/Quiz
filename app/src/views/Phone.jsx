import { useEffect, useRef, useState } from 'react'
import { AlertCircle, ArrowDown, ArrowUp, Beer, Check, Clock, Dices, Flame, Gift, LogIn, MessageCircle, Minus, Trophy, UserRound } from 'lucide-react'
import { rpc } from '../lib/supabase'
import { useCountdown, useView } from '../lib/useView'
import { errText, fmt, options, randomNick } from '../lib/ui'

const KEY = 'hq-player'
const load = () => { try { return localStorage.getItem(KEY) } catch { return null } }
const store = (v) => { try { v ? localStorage.setItem(KEY, v) : localStorage.removeItem(KEY) } catch { /* 사생활 모드 */ } }

export default function Phone() {
  const [pid, setPid] = useState(load)
  const { view, error, refetch } = useView(pid, 2500)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState(null)

  // 진행자가 초기화해 내 기록이 사라졌으면 입장부터 다시
  const [kicked, setKicked] = useState(false)
  useEffect(() => { if (view && pid && view._for === pid && !view.me) { store(null); setPid(null); setKicked(true) } }, [view, pid])
  useEffect(() => { setMsg(null) }, [view?.phase, view?.qi])

  async function act(fn) {
    if (busy) return
    setBusy(true); setMsg(null)
    try { await fn(); await refetch() } catch (e) { setMsg(errText(e.message)) } finally { setBusy(false) }
  }

  if (!view) return (
    <div className="phone"><div className="center"><div className="big-icon"><Beer size={38} /></div>
      <p className="title">한잔 퀴즈</p><p className="lead">{error ? '연결 중이에요…' : '불러오는 중…'}</p></div></div>
  )

  if (!pid) return <Join view={view} act={act} msg={msg || (kicked ? '새 게임이 시작됐어요. 닉네임을 입력하고 다시 들어와 주세요' : null)} busy={busy} onJoined={(id) => { store(id); setPid(id) }} />

  const me = view.me
  if (!me) return <Waiting icon={<Beer size={38} />} title="입장하는 중…" text="잠시만요" />
  const body = {
    lobby: <>
      <Waiting icon={<Beer size={38} />} title="입장 완료!" text="잔 채우고 잠시만 기다려 주세요. 곧 첫 문제가 열려요." />
      <button className="lead" style={{ textDecoration: 'underline', textUnderlineOffset: 4, padding: 12 }} disabled={busy}
        onClick={() => act(async () => { await rpc('hq_leave', { p_player: me.id }); store(null); setPid(null) })}>닉네임 바꾸기</button>
    </>,
    bet: <Bet me={me} act={act} busy={busy} />,
    q: <Question view={view} me={me} act={act} busy={busy} />,
    answer: <Result view={view} me={me} />,
    final: <Final me={me} players={view.players} />,
    draw: <Draw view={view} />,
  }[view.phase]

  return (
    <div className="phone">
      <div className="statusbar">
        <div className="me-chip"><UserRound size={20} color="var(--mute)" /><span>{me.name}</span></div>
        <div className="score-chip num">{fmt(me.score)}<small>점 · {me.rank}위</small></div>
      </div>
      {body}
      {msg && <div className="err" role="alert"><AlertCircle size={20} />{msg}</div>}
    </div>
  )
}

function Waiting({ icon, title, text }) {
  return <div className="center" style={{ flex: 1, alignContent: 'center' }}>
    <div className="big-icon">{icon}</div><p className="title">{title}</p><p className="lead">{text}</p>
  </div>
}

function Join({ view, act, msg, busy, onJoined }) {
  const [name, setName] = useState('')
  const ref = useRef(null)
  const joinId = useRef(crypto.randomUUID())
  const live = { lobby: '곧 시작해요', bet: '마지막 베팅 중', q: `${view.qi + 1}번 문제 푸는 중`, answer: `${view.qi + 1}번 정답 공개 중`, final: '최종 순위 발표 중', draw: '경품 추첨 중' }[view.phase]

  function submit(e) {
    e.preventDefault()
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
            placeholder="예: 소맥장인" value={name} onChange={(e) => setName(e.target.value)} />
          <button type="button" className="icon-btn" aria-label="닉네임 추천" onClick={() => { setName((v) => randomNick(v)); ref.current?.focus() }}><Dices size={28} /></button>
        </div>
        <span className="lead" style={{ fontSize: 15 }}>고민되면 주사위를 눌러 보세요</span>
      </label>
      {msg && <div className="err" role="alert"><AlertCircle size={20} />{msg}</div>}
      <button className="primary" style={{ marginTop: 'auto' }} disabled={busy}><LogIn size={24} />{busy ? '들어가는 중…' : '입장하기'}</button>
    </form>
  )
}

function Question({ view, me, act, busy }) {
  const q = view.question
  const left = useCountdown(view.q_started_at, q.limit_sec)
  if (me.answer != null) {
    const [label] = options(q)[me.answer]
    return <Waiting icon={<Check size={40} />} title="제출 완료" text={`'${label}'(으)로 냈어요. 정답은 큰 화면에서 공개돼요.`} />
  }
  if (left <= 0) return <Waiting icon={<Clock size={38} />} title="시간 종료" text="다음 문제는 꼭 잡아 봐요!" />
  const ox = q.type === 'ox'
  return <>
    <div className="round">{q.is_bet ? <Flame size={18} /> : null}{q.round} · {q.idx + 1}/{view.total_q}</div>
    <div className={`timer ${left <= 5 ? 'hurry' : ''}`}>
      <div className="bar"><i style={{ width: `${(left / q.limit_sec) * 100}%` }} /></div>
      <b className="num">{Math.ceil(left)}</b>
    </div>
    <h1 className="title">{q.q}</h1>
    <div className={`choices ${ox ? 'ox' : ''}`}>
      {options(q).map(([label, k, bg, dark], i) => (
        <button key={i} className={`choice ${dark ? 'dark' : ''}`} style={{ background: bg }} disabled={busy}
          onClick={() => act(() => rpc('hq_answer', { p_player: me.id, p_choice: i }))}>
          {ox ? label : <><span className="k">{k}</span>{label}</>}
        </button>
      ))}
    </div>
  </>
}

function RankDelta({ me }) {
  const d = me.prev_rank ? me.prev_rank - me.rank : 0
  if (d > 0) return <span className="up"><ArrowUp size={22} />{d}</span>
  if (d < 0) return <span className="down"><ArrowDown size={22} />{-d}</span>
  return <span style={{ color: 'var(--mute)' }}><Minus size={22} /></span>
}

function Result({ view, me }) {
  const q = view.question
  const none = me.answer == null, ok = !none && me.answer === q.answer
  const [answerLabel] = options(q)[q.answer]
  return <>
    <div className={`verdict ${none ? 'none' : ok ? 'ok' : 'no'}`}>
      <h2>{none ? '시간 초과' : ok ? '정답!' : '아쉽다'}</h2>
      <div className="gain num">{me.gain > 0 ? '+' : ''}{fmt(me.gain)}</div>
    </div>
    <div className="stat-row">
      <div className="stat"><small>지금 순위</small><b className="num">{me.rank}위 <RankDelta me={me} /></b></div>
      <div className="stat"><small>정답</small><b style={{ fontSize: 22 }}>{answerLabel}</b></div>
    </div>
    {q.note && <div className="panel note"><MessageCircle size={22} color="var(--beer)" /><span>{q.note}</span></div>}
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

function Final({ me, players }) {
  return <Waiting icon={<Trophy size={38} />} title={`${players}명 중 ${me.rank}위!`}
    text={me.rank === 1 ? '오늘의 퀴즈왕입니다. 앞으로 나와 주세요!' : '수고하셨어요. 곧 경품 추첨이 시작돼요.'} />
}

function Draw({ view }) {
  if (!view.winner) return <Waiting icon={<Gift size={38} />} title="경품 추첨 중" text="큰 화면을 봐 주세요. 내 이름이 나올지도?" />
  return view.winner.is_me
    ? <Waiting icon={<Gift size={38} />} title="당첨됐어요!" text="앞으로 나와 경품을 받아 가세요." />
    : <Waiting icon={<Gift size={38} />} title={`${view.winner.name} 님 당첨`} text="다음 추첨도 기대해 주세요." />
}
