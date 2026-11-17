import { useEffect, useState } from 'react'
import { ChevronRight, Dices, Copy, ImagePlus, ListOrdered, Trash2, Lock, RotateCcw, Save, SlidersHorizontal, Upload, Users } from 'lucide-react'
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
    catch (e) { setMsg(`${errText(e.message)} (${e.message})`); throw e } finally { setBusy(false) }
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
    bet: '베팅 마감 · 마지막 문제', q: '정답 공개', final: '행운상 추첨으로', draw: null,
  }[view.phase]
  const phaseKo = { lobby: '입장 대기', bet: '베팅 중', q: '문제 푸는 중', answer: '정답 공개됨', final: '최종 순위', draw: '행운상 추첨' }[view.phase]
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
        {next && <button className="go" disabled={busy} onClick={() => run('next', { from_phase: view.phase, from_qi: view.qi })}>{next}<ChevronRight size={22} /></button>}
        {view.phase === 'draw' && <button className="go" disabled={busy} onClick={() => run('draw')}><Dices size={22} />행운상 뽑기 · {view.drawn}명 뽑음</button>}
        {view.phase === 'draw' && <p className="lead" style={{ fontSize: 14 }}>1~3등을 뺀 나머지에서 뽑아요. 누를 때마다 한 명씩.</p>}
      </div>
      {msg && <div className="err" style={{ marginTop: 12 }}>{msg}</div>}

      <h3>리허설 (가상 참가자)</h3>
      {[20, 50, 100].map((n) => <button key={n} className="ghost" onClick={() => run('bots', { n })}><Users size={15} style={{ verticalAlign: -2 }} /> {n}명 채우기</button>)}

      <h3>참가자 접속 주소 (단톡방에 공유)</h3>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', fontSize: 15, wordBreak: 'break-all' }}>
        <a href={base} target="_blank" rel="noreferrer">{base}</a>
        <button className="ghost" style={{ margin: 0 }} onClick={() => navigator.clipboard?.writeText(base).then(() => setMsg('주소를 복사했어요'))}><Copy size={15} style={{ verticalAlign: -2 }} /> 복사</button>
      </div>

      <h3>다시 하기</h3>
      <div style={{ display: 'grid', gap: 10 }}>
        <div>
          <button className="ghost" disabled={busy} onClick={() => confirm('새 게임을 시작할까요?\n모든 참가자가 입장 화면으로 돌아가 닉네임부터 다시 입력해요.') && run('reset')}>
            <RotateCcw size={15} style={{ verticalAlign: -2 }} /> 새 게임 (닉네임부터 다시)</button>
          <p className="lead" style={{ fontSize: 13, margin: '2px 0 0' }}>리허설 끝나고 실전 시작할 때. 행사가 끝난 뒤 누르면 참가자 기록도 지워져요.</p>
        </div>
        <div>
          <button className="ghost" disabled={busy} onClick={() => confirm('한 판 더 할까요?\n닉네임은 그대로, 점수만 0점이 돼요. (가상 참가자는 빠져요)') && run('restart')}>
            <RotateCcw size={15} style={{ verticalAlign: -2 }} /> 한 판 더 (닉네임 유지)</button>
          <p className="lead" style={{ fontSize: 13, margin: '2px 0 0' }}>같은 사람들끼리 바로 한 번 더 할 때.</p>
        </div>
      </div>
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
      <p className="lead" style={{ fontSize: 13 }}>type: ox (answer 0=O, 1=X) · mc (opts 4개, answer 0~3) · poll (opts, answer 없음 = 정답 없는 투표) · is_bet: true면 그 문제 직전에 베팅</p>
      <textarea value={qText} onChange={(e) => setQText(e.target.value)} placeholder="[불러오기]를 누르세요" />

      <ImageUpload admin={admin} total={view.total_q} setMsg={setMsg} />
    </section>
  </div>
}

// 문제 사진 올리기: 폰에서 고른 사진을 긴 변 900px JPEG 로 줄여 DB 에 넣는다(별도 저장소 설정 불필요).
function ImageUpload({ admin, total, setMsg }) {
  const [idx, setIdx] = useState(0)
  const [has, setHas] = useState([])
  const [busy, setBusy] = useState(false)
  const refresh = () => admin('images_list').then(setHas).catch(() => {})
  useEffect(() => { refresh() }, []) // eslint-disable-line

  async function pick(file) {
    if (!file) return
    setBusy(true)
    try {
      const bmp = await createImageBitmap(file)
      const k = Math.min(1, 900 / Math.max(bmp.width, bmp.height))
      const c = document.createElement('canvas')
      c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k)
      c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height)
      const data = c.toDataURL('image/jpeg', 0.78)
      await admin('image', { idx, data })
      setMsg(`${idx + 1}번 문제에 사진을 붙였어요`)
      refresh()
    } catch { /* admin() 이 메시지를 띄운다 */ } finally { setBusy(false) }
  }

  return <>
    <h3>문제 사진 (어린 시절 사진, 반려동물, 손 사진 등)</h3>
    <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
      <select value={idx} onChange={(e) => setIdx(+e.target.value)} className="ghost" style={{ color: 'var(--fg)', border: 0, font: 'inherit' }}>
        {Array.from({ length: total }, (_, i) => <option key={i} value={i}>{i + 1}번 문제{has.includes(i) ? ' (사진 있음)' : ''}</option>)}
      </select>
      <label className="ghost" style={{ cursor: 'pointer' }}><ImagePlus size={15} style={{ verticalAlign: -2 }} /> {busy ? '올리는 중…' : '사진 고르기'}
        <input type="file" accept="image/*" hidden disabled={busy} onChange={(e) => { pick(e.target.files?.[0]); e.target.value = '' }} /></label>
      {has.includes(idx) && <button className="ghost" onClick={() => admin('image', { idx }).then(refresh).catch(() => {})}><Trash2 size={15} style={{ verticalAlign: -2 }} /> 사진 빼기</button>}
    </div>
    <p className="lead" style={{ fontSize: 13 }}>사진은 그 문제가 열릴 때만 참가자 폰에 보여요. 문항 순서를 바꾸면 사진도 다시 붙여 주세요.</p>
  </>
}
