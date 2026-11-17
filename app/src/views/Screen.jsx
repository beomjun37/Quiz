import { useEffect, useState } from 'react'
import QRCode from 'qrcode'
import { useCountdown, useView } from '../lib/useView'
import { options } from '../lib/ui'
import { serverNow } from '../lib/clock'

// TV·빔프로젝터용. 1.5초마다 갱신해 제출 인원이 실시간으로 올라가게 한다.
export default function Screen() {
  const { view, error } = useView(null, 1500)
  if (!view) return <div className="screen"><h1>🍻 한잔 퀴즈</h1><div className="mute">{error ?? '연결 중…'}</div></div>
  switch (view.phase) {
    case 'lobby': return <Lobby view={view} />
    case 'bet': return <BetBoard view={view} />
    case 'q': case 'answer': return <QBoard view={view} />
    case 'final': return <div className="screen"><h1>🏆 최종 순위</h1><Ranking view={view} limit={12} /><TopPlayers view={view} /></div>
    case 'draw': return <Draw view={view} />
    default: return null
  }
}

function Lobby({ view }) {
  const [qr, setQr] = useState(null)
  const url = location.href.split('#')[0]
  useEffect(() => { QRCode.toDataURL(url, { width: 520, margin: 1 }).then(setQr) }, [url])
  return <div className="screen">
    <h1>🍻 한잔 퀴즈</h1>
    <div style={{ display: 'flex', gap: 48, alignItems: 'center', flexWrap: 'wrap' }}>
      {qr && <img src={qr} alt="입장 QR" width={300} height={300} style={{ borderRadius: 16 }} />}
      <div>
        <div className="big" style={{ fontSize: 44 }}>QR 찍고 입장!</div>
        <div className="mute" style={{ fontSize: 26 }}>이름 쓰고 테이블 번호만 누르면 끝</div>
        <div style={{ fontSize: 140, fontWeight: 900, color: 'var(--acc)' }}>{view.players}<small style={{ fontSize: 44 }}>명</small></div>
      </div>
    </div>
  </div>
}

function Ranking({ view, limit = 5 }) {
  return <div>{view.teams.slice(0, limit).map((t, i) => (
    <div key={t.table_no} className={`rank ${i === 0 ? 'top' : ''}`}>
      <span>{i + 1}</span><span>{t.table_no}번 테이블 <small className="mute">({t.n}명)</small></span>
      <span style={{ textAlign: 'right' }}>{t.avg.toLocaleString()}</span>
    </div>))}</div>
}

// 20명 규모에선 개인 순위가 재미 포인트. 100명이어도 상위 5명만 보여준다.
function TopPlayers({ view }) {
  if (!view.top.length) return null
  return <div className="mute" style={{ fontSize: 26 }}>🔥 개인 TOP {view.top.length}: {view.top.map((p) => `${p.name}(${p.score.toLocaleString()})`).join(' · ')}</div>
}

function BetBoard({ view }) {
  const b = view.bets ?? {}
  return <div className="screen">
    <div><span className="tag" style={{ fontSize: 28 }}>R3 올인 베팅</span></div>
    <h1>마지막 문제, 얼마나 거시겠습니까?</h1>
    <div style={{ display: 'flex', gap: 24, fontSize: 40 }}>
      {[['100', '올인 🔥'], ['50', '반만'], ['0', '안 건다']].map(([k, l]) => (
        <div key={k} className="card" style={{ flex: 1, textAlign: 'center' }}>{l}
          <div style={{ fontSize: 96, fontWeight: 900, color: 'var(--acc)' }}>{b[k] ?? 0}</div></div>))}
    </div>
    <Ranking view={view} />
  </div>
}

function QBoard({ view }) {
  const q = view.question
  const left = useCountdown(view.q_started_at, q.limit_sec)
  const revealed = view.phase === 'answer'
  return <div className="screen">
    <div><span className="tag" style={{ fontSize: 28 }}>{q.round} · {q.idx + 1}/{view.total_q}</span></div>
    <h1>{q.q}</h1>
    {!revealed && <div style={{ display: 'flex', gap: 40, alignItems: 'baseline' }}>
      <div style={{ fontSize: 110, fontWeight: 900, color: left <= 5 ? 'var(--x)' : 'var(--acc)' }}>{Math.ceil(left)}</div>
      <div style={{ fontSize: 40 }}>{view.submitted} / {view.players}명 제출</div></div>}
    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
      {options(q).map(([label, color], i) => {
        const win = revealed && i === q.answer
        return <div key={i} className={`card ${win ? 'pop' : ''}`} style={{
          fontSize: 38, border: `4px solid ${win ? '#fff' : 'transparent'}`,
          background: revealed && !win ? '#2a2e36' : color, opacity: revealed && !win ? 0.5 : 1,
        }}>{label}{revealed && <b style={{ float: 'right' }}>{view.dist?.[i] ?? 0}명</b>}</div>
      })}
    </div>
    {revealed && <>{q.note && <div className="big" style={{ fontSize: 40 }}>💬 {q.note}</div>}<Ranking view={view} /></>}
  </div>
}

// 서버가 뽑은 당첨자를 3초간 이름 룰렛으로 보여준 뒤 공개
function Draw({ view }) {
  const [shown, setShown] = useState(null)
  const key = view.drawn_at
  useEffect(() => {
    if (!view.winner) { setShown(null); return }
    const names = view.spin?.length ? view.spin : [view.winner.name]
    const started = Date.parse(view.drawn_at)
    let k = 0
    const t = setInterval(() => {
      if (serverNow() - started > 3000) { setShown('done'); clearInterval(t) }
      else setShown(names[k++ % names.length])
    }, 90)
    return () => clearInterval(t)
  }, [key]) // eslint-disable-line
  const done = shown === 'done'
  return <div className="screen">
    <h1>🎁 행운의 추첨</h1>
    <div className={`wheel ${done ? 'pop' : ''}`}>{!view.winner ? '???' : done ? `${view.winner.name} 님!` : shown}</div>
    {done && <div className="big" style={{ textAlign: 'center' }}>{view.winner.table_no}번 테이블 축하합니다 🎉</div>}
  </div>
}
