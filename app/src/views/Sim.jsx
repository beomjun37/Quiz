import { useEffect, useRef, useState } from 'react'
import { ChevronLeft, ChevronRight, Pause, Play, Square } from 'lucide-react'
import Phone from './Phone'
import { rpc } from '../lib/supabase'
import { serverNow } from '../lib/clock'
import { errText } from '../lib/ui'

/**
 * #/sim — 진행자 연습 모드. 지금 문제 구성 그대로, 진행자가 참가자가 되어 처음부터 마무리(경품 추첨)까지 풀어 본다.
 * 실제 서버 게임을 쓰므로(가상 동료 29명 + 나) 점수·베팅·시상·추첨이 실전과 똑같이 동작한다.
 * 진행은 자동: 내가 답을 내거나 시간이 끝나면 정답 공개, 몇 초 뒤 다음 문제. 끝나면 '새 게임'으로 정리.
 */
const KEY = 'hq-player'
export default function Sim() {
  const [pin, setPin] = useState(() => { try { return sessionStorage.getItem('hq-pin') ?? localStorage.getItem('hq-pin-sim') ?? '' } catch { return '' } })
  const [started, setStarted] = useState(false)
  const [msg, setMsg] = useState(null)
  const [busy, setBusy] = useState(false)
  const admin = (action, arg = {}) => rpc('hq_admin', { p_pin: pin, p_action: action, p_arg: arg })

  async function start() {
    setBusy(true); setMsg(null)
    try {
      await admin('check')
      try { localStorage.setItem('hq-pin-sim', pin) } catch { /* noop */ }
      const v = await rpc('hq_view', {})
      if (v.phase !== 'lobby') throw new Error('게임이 진행 중이에요. 진행자 화면에서 "새 게임"을 누른 뒤 다시 시작해 주세요')
      if (v.players > 0 && !confirm(`이미 ${v.players}명이 입장해 있어요. 연습이 끝나면 '새 게임'으로 모두 정리돼요. 계속할까요?`)) return
      const me = await rpc('hq_join', { p_name: '진행자(연습)', p_id: crypto.randomUUID() }).catch(async () => rpc('hq_join', { p_name: `진행자 연습${Math.floor(Math.random() * 90 + 10)}`, p_id: crypto.randomUUID() }))
      try { localStorage.setItem(KEY, me.id) } catch { /* noop */ }
      await admin('bots', { n: 30 })
      setStarted(true)
    } catch (e) { setMsg(errText(e.message) === '처리 중 문제가 생겼어요' ? e.message : errText(e.message)) } finally { setBusy(false) }
  }

  if (!started) return <div className="phone">
    <h1 className="title">혼자 끝까지 풀어 보기</h1>
    <p className="lead">지금 문제 구성 그대로, 내가 참가자가 되어 첫 문제부터 시상·행운상 추첨·마무리 화면까지 풀어 봐요. 가상 동료 29명이 함께 풀고, 진행은 자동으로 넘어가요.</p>
    <div className="panel" style={{ fontSize: 15, display: 'grid', gap: 6 }}>
      <span>· 실제 서버 게임으로 돌아가요. <b>실제 회식 중에는 쓰지 마세요.</b></span>
      <span>· 다 끝나면 '연습 끝내기'로 정리돼요(문항은 그대로).</span>
    </div>
    <input type="password" inputMode="numeric" placeholder="진행자 PIN" value={pin} onChange={(e) => setPin(e.target.value)}
      style={{ font: 'inherit', fontSize: 20, padding: 14, borderRadius: 12, border: '2px solid var(--line)', background: 'var(--ink)', color: 'var(--fg)' }} />
    {msg && <div className="err">{msg}</div>}
    <button className="primary" disabled={busy || !pin} onClick={start}><Play size={22} />{busy ? '준비 중…' : '연습 시작'}</button>
  </div>

  return <><SimDriver admin={admin} /><Phone /></>
}

