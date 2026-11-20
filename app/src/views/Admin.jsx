import { useEffect, useState } from 'react'
import QRCode from 'qrcode'
import { ChevronRight, Dices, Copy, ListOrdered, Mic, Eye, Lock, RotateCcw, Save, SlidersHorizontal, Users, QrCode, Undo2, KeyRound, PencilLine, AlertTriangle, X as Close } from 'lucide-react'
import QuestionEditor from './QuestionEditor'
import { rpc } from '../lib/supabase'
import { useCountdown, useView } from '../lib/useView'
import { errText, fmt, options, trap, REACT_EMOJI } from '../lib/ui'

// 진행자 노트북용. 권한은 서버(hq_admin)가 PIN으로 매번 검증한다. URL이 새도 조작 불가.
export default function Admin() {
  const [pin, setPin] = useState(() => sessionStorage.getItem('hq-pin') ?? '')
  const [ok, setOk] = useState(false)
  const [msg, setMsg] = useState(null)
  const [busy, setBusy] = useState(false)
  const { view, refetch } = useView(null, 2000)
  const [qr, setQr] = useState(false)
  const [images, setImages] = useState([])
  const refreshImages = () => admin('images_list').then(setImages).catch(() => {})
  useEffect(() => { if (ok) refreshImages() }, [ok]) // eslint-disable-line

  // 문제 사진: 고른 사진을 긴 변 900px JPEG 로 줄여 DB 에 넣는다(별도 저장소 설정 불필요). file 이 없으면 삭제.
  async function onImage(idx, file) {
    try {
      if (!file) { await admin('image', { idx }); setMsg(`${idx + 1}번 사진을 뺐어요`) }
      else {
        const bmp = await createImageBitmap(file)
        const k = Math.min(1, 900 / Math.max(bmp.width, bmp.height))
        const c = document.createElement('canvas')
        c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k)
        c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height)
        await admin('image', { idx, data: c.toDataURL('image/jpeg', 0.78) })
        setMsg(`${idx + 1}번 문제에 사진을 붙였어요`)
      }
      refreshImages()
    } catch { /* admin() 이 메시지를 띄운다 */ }
  }

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
    bet: '베팅 마감 · 마지막 문제', q: '정답 공개', final: '행운상 추첨으로', draw: '마무리 화면으로', end: null,
  }[view.phase]
  const phaseKo = { lobby: '입장 대기', bet: '베팅 중', q: '문제 푸는 중', answer: '정답 공개됨', final: '최종 순위', draw: '행운상 추첨', end: '마무리' }[view.phase]
  const base = location.href.split('#')[0]

  return <div className="admin">
    <StickyBar view={view} next={next} phaseKo={phaseKo} busy={busy} run={run} />
    <section className="panel">
      <h2><SlidersHorizontal size={20} />진행</h2>
      <div className="kv">
        <span>단계<b>{phaseKo}</b></span>
        <span>문제<b className="num">{Math.max(view.qi + 1, 0)} / {view.total_q}</b></span>
        <span>참가<b className="num">{view.players}명</b></span>
        {view.phase === 'q' && <span>제출<b className="num">{view.submitted} / {view.players}명</b></span>}
      </div>
      <HostCard view={view} admin={admin} />
      <div style={{ marginTop: 16 }}>
        {next && view.phase !== 'draw' && <button className="go" disabled={busy} onClick={() => run('next', { from_phase: view.phase, from_qi: view.qi })}>{next}<ChevronRight size={22} /></button>}
        {view.phase === 'draw' && <DrawControl view={view} run={run} busy={busy} />}
        {view.phase === 'end' && <EndControl view={view} run={run} busy={busy} />}
      </div>
      {view.phase !== 'lobby' && <button className="undo" disabled={busy} onClick={() => {
        const what = { q: '문제 열기를 취소할까요? 이 문제에 낸 답은 지워져요.', answer: '정답 공개를 취소할까요? 점수가 공개 전으로 돌아가요.', bet: '베팅 단계를 취소할까요?', final: '최종 순위를 닫고 정답 공개 화면으로 돌아갈까요?', draw: '추첨 화면을 닫을까요? (이미 뽑힌 사람은 그대로예요)', end: '마무리 화면을 닫고 추첨으로 돌아갈까요?' }[view.phase]
        if (confirm(what)) run('back', { from_phase: view.phase, from_qi: view.qi })
      }}><Undo2 size={15} />잘못 눌렀어요, 한 단계 되돌리기</button>}
      {msg && <div className="err" style={{ marginTop: 12 }}>{msg}</div>}

      <h3>리허설 (가상 참가자)</h3>
      {[20, 50, 100].map((n) => <button key={n} className="ghost" onClick={() => run('bots', { n })}><Users size={15} style={{ verticalAlign: -2 }} /> {n}명 채우기</button>)}

      <h3>참가자 접속 (단톡방 링크 또는 QR)</h3>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', fontSize: 15, wordBreak: 'break-all', flexWrap: 'wrap' }}>
        <a href={base} target="_blank" rel="noreferrer">{base}</a>
        <button className="ghost" style={{ margin: 0 }} onClick={() => navigator.clipboard?.writeText(base).then(() => setMsg('주소를 복사했어요'))}><Copy size={15} style={{ verticalAlign: -2 }} /> 복사</button>
        <button className="ghost" style={{ margin: 0 }} onClick={() => setQr(true)}><QrCode size={15} style={{ verticalAlign: -2 }} /> QR 크게 보기</button>
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

      <PinChange admin={admin} busy={busy} onChanged={(p) => { setPin(p); sessionStorage.setItem('hq-pin', p) }} />
    </section>

    <section className="panel">
      <h2><ListOrdered size={20} />개인 순위 TOP 10</h2>
      {view.ranking.length ? view.ranking.map((p) => (
        <div key={p.name} className="mini num"><b>{p.rank}</b><span>{p.name}</span><span>{fmt(p.score)}</span></div>
      )) : <p className="lead">아직 점수가 없어요</p>}

      <h2 style={{ marginTop: 28 }}><PencilLine size={20} />문항 편집</h2>
      <QuestionEditor admin={admin} phase={view.phase} setMsg={setMsg} images={images} onImage={onImage} />
    </section>
    {qr && <QrOverlay url={base} onClose={() => setQr(false)} />}
  </div>
}

