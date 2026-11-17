import { useState } from 'react'
import { ChevronRight, Dices, ExternalLink, ListOrdered, Lock, RotateCcw, Save, Trash2, SlidersHorizontal, Upload, Users } from 'lucide-react'
import { rpc } from '../lib/supabase'
import { useView } from '../lib/useView'
import { errText, fmt } from '../lib/ui'

// 진행자 노트북용. 권한은 서버(hq_admin)가 PIN으로 매번 검증한다. URL이 새도 조작 불가.
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
  const run = (action, arg) => admin(action, arg).catch(() => {})

  if (!ok) return <div className="admin" style={{ gridTemplateColumns: '1fr', maxWidth: 440 }}>
    <form className="panel" onSubmit={(e) => { e.preventDefault(); admin('check').then(() => { sessionStorage.setItem('hq-pin', pin); setOk(true) }).catch(() => {}) }}>
      <h2><Lock size={20} />진행자 로그인</h2>
      <input type="password" inputMode="numeric" autoFocus placeholder="PIN" value={pin} onChange={(e) => setPin(e.target.value)} />
      <button className="go" disabled={busy}>들어가기<ChevronRight size={20} /></button>
      {msg && <div className="err" style={{ marginTop: 12 }}>{msg}</div>}
    </form>
  </div>

  if (!view) return <div className="admin">불러오는 중…</div>
  const last = view.qi + 1 >= view.total_q
  const next = {
    lobby: view.next_is_bet ? '베팅 열기' : '1번 문제 열기',
    answer: last ? '최종 순위 공개' : view.next_is_bet ? '마지막 베팅 열기' : `${view.qi + 2}번 문제 열기`,
    bet: '베팅 마감 · 마지막 문제', q: '정답 공개', final: '추첨 화면으로', draw: null,
  }[view.phase]
  const phaseKo = { lobby: '입장 대기', bet: '베팅 중', q: '문제 푸는 중', answer: '정답 공개됨', final: '최종 순위', draw: '추첨' }[view.phase]
  const base = location.href.split('#')[0]

  return <div className="admin">
    <section className="panel">
      <h2><SlidersHorizontal size={20} />진행</h2>
      <div className="kv">
        <span>단계<b>{phaseKo}</b></span>
        <span>문제<b className="num">{Math.max(view.qi + 1, 0)} / {view.total_q}</b></span>
        <span>참가<b className="num">{view.players}명</b></span>
        {view.phase === 'q' && <span>제출<b className="num">{view.submitted}명</b></span>}
      </div>
      {view.question && <p className="lead" style={{ margin: '12px 0 0' }}>{view.question.q}</p>}
      <div style={{ marginTop: 16 }}>
        {next && <button className="go" disabled={busy} onClick={() => run('next')}>{next}<ChevronRight size={22} /></button>}
        {view.phase === 'draw' && <button className="go" disabled={busy} onClick={() => run('draw')}><Dices size={22} />추첨 돌리기 · {view.drawn}명 뽑음</button>}
      </div>
      {msg && <div className="err" style={{ marginTop: 12 }}>{msg}</div>}

      <h3>리허설 (가상 참가자)</h3>
      {[20, 50, 100].map((n) => <button key={n} className="ghost" onClick={() => run('bots', { n })}><Users size={15} style={{ verticalAlign: -2 }} /> {n}명 채우기</button>)}

      <h3>화면 링크</h3>
      <div style={{ display: 'grid', gap: 6, fontSize: 15, wordBreak: 'break-all' }}>
        <span>참가자 <a href={base} target="_blank" rel="noreferrer">{base}</a></span>
        <span>스크린 <a href={`${base}#/screen`} target="_blank" rel="noreferrer">{base}#/screen <ExternalLink size={13} /></a></span>
      </div>

      <h3>다시 하기</h3>
      <button className="ghost" disabled={busy} onClick={() => confirm('게임을 처음부터 다시 할까요?\n참가자는 그대로 남고 점수만 0점이 됩니다. (가상 참가자는 빠져요)') && run('restart')}>
        <RotateCcw size={15} style={{ verticalAlign: -2 }} /> 처음부터 다시 (참가자 유지)</button>
      <p className="lead" style={{ fontSize: 13, margin: '4px 0 0' }}>리허설 끝나고 실전 시작할 때, 게임을 한 판 더 할 때 누르세요.</p>

      <details style={{ marginTop: 18 }}>
        <summary style={{ cursor: 'pointer', color: 'var(--mute)', fontSize: 14 }}>행사 종료 후: 개인정보 삭제</summary>
        <p className="lead" style={{ fontSize: 13 }}>참가자 닉네임·점수를 모두 지웁니다. 접속 중인 모든 폰이 입장 화면으로 돌아가요.</p>
        <button className="danger" disabled={busy} onClick={() => prompt('정말 지우려면 "삭제"라고 입력하세요') === '삭제' && run('reset')}>
          <Trash2 size={15} style={{ verticalAlign: -2 }} /> 참가자 전체 삭제</button>
      </details>
    </section>

    <section className="panel">
      <h2><ListOrdered size={20} />개인 순위 TOP 10</h2>
      {view.ranking.length ? view.ranking.map((p) => (
        <div key={p.name} className="mini num"><b>{p.rank}</b><span>{p.name}</span><span>{fmt(p.score)}</span></div>
      )) : <p className="lead">아직 점수가 없어요</p>}

      <h3>문항 편집 (입장 대기 단계에서만)</h3>
      <button className="ghost" onClick={() => admin('questions_get').then((r) => setQText(JSON.stringify(r.map(({ idx, ...x }) => x), null, 1))).catch(() => {})}><Upload size={15} style={{ verticalAlign: -2 }} /> 불러오기</button>
      <button className="ghost" disabled={busy || !qText} onClick={() => {
        let list; try { list = JSON.parse(qText) } catch { return setMsg('JSON 형식이 잘못됐어요') }
        run('questions', { list })
      }}><Save size={15} style={{ verticalAlign: -2 }} /> 저장</button>
      <p className="lead" style={{ fontSize: 13 }}>type: ox (answer 0=O, 1=X) / mc (opts 4개, answer 0~3) · is_bet: true면 그 문제 직전에 베팅</p>
      <textarea value={qText} onChange={(e) => setQText(e.target.value)} placeholder="[불러오기]를 누르세요" />
    </section>
  </div>
}