// 자동 진행: 1초마다 상태를 보고 다음 단계로 넘긴다
function SimDriver({ admin }) {
  const [paused, setPaused] = useState(false)
  const [label, setLabel] = useState('준비 중')
  const since = useRef({ key: '', at: 0, drawn: false })
  const pausedRef = useRef(paused); pausedRef.current = paused
  const last = useRef(null)
  const [jumping, setJumping] = useState(false)
  const jumpingRef = useRef(false)
  // 이전/다음 문제로 바로 이동. 마지막 문제 다음은 최종 순위로.
  async function jump(d) {
    const v = last.current; if (!v || jumpingRef.current) return
    jumpingRef.current = true; setJumping(true)
    try {
      const cur = v.phase === 'lobby' ? -1 : v.phase === 'bet' ? v.qi + 1 : ['final', 'draw', 'end'].includes(v.phase) ? v.total_q : v.qi
      const to = cur + d
      if (to < 0) return
      if (to >= v.total_q) { if (v.phase === 'q' || v.phase === 'answer' || v.phase === 'bet') { await admin('goto', { qi: v.total_q - 1 }); await admin('next'); await admin('next') } last.current = await rpc('hq_view', {}); return }
      await admin('goto', { qi: to })
      since.current = { key: '', at: Date.now(), drawn: false }
      // 바로 다시 읽어 둬야 연달아 눌러도 한 칸씩 정확히 움직인다
      const me = (() => { try { return localStorage.getItem(KEY) } catch { return null } })()
      last.current = await rpc('hq_view', { p_player: me })
    } catch { /* noop */ } finally { jumpingRef.current = false; setJumping(false) }
  }
  useEffect(() => {
    let dead = false, running = false
    const t = setInterval(async () => {
      if (dead || running || pausedRef.current) return
      running = true
      try {
        const me = (() => { try { return localStorage.getItem(KEY) } catch { return null } })()
        const v = await rpc('hq_view', { p_player: me })
        last.current = v
        const key = `${v.phase}:${v.qi}`
        if (since.current.key !== key) since.current = { key, at: Date.now(), drawn: false }
        const el = (Date.now() - since.current.at) / 1000
        const go = () => admin('next', { from_phase: v.phase, from_qi: v.qi })
        switch (v.phase) {
          case 'lobby': setLabel('곧 시작'); if (el > 3) await go(); break
          case 'q': {
            const left = v.question.limit_sec - (serverNow() - Date.parse(v.q_started_at)) / 1000
            setLabel(v.me?.answer != null ? '제출 완료 · 곧 정답 공개' : '문제 푸는 중')
            if ((v.me?.answer != null && el > 2) || left < -1) await go()
            break
          }
          case 'answer': setLabel('정답 공개 · 곧 다음 문제'); if (el > 6) await go(); break
          case 'bet': setLabel('베팅을 골라 주세요'); if ((v.me?.bet != null && el > 2) || el > 15) await go(); break
          case 'final': setLabel('최종 순위'); if (el > 7) await go(); break
          case 'draw':
            setLabel('행운상 추첨')
            if (!since.current.drawn && el > 2) { since.current.drawn = true; await admin('draw', { n: 2 }) }
            else if (since.current.drawn && el > 9) await go()
            break
          case 'end': setLabel('연습 끝! 마무리 화면이에요'); break
        }
      } catch { /* 다음 틱에 다시 */ } finally { running = false }
    }, 1000)
    return () => { dead = true; clearInterval(t) }
  }, []) // eslint-disable-line

  return <div className="sim-bar">
    <button onClick={() => jump(-1)} disabled={jumping} aria-label="이전 문제"><ChevronLeft size={18} /></button>
    <span><b>연습 모드</b> · {paused ? '일시정지' : label}</span>
    <button onClick={() => jump(1)} disabled={jumping} aria-label="다음 문제"><ChevronRight size={18} /></button>
    <button onClick={() => setPaused((p) => !p)} aria-label={paused ? '계속' : '일시정지'}>{paused ? <Play size={16} /> : <Pause size={16} />}</button>
    <button onClick={async () => {
      if (!confirm('연습을 끝낼까요? 가상 동료와 연습 기록을 지우고 대기 상태로 돌아가요.')) return
      try { await admin('reset') } catch { /* noop */ }
      try { localStorage.removeItem(KEY) } catch { /* noop */ }
      location.hash = '#/admin'; location.reload()
    }} aria-label="연습 끝내기"><Square size={16} />끝내기</button>
  </div>
}