// 화면 위에 늘 붙어 있는 진행 막대: 단계, 남은 시간, 제출 현황, 다음 버튼. 스크롤을 내려도 보인다.
function StickyBar({ view, next, phaseKo, busy, run }) {
  const q = view.question
  const left = useCountdown(view.phase === 'q' ? view.q_started_at : null, q?.limit_sec ?? 15)
  const isQ = view.phase === 'q' && q
  const all = view.players > 0 && view.submitted >= view.players
  return <div className="admin-sticky">
    <div className="ph">{phaseKo}<small className="num">{Math.max(view.qi + 1, 0)} / {view.total_q} · {view.players}명</small></div>
    {isQ && <>
      <b className={`sec num ${left <= 5 ? 'hurry' : ''}`}>{Math.ceil(left)}<small style={{ fontSize: 14 }}>초</small></b>
      <div className="sbar">
        <div className="track"><i style={{ width: `${(left / q.limit_sec) * 100}%`, background: left <= 5 ? 'var(--x)' : undefined }} /></div>
        <span className="num">{left <= 0 ? '시간 끝! 정답 공개를 눌러 주세요' : all ? `전원 제출 (${view.submitted}명) · 바로 공개해도 돼요` : `제출 ${view.submitted} / ${view.players}명`}</span>
      </div>
    </>}
    {next && view.phase !== 'draw' && <button className="go" disabled={busy} onClick={() => run('next', { from_phase: view.phase, from_qi: view.qi })}>{next}<ChevronRight size={20} /></button>}
  </div>
}

