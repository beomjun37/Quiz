import { useEffect, useState } from 'react'
import QRCode from 'qrcode'
import { Beer, Flame, Gift, MessageCircle, Trophy } from 'lucide-react'
import { useCountdown, useView } from '../lib/useView'
import { fmt, options } from '../lib/ui'
import { serverNow } from '../lib/clock'

// TV·빔프로젝터용. 1.5초마다 갱신해 제출 인원이 실시간으로 올라간다.
export default function Screen() {
  const { view, error } = useView(null, 1500)
  if (!view) return <div className="screen"><h1>한잔 퀴즈</h1><p className="lead">{error ? '연결 중…' : '불러오는 중…'}</p></div>
  switch (view.phase) {
    case 'lobby': return <Lobby view={view} />
    case 'bet': return <BetBoard view={view} />
    case 'q': case 'answer': return <QBoard view={view} />
    case 'final': return <Final view={view} />
    case 'draw': return <Draw view={view} />
    default: return null
  }
}

function Head({ left, right }) {
  return <div className="screen-head"><span className="round">{left}</span><span className="num">{right}</span></div>
}

function Lobby({ view }) {
  const [qr, setQr] = useState(null)
  const url = location.href.split('#')[0]
  useEffect(() => { QRCode.toDataURL(url, { width: 560, margin: 0, color: { dark: '#0d0f14' } }).then(setQr) }, [url])
  return <div className="screen">
    <Head left={<><Beer size={30} />한잔 퀴즈</>} right="개인전" />
    <div className="lobby">
      <div className="qr">{qr && <img src={qr} alt="입장 QR 코드" width={340} height={340} style={{ display: 'block' }} />}</div>
      <div style={{ display: 'grid', gap: 14 }}>
        <h1>QR 찍고<br />닉네임만 적으면 끝</h1>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 16 }}>
          <span className="count num">{view.players}</span>
          <span style={{ fontSize: 40, fontWeight: 700, color: 'var(--mute)' }}>명 입장</span>
        </div>
      </div>
    </div>
  </div>
}

function Board({ rows, limit = 10 }) {
  return <div className="board">{rows.slice(0, limit).map((p, i) => (
    <div key={p.name} className={`row ${p.rank === 1 ? 'first' : ''}`} style={{ animationDelay: `${i * 40}ms` }}>
      <span className="rk num">{p.rank}</span>
      <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{p.name}</span>
      <span className="gain num">{p.gain > 0 ? `+${fmt(p.gain)}` : ''}</span>
      <span className="sc num">{fmt(p.score)}</span>
    </div>))}</div>
}

function BetBoard({ view }) {
  const b = view.bets ?? {}
  return <div className="screen">
    <Head left={<><Flame size={30} />마지막 베팅</>} right={`${view.players}명`} />
    <h1>마지막 문제, 얼마나 거시겠습니까?</h1>
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 18 }}>
      {[['100', '올인', 'var(--x)'], ['50', '반만', 'var(--beer)'], ['0', '안 걸기', 'var(--mute)']].map(([k, l, c]) => (
        <div key={k} className="panel" style={{ textAlign: 'center', fontSize: 34, fontWeight: 700 }}>{l}
          <div className="num" style={{ fontSize: 110, fontWeight: 900, color: c, lineHeight: 1.1 }}>{b[k] ?? 0}</div></div>))}
    </div>
    <Board rows={view.ranking} limit={5} />
  </div>
}

function QBoard({ view }) {
  const q = view.question
  const left = useCountdown(view.q_started_at, q.limit_sec)
  const revealed = view.phase === 'answer'
  return <div className="screen">
    <Head left={<>{q.is_bet && <Flame size={30} />}{q.round}</>} right={`${q.idx + 1} / ${view.total_q}`} />
    <h1>{q.q}</h1>
    {!revealed && <div className={`screen-timer ${left <= 5 ? 'hurry' : ''}`}>
      <span className="sec num">{Math.ceil(left)}</span>
      <span className="sub num">{view.submitted} / {view.players}명 제출</span></div>}
    <div className="screen-choices">
      {options(q).map(([label, k, bg, dark], i) => {
        const win = revealed && i === q.answer
        return <div key={i} className={`screen-choice ${q.type === 'ox' ? 'ox' : ''} ${dark ? 'dark' : ''} ${revealed ? (win ? 'win' : 'dim') : ''}`} style={{ background: bg }}>
          {q.type === 'mc' && <span className="num" style={{ opacity: 0.7 }}>{k}</span>}{label}
          {revealed && <span className="n num">{view.dist?.[i] ?? 0}명</span>}
        </div>
      })}
    </div>
    {revealed && <>
      {q.note && <div className="screen-note"><MessageCircle size={36} color="var(--beer)" />{q.note}</div>}
      <Board rows={view.ranking} limit={5} />
    </>}
  </div>
}

function Final({ view }) {
  const [a, b, c] = view.ranking
  const slot = (p, cls, place) => p
    ? <div className={cls}><span className="pl num">{place}</span><span className="nm">{p.name}</span><span className="pt num">{fmt(p.score)}점</span></div>
    : <div className={cls} />
  return <div className="screen">
    <Head left={<><Trophy size={30} />최종 순위</>} right={`${view.players}명 참여`} />
    <div className="podium">{slot(b, 'p2', 2)}{slot(a, 'p1', 1)}{slot(c, 'p3', 3)}</div>
    <Board rows={view.ranking.slice(3)} limit={7} />
  </div>
}

// 서버가 뽑은 당첨자를 3초간 이름 룰렛으로 돌린 뒤 공개
function Draw({ view }) {
  const [shown, setShown] = useState(null)
  useEffect(() => {
    if (!view.winner) { setShown(null); return }
    const names = view.spin?.length ? view.spin : [view.winner.name]
    const started = Date.parse(view.drawn_at)
    let k = 0
    const t = setInterval(() => {
      if (serverNow() - started > 3000) { setShown('done'); clearInterval(t) } else setShown(names[k++ % names.length])
    }, 85)
    return () => clearInterval(t)
  }, [view.drawn_at]) // eslint-disable-line
  const done = shown === 'done'
  return <div className="screen">
    <Head left={<><Gift size={30} />행운의 추첨</>} right={`${view.drawn}명 당첨`} />
    <div style={{ flex: 1, display: 'grid', alignContent: 'center' }}>
      <div className={`wheel ${done ? 'done' : ''}`}>{!view.winner ? '두근두근' : done ? view.winner.name : shown}</div>
      {done && <p className="title" style={{ textAlign: 'center' }}>축하합니다! 앞으로 나와 주세요</p>}
    </div>
  </div>
}
