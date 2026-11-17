import { useEffect, useRef, useState } from 'react'
import { rpc } from '../lib/supabase'
import { useCountdown, useView } from '../lib/useView'
import { errText, options } from '../lib/ui'

const KEY = 'hq-player'
const load = () => { try { return localStorage.getItem(KEY) } catch { return null } }
const store = (v) => { try { v ? localStorage.setItem(KEY, v) : localStorage.removeItem(KEY) } catch { /* 사파리 사생활 모드 */ } }

export default function Phone() {
  const [pid, setPid] = useState(load)
  const { view, error, refetch } = useView(pid, 2500)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState(null)

  // 진행자가 초기화해서 내 행이 사라졌으면 입장부터 다시
  useEffect(() => { if (view && pid && !view.me) { store(null); setPid(null) } }, [view, pid])

  async function act(fn) {
    if (busy) return
    setBusy(true); setMsg(null)
    try { await fn(); await refetch() } catch (e) { setMsg(errText(e.message)) } finally { setBusy(false) }
  }

  if (!view) return <div className="phone"><div className="big">🍻 한잔 퀴즈</div><div className="mute">{error ? `연결 중… (${error})` : '불러오는 중…'}</div></div>

  if (!pid || !view.me) return <Join view={view} act={act} msg={msg} onJoined={(id) => { store(id); setPid(id) }} />

  const me = view.me, q = view.question
  const head = <div className="mute">{me.name} · {me.table_no}번 테이블 · <b style={{ color: 'var(--acc)' }}>{me.score.toLocaleString()}점</b> · 개인 {me.rank}위</div>
  const wrap = (body) => <div className="phone">{head}{body}{msg && <div className="err">{msg}</div>}</div>

  switch (view.phase) {
    case 'lobby':
      return wrap(<><div className="card big">입장 완료!<br />잔 채우고 기다려 주세요 🍺</div><div className="mute">곧 화면에 첫 문제가 뜹니다.</div></>)
    case 'bet':
      return wrap(<Bet me={me} act={act} />)
    case 'q':
      return wrap(<Question view={view} me={me} act={act} busy={busy} />)
    case 'answer': {
      const ok = me.answer != null && me.answer === q.answer
      return wrap(<>
        <div className="card big pop" style={{ background: me.answer == null ? 'var(--card)' : ok ? 'var(--ok)' : 'var(--x)' }}>
          {me.answer == null ? '시간 초과 ⏰' : ok ? '정답! 🎉' : '아쉽다 😅'}
        </div>
        <div className="mute">정답: <b style={{ color: 'var(--fg)' }}>{options(q)[q.answer][0]}</b></div>
        {q.note && <div className="card" style={{ fontSize: 20 }}>💬 {q.note}</div>}
      </>)
    }
    case 'final': {
      const r = view.teams.findIndex((t) => t.table_no === me.table_no) + 1
      return wrap(<><div className="card big pop">우리 테이블 {r}위!</div><div className="mute">곧 행운의 추첨이 시작됩니다 🎁</div></>)
    }
    case 'draw':
      return wrap(<div className="card big">{!view.winner ? '두근두근 추첨 대기 중…' : view.winner.is_me ? '🎉 당첨! 앞으로 나와 주세요' : `당첨: ${view.winner.name} 님`}</div>)
    default:
      return wrap(null)
  }
}

function Join({ view, act, msg, onJoined }) {
  const [name, setName] = useState('')
  const ref = useRef(null)
  const live = { lobby: '곧 시작합니다', bet: '마지막 베팅 중', q: `${view.qi + 1}번 문제 진행 중`, answer: `${view.qi + 1}번 정답 공개 중`, final: '최종 순위 발표 중', draw: '추첨 중' }[view.phase]
  return (
    <div className="phone">
      <div className="big">🍻 한잔 퀴즈</div>
      <div className="card" style={{ fontSize: 18 }}>📢 지금 <b style={{ color: 'var(--acc)' }}>{live}</b> · {view.players}명 참여<br /><span className="mute">입장하면 바로 이어서 참여해요</span></div>
      <div className="mute">① 이름 쓰고 ② 앉은 테이블 번호 누르면 끝!</div>
      <input ref={ref} autoFocus placeholder="이름 (예: 김부장)" maxLength={12} value={name} onChange={(e) => setName(e.target.value)} />
      <div className="mute">우리 테이블은?</div>
      <div className="grid3">
        {Array.from({ length: view.tables }, (_, i) => (
          <button key={i} className="opt" style={{ background: '#374151' }}
            onClick={() => act(async () => {
              const n = (ref.current?.value ?? name).trim()
              if (!n) { ref.current?.focus(); throw new Error('BAD_NAME') }
              const r = await rpc('hq_join', { p_name: n, p_table: i + 1 })
              onJoined(r.id)
            })}>{i + 1}번</button>
        ))}
      </div>
      {msg && <div className="err">{msg}</div>}
    </div>
  )
}

function Question({ view, me, act, busy }) {
  const q = view.question
  const left = useCountdown(view.q_started_at, q.limit_sec)
  if (me.answer != null) return <><div className="card big">제출 완료 ✅</div><div className="mute">정답은 화면에서 공개됩니다.</div></>
  if (left <= 0) return <div className="card big">시간 종료 ⏰</div>
  const ox = q.type === 'ox'
  return <>
    <span className="tag">{q.round}</span>
    <div className="bar"><i style={{ width: `${(left / q.limit_sec) * 100}%` }} /></div>
    <div className="big">{q.q}</div>
    <div className={ox ? 'grid2' : ''} style={ox ? undefined : { display: 'grid', gap: 12 }}>
      {options(q).map(([label, color], i) => (
        <button key={i} className="opt" disabled={busy}
          style={{ background: color, ...(ox ? { fontSize: 56, minHeight: 160 } : {}) }}
          onClick={() => act(() => rpc('hq_answer', { p_player: me.id, p_choice: i }))}>{label}</button>
      ))}
    </div>
  </>
}

function Bet({ me, act }) {
  const choices = [[0, '안 건다 (0%)', '#374151', '#fff'], [50, '반만 (50%)', 'var(--acc)', '#111'], [100, '올인 (100%) 🔥', 'var(--x)', '#fff']]
  return <>
    <span className="tag">R3 올인 베팅</span>
    <div className="big">마지막 문제!<br />내 점수 얼마나 걸까?</div>
    <div className="mute">지금 {me.score.toLocaleString()}점. 맞히면 건 만큼 더 받고, 틀리면 건 만큼 잃습니다.</div>
    {choices.map(([v, l, bg, fg]) => (
      <button key={v} className="btn" style={{ background: bg, color: fg, outline: me.bet === v ? '4px solid #fff' : 'none' }}
        onClick={() => act(() => rpc('hq_bet', { p_player: me.id, p_pct: v }))}>{l}</button>
    ))}
    {me.bet != null && <div className="mute">✔ {me.bet}% 선택 · 마감 전까지 바꿀 수 있어요</div>}
  </>
}