// 진행자 카드: 지금 단계에서 읽을 멘트 + 정답(참가자보다 먼저) + 다음 문제 미리보기
function HostCard({ view, admin }) {
  const [cur, setCur] = useState(null)
  useEffect(() => { admin('current').then(setCur).catch(() => {}) }, [view.phase, view.qi]) // eslint-disable-line
  const q = view.question
  const label = (qq, a) => (a == null ? '정답 없음 (투표)' : options(qq)[a]?.[0])
  const top = view.ranking
  const nx = cur?.next
  const correct = q && view.dist && q.answer != null ? view.dist[q.answer] : null

  let say
  switch (view.phase) {
    case 'lobby':
      say = `단톡방 링크로 들어와서 닉네임만 쓰면 입장입니다! 지금 ${view.players}명 들어왔어요. 빨리 맞힐수록 점수가 높고, 3연속 맞히면 보너스, 찬스 카드는 한 게임에 딱 한 장입니다. 그럼 시작합니다!`
      break
    case 'q':
      say = cur?.now?.host || `${q.idx + 1}번 문제! ${q.limit_sec}초 드립니다. 빨리 누를수록 점수가 높아요!`
      break
    case 'answer':
      say = q.type === 'poll'
        ? `투표 결과 나왔습니다! 1등은 '${options(q)[view.dist.indexOf(Math.max(...view.dist))][0]}'! ${q.note || ''}`
        : `정답은 '${label(q, q.answer)}'! ${correct}명이 맞혔습니다. ${trapText(q, view.dist)}${q.note || ''} 지금 1등은 ${top[0]?.name ?? '-'}님!`
      break
    case 'bet':
      say = '마지막 문제 전에 베팅 시간입니다! 지금 내 점수를 0%, 50%, 100% 중에 걸 수 있어요. 맞히면 건 만큼 더 받고, 틀리면 건 만큼 잃습니다. 하위권은 올인하면 역전도 가능합니다!'
      break
    case 'final':
      say = `최종 결과! 1등 ${top[0]?.name ?? '-'}님, 2등 ${top[1]?.name ?? '-'}님, 3등 ${top[2]?.name ?? '-'}님! 상품 받으러 나와 주세요. 아직 안 끝났습니다, 4등부터는 행운상 추첨이 남았어요!`
      break
    case 'draw':
      say = '4등부터 꼴찌까지 모두 대상입니다. 폰 화면 보세요, 두근두근!'
      break
    case 'end':
      say = `오늘 ${view.players}명 모두 수고 많으셨습니다! 폰에 각자 오늘 기록이 떠 있으니 캡처해서 단톡방에 올려 주세요. 다 같이 건배하고 마무리하겠습니다. 건배!`
      break
  }

  return <div className="host">
    <div className="host-say"><Mic size={18} /><p>{say}</p></div>
    {view.phase === 'answer' && view.reactions && <div className="host-ans">반응 {['clap', 'lol', 'beer', 'fire'].map((k) => `${REACT_EMOJI[k]} ${view.reactions[k] ?? 0}`).join('  ')}</div>}
    {nx && nx.reveal && !nx.has_image && ['lobby', 'answer', 'bet'].includes(view.phase) &&
      <div className="warn"><AlertTriangle size={16} />다음 {nx.idx + 1}번은 사진 문제인데 사진이 없어요. 문항 편집에서 붙이거나 건너뛰세요.</div>}
    {q && view.phase === 'q' && cur?.now && <div className="host-ans"><Eye size={16} />
      정답 <b>{label(q, cur.now.answer)}</b>{cur.now.note && <span> · {cur.now.note}</span>}</div>}
    {nx && ['lobby', 'answer', 'bet'].includes(view.phase) && <div className="host-next">
      <small>다음 {nx.idx + 1}번{nx.is_bet ? ' (베팅 문제)' : ''}</small>
      <p>{nx.q}</p>
      <span><Eye size={14} /> 정답 {label(nx, nx.answer)}</span>
    </div>}
  </div>
}

