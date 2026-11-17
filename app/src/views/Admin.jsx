import { useState } from 'react'
import { rpc } from '../lib/supabase'
import { useView } from '../lib/useView'
import { errText } from '../lib/ui'

// 진행자 노트북용. 권한은 서버(hq_admin)가 PIN 으로 매번 검증한다 — 이 화면 URL 이 새도 조작 불가.
export default function Admin() {
  const [pin, setPin] = useState(() => sessionStorage.getItem('hq-pin') ?? '')
  const [ok, setOk] = useState(false)
  const [msg, setMsg] = useState(null)
  const [busy, setBusy] = useState(false)
  const { view, refetch } = useView(null, 2000)
  const [qText, setQText] = useState('')

  async function admin(action, arg = {}) {
    setBusy(true); setMsg(null)
    try { const r = await rpc('hq_admin', { p_pin: pin, p_action: action, p_arg: arg }); await refetch(); return r }
    catch (e) { setMsg(errText(e.message)); throw e } finally { setBusy(false) }
  }

  if (!ok) return <div className="admin" style={{ gridTemplateColumns: '1fr', maxWidth: 420 }}><div className="card">
    <h2>🎛 진행자 로그인</h2>
    <input type="password" inputMode="numeric" placeholder="PIN" value={pin} onChange={(e) => setPin(e.target.value)} />
    <button className="go" disabled={busy} onClick={() => admin('check').then(() => { sessionStorage.setItem('hq-pin', pin); setOk(true) }).catch(() => {})}>들어가기</button>
    {msg && <div className="err">{msg}</div>}
  </div></div>

  if (!view) return <div className="admin">불러오는 중…</div>
  const nextLabel = {
    lobby: view.next_is_bet ? '▶ R3 베팅 열기' : '▶ 문제 1 열기',
    answer: view.qi + 1 >= view.total_q ? '▶ 최종 순위' : view.next_is_bet ? '▶ R3 베팅 열기' : `▶ 문제 ${view.qi + 2} 열기`,
    bet: '▶ 베팅 마감 → 마지막 문제', q: '▶ 정답 공개', final: '▶ 추첨 화면으로', draw: null,
  }[view.phase]
  const q = view.question

  return <div className="admin">
    <div className="card">
      <h2>🎛 진행</h2>
      <div>단계 <b>{view.phase}</b> · 문제 {view.qi + 1}/{view.total_q} · 참가 <b>{view.players}</b>명
        {view.phase === 'q' && <> · 제출 <b>{view.submitted}</b>명</>}</div>
      {q && <div className="mute" style={{ marginTop: 6 }}>현재: {q.q}</div>}
      <div style={{ marginTop: 10 }}>
        {nextLabel && <button className="go" style={{ fontSize: 20, padding: '16px 22px' }} disabled={busy} onClick={() => admin('next')}>{nextLabel}</button>}
        {view.phase === 'draw' && <button className="go" style={{ fontSize: 20, padding: '16px 22px' }} disabled={busy}
          onClick={() => admin('draw').catch(() => {})}>🎲 추첨 돌리기 ({view.drawn}명 뽑음)</button>}
      </div>
      {msg && <div className="err" style={{ marginTop: 8 }}>{msg}</div>}

      <h3>테이블 수 (입장 전에 정하기)</h3>
      {[3, 4, 5, 6, 8, 10, 12].map((n) => <button key={n} className={view.tables === n ? 'go' : ''} onClick={() => admin('tables', { n })}>{n}</button>)}

      <h3>리허설 (가상 참가자)</h3>
      {[20, 50, 100].map((n) => <button key={n} onClick={() => admin('bots', { n })}>{n}명 채우기</button>)}

      <h3>화면 링크</h3>
      <div className="mute" style={{ fontSize: 14, wordBreak: 'break-all' }}>
        참가자: {location.href.split('#')[0]}<br />스크린: <a style={{ color: 'var(--acc)' }} href="#/screen" target="_blank">{location.href.split('#')[0]}#/screen</a>
      </div>

      <h3>위험 구역</h3>
      <button style={{ background: 'var(--x)' }} disabled={busy}
        onClick={() => confirm('참가자·답안·점수를 전부 지울까요? (문항은 유지)') && admin('reset').catch(() => {})}>전체 초기화 / 개인정보 삭제</button>
    </div>

    <div className="card">
      <h2>📊 테이블 순위</h2>
      {view.teams.length ? view.teams.map((t, i) => <div key={t.table_no}>{i + 1}. {t.table_no}번 ({t.n}명) — {t.avg.toLocaleString()}점</div>) : <div className="mute">아직 없음</div>}
      <h3>개인 TOP 5</h3>
      {view.top.map((p, i) => <div key={i}>{i + 1}. {p.name} ({p.table_no}번) — {p.score.toLocaleString()}</div>)}

      <h3>문항 편집 (대기 단계에서만)</h3>
      <button onClick={() => admin('questions_get').then((r) => setQText(JSON.stringify(r.map(({ idx, ...x }) => x), null, 1)))}>불러오기</button>
      <button className="go" disabled={busy || !qText} onClick={() => {
        let list; try { list = JSON.parse(qText) } catch { return setMsg('JSON 형식이 잘못됐어요') }
        admin('questions', { list }).then(() => setMsg(null)).catch(() => {})
      }}>저장</button>
      <div className="mute" style={{ fontSize: 13, margin: '6px 0' }}>type: ox(answer 0=O,1=X) / mc(opts 4개, answer 0~3) · is_bet: true 면 직전에 베팅 단계</div>
      <textarea value={qText} onChange={(e) => setQText(e.target.value)} placeholder="[불러오기]를 누르세요" />
    </div>
  </div>
}