// 행운상: 몇 명 뽑을지 고르고 한 번에 뽑는다. 여러 번 눌러도 이미 뽑힌 사람은 빠진다.
function DrawControl({ view, run, busy }) {
  const [n, setN] = useState(1)
  return <div className="draw-ctl">
    <div className="stepper">
      <button type="button" onClick={() => setN((v) => Math.max(1, v - 1))} aria-label="줄이기">−</button>
      <b className="num">{n}명</b>
      <button type="button" onClick={() => setN((v) => Math.min(20, v + 1))} aria-label="늘리기">+</button>
    </div>
    <button className="go" disabled={busy} onClick={() => run('draw', { n })}><Dices size={22} />{n}명 뽑기</button>
    <p className="lead" style={{ fontSize: 14, width: '100%' }}>1~3등과 이미 뽑힌 사람은 빼고 뽑아요. 지금까지 {view.drawn}명 당첨.
      {(view.winners ?? []).length > 0 && <> 방금: <b style={{ color: 'var(--fg)' }}>{view.winners.map((w) => w.name).join(', ')}</b></>}</p>
    <button className="go" style={{ background: 'var(--ink-3)', color: 'var(--fg)' }} disabled={busy}
      onClick={() => run('next', { from_phase: 'draw', from_qi: view.qi })}>마무리 화면으로<ChevronRight size={22} /></button>
  </div>
}

// 마무리 화면의 인사말은 진행자가 바꿀 수 있다.
function EndControl({ view, run, busy }) {
  const [msg, setMsgText] = useState(view.end_msg ?? '')
  return <div style={{ display: 'grid', gap: 8 }}>
    <p className="lead" style={{ margin: 0 }}>참가자 폰에 마무리 화면(수상자 + 개인 기록)이 떠 있어요.</p>
    <label style={{ fontSize: 14, color: 'var(--mute)' }}>마무리 인사말</label>
    <input value={msg} maxLength={120} onChange={(e) => setMsgText(e.target.value)} style={{ margin: 0 }} />
    <button className="ghost" disabled={busy} onClick={() => run('end_msg', { msg })}><Save size={15} style={{ verticalAlign: -2 }} /> 인사말 바꾸기</button>
  </div>
}

const trapText = (q, dist) => { const t = trap(q, dist); return t ? `'${t.label}'에 ${t.n}명이 속았네요! ` : '' }

function QrOverlay({ url, onClose }) {
  const [src, setSrc] = useState(null)
  useEffect(() => { QRCode.toDataURL(url, { width: 720, margin: 1 }).then(setSrc) }, [url])
  return <div className="qr-overlay" onClick={onClose} role="dialog" aria-label="입장 QR">
    <div className="qr-box" onClick={(e) => e.stopPropagation()}>
      <button className="qr-close" onClick={onClose} aria-label="닫기"><Close size={22} /></button>
      <h2>폰 카메라로 찍고 입장!</h2>
      {src && <img src={src} alt="입장 QR 코드" />}
      <p>{url}</p>
    </div>
  </div>
}

function PinChange({ admin, busy, onChanged }) {
  const [open, setOpen] = useState(false)
  const [a, setA] = useState(''), [b, setB] = useState('')
  const [err, setErr] = useState(null)
  if (!open) return <><h3>보안</h3><button className="ghost" onClick={() => setOpen(true)}><KeyRound size={15} style={{ verticalAlign: -2 }} /> 진행자 PIN 바꾸기</button></>
  return <>
    <h3>진행자 PIN 바꾸기</h3>
    <input type="password" inputMode="numeric" placeholder="새 PIN (4~12자리)" value={a} onChange={(e) => setA(e.target.value)} />
    <input type="password" inputMode="numeric" placeholder="새 PIN 한 번 더" value={b} onChange={(e) => setB(e.target.value)} />
    {err && <div className="err" style={{ marginBottom: 8 }}>{err}</div>}
    <button className="ghost" disabled={busy} onClick={async () => {
      if (a.length < 4 || a.length > 12) return setErr('4~12자리로 정해 주세요')
      if (a !== b) return setErr('두 번 입력한 PIN이 달라요')
      setErr(null)
      try { await admin('set_pin', { pin: a }); onChanged(a); setOpen(false); setA(''); setB('') } catch { /* admin() 이 메시지를 띄운다 */ }
    }}><Save size={15} style={{ verticalAlign: -2 }} /> 저장</button>
    <button className="ghost" onClick={() => setOpen(false)}>취소</button>
  </>
}
