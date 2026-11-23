import { useEffect, useRef, useState } from 'react'
import QRCode from 'qrcode'
import { ChevronLeft, ChevronRight, Dices, Copy, ListOrdered, Mic, Eye, Lock, RotateCcw, Save, SlidersHorizontal, Users, QrCode, Undo2, KeyRound, PencilLine, AlertTriangle, Shuffle, ClipboardCheck, PlayCircle, Square, CheckCircle2, Smartphone, RotateCw, Radio, ListChecks, Settings, SkipForward, XCircle, Music, Plus, Library, X as Close } from 'lucide-react'
import QuestionEditor from './QuestionEditor'
import { QImage, useWakeLock } from './Phone'
import { makeClip } from '../lib/audioclip'
import YTPlayer, { withStart } from '../lib/ytplayer'
import { rpc } from '../lib/supabase'
import { useCountdown, useView } from '../lib/useView'
import { errText, fmt, options, trap, REACT_EMOJI, parseYouTube } from '../lib/ui'

const savePin = (p) => { try { localStorage.setItem('hq-pin', p) } catch { /* noop */ } }

// 진행자 노트북용. 권한은 서버(hq_admin)가 PIN으로 매번 검증한다. URL이 새도 조작 불가.
export default function Admin() {
  const [pin, setPin] = useState(() => { try { return localStorage.getItem('hq-pin') ?? sessionStorage.getItem('hq-pin') ?? '' } catch { return '' } })
  const [ok, setOk] = useState(false)
  const [msg, setMsg] = useState(null)
  const [busy, setBusy] = useState(false)
  const { view, refetch } = useView(null, 2000)
  useWakeLock()
  const [qr, setQr] = useState(false)
  const [editorKey, setEditorKey] = useState(0)
  const [preview, setPreview] = useState(null)
  const [tab, setTabState] = useState(() => { try { return sessionStorage.getItem('hq-tab') ?? 'live' } catch { return 'live' } })
  const setTab = (t) => { setTabState(t); try { sessionStorage.setItem('hq-tab', t) } catch { /* noop */ } window.scrollTo(0, 0) }
  const [questions, setQuestions] = useState([])
  const refreshQuestions = () => admin('questions_get').then((r) => setQuestions(r)).catch(() => {})
  const [images, setImages] = useState([])
  const refreshImages = () => admin('images_list').then(setImages).catch(() => {})
  const [audios, setAudios] = useState([])
  const refreshAudios = () => admin('audio_list').then(setAudios).catch(() => {})
  // 노래 음원 붙이기: 내 폰의 음원 파일에서 start 초부터 20초만 잘라 올린다(진행자만 꺼낼 수 있음)
  async function onAudio(idx, file, start) {
    try {
      if (!file) { await admin('audio', { idx }); setMsg(`${idx + 1}번 음원을 뺐어요`) }
      else {
        setMsg('음원 자르는 중… (몇 초 걸려요)')
        const clip = await makeClip(file, start)
        await admin('audio', { idx, data: clip.data })
        setMsg(`${idx + 1}번에 음원 ${clip.seconds}초를 붙였어요`)
      }
      refreshAudios(); refreshQuestions()
    } catch (e) { if (!String(e?.message).match(/[A-Z_]{4,}/)) setMsg('이 파일은 읽을 수 없어요. mp3·m4a 같은 음악 파일을 골라 주세요') }
  }
  useEffect(() => { if (ok) { refreshImages(); refreshQuestions(); refreshAudios() } }, [ok]) // eslint-disable-line

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
    <form className="panel" onSubmit={(e) => { e.preventDefault(); admin('check').then(() => { savePin(pin); setOk(true) }).catch(() => {}) }}>
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

  const undo = () => {
    const what = { q: '문제 열기를 취소할까요? 이 문제에 낸 답은 지워져요.', answer: '정답 공개를 취소할까요? 점수가 공개 전으로 돌아가요.', bet: '베팅 단계를 취소할까요?', final: '최종 순위를 닫고 정답 공개 화면으로 돌아갈까요?', draw: '추첨 화면을 닫을까요? (이미 뽑힌 사람은 그대로예요)', end: '마무리 화면을 닫고 추첨으로 돌아갈까요?' }[view.phase]
    if (confirm(what)) run('back', { from_phase: view.phase, from_qi: view.qi })
  }
  const openPreview = (list, idx, extra = {}) => setPreview({ list, idx, ...extra })

  // iOS 앱처럼 하단 탭 3개: 진행(지금 할 일만) / 문제 / 설정
  return <div className="host-app">
    {tab !== 'live' && view.phase !== 'lobby' && <MiniBar view={view} next={next} phaseKo={phaseKo} busy={busy} run={run} onOpen={() => setTab('live')} />}

    {tab === 'live' && <main className="tab-page">
      <header className="large-title"><small className="num">{view.phase === 'lobby' ? `참가 ${view.players}명` : `${Math.max(view.qi + 1, 0)} / ${view.total_q}번 · 참가 ${view.players}명`}</small><h1>{phaseKo}</h1></header>
      {['q', 'answer'].includes(view.phase) && view.question && <p className="live-q">{view.question.q}</p>}
      {view.phase === 'q' && view.question && <LiveTimer view={view} />}
      <HostCard view={view} admin={admin} audios={audios} onPreview={(q, idx) => openPreview(questions, idx)} />
      <LiveSong view={view} questions={questions} audios={audios} admin={admin} onSaved={refreshQuestions} />
      {msg && <div className="err">{msg}</div>}
      <div className="live-actions">
        {next && view.phase !== 'draw' && <button className="go big" disabled={busy} onClick={() => run('next', { from_phase: view.phase, from_qi: view.qi })}>{next}<ChevronRight size={22} /></button>}
        {view.phase === 'draw' && <DrawControl view={view} run={run} busy={busy} />}
        {view.phase === 'end' && <EndControl view={view} run={run} busy={busy} />}
      </div>
      {view.phase === 'lobby' && <div className="group">
        <button className="row-btn" onClick={() => setQr(true)}><QrCode size={20} /><span>입장 QR 크게 보기</span><ChevronRight size={18} /></button>
        <button className="row-btn" onClick={() => navigator.clipboard?.writeText(base).then(() => setMsg('주소를 복사했어요'))}><Copy size={20} /><span>참가 링크 복사 (단톡방용)</span><ChevronRight size={18} /></button>
      </div>}
      {view.phase === 'q' && <div className="group">
        <button className="row-btn" disabled={busy} onClick={() => confirm('이 문제를 건너뛸까요?\n낸 답은 지워지고, 점수 없이 바로 다음으로 넘어가요.') && run('skip', { from_phase: 'q', from_qi: view.qi })}>
          <SkipForward size={20} /><span>이 문제 건너뛰기<small>점수 없이 바로 다음 문제로</small></span><ChevronRight size={18} /></button>
        <button className="row-btn" disabled={busy} onClick={() => confirm('이 문제를 취소할까요?\n낸 답은 지워지고, 문제를 열기 전으로 돌아가요. (다시 열 수 있어요)') && run('back', { from_phase: 'q', from_qi: view.qi })}>
          <XCircle size={20} /><span>이 문제 취소<small>열기 전으로 돌아가기 · 다시 열 수 있어요</small></span><ChevronRight size={18} /></button>
      </div>}
      {view.phase !== 'lobby' && view.phase !== 'q' && <div className="group"><button className="row-btn" disabled={busy} onClick={undo}><Undo2 size={20} /><span>한 단계 되돌리기<small>잘못 눌렀을 때만</small></span><ChevronRight size={18} /></button></div>}
      {view.phase !== 'lobby' && <>
        <p className="group-label">게임을 처음부터 다시</p>
        <div className="group">
          <button className="row-btn" disabled={busy} onClick={() => confirm('지금 게임을 멈추고 처음부터 다시 할까요?\n참가자는 그대로 남고 점수만 0점이 돼요. 1번 문제부터 다시 시작해요.') && run('restart')}>
            <RotateCcw size={20} /><span>처음부터 다시 (참가자 유지)<small>닉네임 그대로 · 점수 0점 · 1번부터</small></span><ChevronRight size={18} /></button>
          <button className="row-btn danger-row" disabled={busy} onClick={() => {
            if (!confirm('지금 게임을 멈추고 새 게임으로 갈까요?\n모든 참가자가 입장 화면으로 돌아가고 기록이 지워져요.')) return
            if (!confirm('정말 모두 지울까요?')) return
            run('reset')
          }}><RotateCcw size={20} /><span>완전히 새로 (모두 다시 입장)<small>참가자·점수 모두 지우기</small></span></button>
        </div>
      </>}
      <details className="group rank-fold" open={view.phase === 'lobby' || ['final', 'draw', 'end'].includes(view.phase)}>
        <summary><Users size={18} />참가자 {view.players}명{view.humans != null && view.humans !== view.players ? ` (실제 ${view.humans} · 가상 ${view.players - view.humans})` : ''} · {view.phase === 'lobby' ? '명단' : '순위'}</summary>
        {(view.roster ?? []).map((p, i) => <div key={p.name} className="mini num"><b>{view.phase === 'lobby' ? i + 1 : p.rank}</b><span>{p.name}{p.bot && <em className="bot">가상</em>}</span><span>{view.phase === 'lobby' ? '' : fmt(p.score)}</span></div>)}
        {!view.players && <p className="lead" style={{ padding: '0 16px 14px', margin: 0 }}>아직 아무도 안 들어왔어요</p>}
      </details>
    </main>}

    {tab === 'questions' && <main className="tab-page">
      <header className="large-title"><small className="num">{view.total_q}문제</small><h1>문제</h1></header>
      <div className="group">
        <button className="row-btn" disabled={!questions.length} onClick={() => openPreview(questions, 0)}><Smartphone size={20} /><span>전체 문제 점검<small>문제마다 참가자·진행자 화면, 사진, 노래 확인</small></span><ChevronRight size={18} /></button>
        <a className="row-btn" href={`${base}#/sim`} target="_blank" rel="noreferrer" onClick={() => { try { localStorage.setItem('hq-pin-sim', pin) } catch { /* noop */ } }}>
          <PlayCircle size={20} /><span>실전처럼 혼자 풀어 보기 (경품까지)</span><ChevronRight size={18} /></a>
      </div>
      {msg && <div className="err">{msg}</div>}
      <BankBrowser admin={admin} phase={view.phase} setMsg={setMsg} onPreview={openPreview} onAdded={() => { setEditorKey((k) => k + 1); refreshQuestions(); refreshImages(); refreshAudios() }} />
      <QuestionCheck admin={admin} images={images} />
      <details className="group fold"><summary><Shuffle size={18} />문제 은행에서 랜덤으로 다시 뽑기</summary>
        <BankPanel admin={admin} phase={view.phase} setMsg={setMsg} onDone={() => { setEditorKey((k) => k + 1); refreshImages(); refreshQuestions() }} />
      </details>
      <QuestionEditor key={editorKey} admin={admin} phase={view.phase} setMsg={setMsg} images={images} onImage={onImage}
        onPreview={openPreview} onSaved={refreshQuestions} audios={audios} onAudio={onAudio} />
    </main>}

    {tab === 'settings' && <main className="tab-page">
      <header className="large-title"><h1>설정</h1></header>
      {msg && <div className="err">{msg}</div>}
      <p className="group-label">참가자 접속</p>
      <div className="group">
        <button className="row-btn" onClick={() => setQr(true)}><QrCode size={20} /><span>입장 QR 크게 보기</span><ChevronRight size={18} /></button>
        <button className="row-btn" onClick={() => navigator.clipboard?.writeText(base).then(() => setMsg('주소를 복사했어요'))}><Copy size={20} /><span>참가 링크 복사</span><ChevronRight size={18} /></button>
      </div>
      <p className="group-label">리허설</p>
      <div className="group pad">
        <div className="chips-row">{[20, 50, 100].map((n) => <button key={n} className="ghost" onClick={() => run('bots', { n })}><Users size={15} style={{ verticalAlign: -2 }} /> 가상 {n}명</button>)}</div>
        <AutoRehearsal admin={admin} view={view} setMsg={setMsg} />
      </div>
      <p className="group-label">다시 하기</p>
      <div className="group">
        <button className="row-btn" disabled={busy} onClick={() => confirm('한 판 더 할까요?\n닉네임은 그대로, 점수만 0점이 돼요. (가상 참가자는 빠져요)') && run('restart')}>
          <RotateCcw size={20} /><span>한 판 더<small>닉네임 유지 · 점수만 0점</small></span><ChevronRight size={18} /></button>
      </div>
      <p className="group-label">보안</p>
      <div className="group pad"><PinChange admin={admin} busy={busy} onChanged={(p) => { setPin(p); savePin(p) }} /></div>
      <div className="group">
        <button className="row-btn danger-row" disabled={busy} onClick={() => {
          if (!confirm('새 게임을 시작할까요?\n모든 참가자가 입장 화면으로 돌아가고 기록이 지워져요.')) return
          if (view.phase !== 'lobby' && !confirm('지금 게임이 진행 중이에요. 정말 모두 지울까요?')) return
          run('reset')
        }}><RotateCcw size={20} /><span>새 게임 (모든 기록 지우기)<small>리허설 후 · 행사가 끝난 뒤</small></span></button>
      </div>
    </main>}

    <nav className="tabbar" aria-label="진행자 메뉴">
      {[['live', '진행', Radio], ['questions', '문제', ListChecks], ['settings', '설정', Settings]].map(([k, l, Icon]) => (
        <button key={k} className={tab === k ? 'on' : ''} onClick={() => setTab(k)} aria-current={tab === k ? 'page' : undefined}><Icon size={24} /><span>{l}</span></button>))}
    </nav>
    {qr && <QrOverlay url={base} onClose={() => setQr(false)} />}
    {preview && <PreviewModal list={preview.list} start={preview.idx} admin={admin} images={preview.bank ? [] : images} audios={preview.bank ? [] : audios}
      bank={preview.bank} onAdd={preview.onAdd} onClose={() => setPreview(null)} onSaved={refreshQuestions} />}
  </div>
}

// 진행 탭이 아닐 때 위에 붙는 작은 막대: 남은 시간과 다음 버튼만
function MiniBar({ view, next, phaseKo, busy, run, onOpen }) {
  const q = view.question
  const left = useCountdown(view.phase === 'q' ? view.q_started_at : null, q?.limit_sec ?? 15)
  return <div className="minibar">
    <button className="mb-info" onClick={onOpen}><b>{phaseKo}</b>{view.phase === 'q' && <span className={`num ${left <= 5 ? 'hurry' : ''}`}>{Math.ceil(left)}초 · {view.submitted}/{view.players}</span>}</button>
    <button className="mb-go" onClick={onOpen}>진행 탭으로<ChevronRight size={16} /></button>
  </div>
}

// 진행 탭의 큰 타이머
function LiveTimer({ view }) {
  const q = view.question
  const left = useCountdown(view.q_started_at, q.limit_sec)
  const all = view.players > 0 && view.submitted >= view.players
  return <div className={`live-timer ${left <= 5 ? 'hurry' : ''} ${left <= 0 ? 'over' : ''}`}>
    <b className="num">{left > 0 ? Math.ceil(left) : 0}</b>
    <div className="lt-side">
      <div className="track"><i style={{ width: `${(left / q.limit_sec) * 100}%` }} /></div>
      <span className="num">{left <= 0 ? '시간 끝! 정답 공개를 눌러 주세요' : all ? `전원 제출 · 바로 공개해도 돼요` : `제출 ${view.submitted} / ${view.players}명`}</span>
    </div>
  </div>
}

// 진행자 카드: 지금 단계에서 읽을 멘트 + 정답(참가자보다 먼저) + 다음 문제 미리보기
function HostCard({ view, admin, audios = [], onPreview }) {
  const [cur, setCur] = useState(null)
  useEffect(() => { admin('current').then(setCur).catch(() => {}) }, [view.phase, view.qi]) // eslint-disable-line
  const q = view.question
  const label = (qq, a) => (a != null ? options(qq)[a]?.[0] : qq.type === 'survey' ? '공개할 때 결정 (가장 많이 고른 답)' : qq.type === 'minority' ? '공개할 때 결정 (가장 적게 고른 답)' : '정답 없음 (투표)')
  const top = view.ranking
  const nx = cur?.next
  const correct = q && view.dist && q.answer != null ? view.dist[q.answer] : null

  let say
  switch (view.phase) {
    case 'lobby':
      say = `지금 ${view.players}명 들어왔어요! 링크 열고 닉네임만 쓰면 입장. 빨리 맞힐수록 고득점, 3연속이면 보너스! 시작합니다!`
      break
    case 'q':
      say = cur?.now?.host || `${q.idx + 1}번 문제! ${q.limit_sec}초 드립니다. 빨리 누를수록 점수가 높아요!`
      break
    case 'answer':
      say = q.type === 'poll'
        ? `투표 결과 나왔습니다! 1등은 '${options(q)[view.dist.indexOf(Math.max(...view.dist))][0]}'! ${q.note || ''}`
        : q.answer == null ? '아무도 답을 안 냈네요! 이번 문제는 점수 없이 넘어갑니다.'
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
    {q && ['q', 'answer'].includes(view.phase) && audios.includes(q.idx) && <ClipPlayer admin={admin} idx={q.idx} key={`c${q.idx}`} />}

    {q && ['q', 'answer'].includes(view.phase) && !audios.includes(q.idx) && cur?.now?.media && !parseYouTube(cur.now.media) && <a className="music-btn" href={`https://www.youtube.com/results?search_query=${encodeURIComponent(cur.now.media)}`} target="_blank" rel="noreferrer">
      <Music size={22} /><span>노래 틀기: {cur.now.media}<small>유튜브가 열려요 · 앞부분 10초만 틀고 멈추세요</small></span></a>}
    {q && view.phase === 'q' && cur?.now && <div className="host-ans"><Eye size={16} />
      정답 <b>{label(q, cur.now.answer)}</b>{cur.now.note && <span> · {cur.now.note}</span>}</div>}
    {nx && ['lobby', 'answer', 'bet'].includes(view.phase) && <div className="host-next">
      <small>다음 {nx.idx + 1}번{nx.is_bet ? ' (베팅 문제)' : ''}</small>
      <p>{nx.q}</p>
      <span><Eye size={14} /> 정답 {label(nx, nx.answer)}</span>
      {(nx.media || audios.includes(nx.idx)) && <span style={{ display: 'block', marginTop: 4 }}><Music size={14} /> 노래 퀴즈 · 문제를 열면 여기서 바로 재생돼요{audios.includes(nx.idx) ? ' (음원 파일)' : ''}</span>}
      <button className="ghost" style={{ margin: '8px 0 0', display: 'block' }} onClick={() => onPreview(nx, nx.idx)}><Smartphone size={15} style={{ verticalAlign: -2 }} /> 참가자 화면 미리보기</button>
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
    <button className="go" disabled={busy} onClick={() => run('draw', { n, from_drawn: view.drawn_at ?? '' })}><Dices size={22} />{n}명 뽑기</button>
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
      <p style={{ margin: '0 0 10px', color: '#555', fontSize: 14 }}>잘 안 찍히면 이 폰의 화면 밝기를 올려 주세요</p>
      {src && <img src={src} alt="입장 QR 코드" />}
      <p>{url}</p>
    </div>
  </div>
}

function PinChange({ admin, busy, onChanged }) {
  const [open, setOpen] = useState(false)
  const [a, setA] = useState(''), [b, setB] = useState('')
  const [err, setErr] = useState(null)
  if (!open) return <><button className="ghost" onClick={() => setOpen(true)}><KeyRound size={15} style={{ verticalAlign: -2 }} /> 진행자 PIN 바꾸기</button></>
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

// 문제 은행에서 랜덤 세트 만들기. '고정'한 문제(사진 문제 등)는 그대로 두고 나머지만 새로 뽑는다.
const CATS = ['추억', '가요', '노래', '이모지', '요즘 말', '예능', '회사', '상식', '다수결', '소수결']
function BankPanel({ admin, phase, setMsg, onDone }) {
  const [stats, setStats] = useState(null)
  const [counts, setCounts] = useState({ 추억: 1, 가요: 1, 노래: 2, 이모지: 2, '요즘 말': 1, 예능: 1, 회사: 0, 상식: 0, 다수결: 1, 소수결: 1 })
  const [minDiff, setMinDiff] = useState(2)
  const [bet, setBet] = useState(true)
  useEffect(() => { admin('bank_stats').then(setStats).catch(() => {}) }, []) // eslint-disable-line
  const avail = (c) => stats?.[c] ? [1, 2, 3].filter((d) => d >= minDiff).reduce((a, d) => a + (stats[c][d] ?? 0), 0) : 0
  const total = CATS.reduce((a, c) => a + Math.min(counts[c], avail(c)), 0) + (bet ? 1 : 0)
  return <div className="bank">
    <div className="bank-head"><b>문제 은행에서 랜덤으로 뽑기</b><small>자주 나온 문제는 뒤로 밀려서 매번 다르게 나와요</small></div>
    <div className="bank-grid">{CATS.map((c) => (
      <div key={c} className="bank-cat">
        <span>{c} <small className="num">{avail(c)}개</small></span>
        <div className="stepper sm">
          <button type="button" aria-label={`${c} 줄이기`} onClick={() => setCounts((v) => ({ ...v, [c]: Math.max(0, v[c] - 1) }))}>−</button>
          <b className="num">{counts[c]}</b>
          <button type="button" aria-label={`${c} 늘리기`} onClick={() => setCounts((v) => ({ ...v, [c]: Math.min(avail(c), v[c] + 1) }))}>+</button>
        </div>
      </div>))}
    </div>
    <div className="seg" style={{ margin: '8px 0' }}>{[[1, '쉬움 포함'], [2, '보통 이상'], [3, '어려움만']].map(([d, l]) => (
      <button type="button" key={d} className={minDiff === d ? 'on' : ''} onClick={() => setMinDiff(d)}>{l}</button>))}</div>
    <label style={{ fontSize: 14, color: 'var(--mute)' }}><input type="checkbox" checked={bet} onChange={(e) => setBet(e.target.checked)} /> 마지막에 올인 베팅 문제 넣기</label>
    <button className="go" style={{ marginTop: 10 }} disabled={phase !== 'lobby'} onClick={async () => {
      if (!confirm(`은행에서 ${total}문제를 새로 뽑을까요?\n'고정'한 문제는 그대로 남고, 나머지 문제는 바뀌어요.`)) return
      try { const r = await admin('compose', { counts, min_diff: minDiff, bet }); setMsg(`랜덤 세트를 만들었어요 (고정 문제 포함 총 ${r.total}문제)`); onDone() } catch { /* 메시지 표시됨 */ }
    }}><Shuffle size={18} />랜덤 세트 만들기</button>
    <p className="lead num" style={{ fontSize: 13, margin: '6px 0 0' }}>은행에서 {total}문제 + 고정한 문제</p>
  </div>
}

// 문항 점검: 회식 전에 한 번 눌러 보면 빠진 것을 한꺼번에 알려 준다.
function QuestionCheck({ admin, images }) {
  const [res, setRes] = useState(null)
  async function check() {
    let list; try { list = await admin('questions_get') } catch { return }
    const out = []
    const n = (i) => `${i + 1}번`
    list.forEach((q, i) => {
      if (q.reveal && !images.includes(i)) out.push(['err', `${n(i)} 사진 문제인데 사진이 없어요`])
      if ((q.opts ?? []).some((o) => /^\(이름 \d\)$/.test(String(o).trim()))) out.push(['err', `${n(i)} 보기가 '(이름 1)' 같은 자리 표시예요`])
      if (!['poll', 'survey', 'minority'].includes(q.type) && q.answer == null) out.push(['err', `${n(i)} 정답이 없어요`])
      if (q.type === 'mc' && new Set(q.opts).size !== q.opts.length) out.push(['err', `${n(i)} 보기가 겹쳐요`])
      if (q.q.length > 60) out.push(['warn', `${n(i)} 문제가 길어서 폰에서 3줄 이상이에요`])
    })
    const bets = list.filter((q) => q.is_bet)
    if (bets.length === 0) out.push(['warn', '마지막 올인 베팅 문제가 없어요'])
    if (bets.length > 1) out.push(['err', '베팅 문제가 2개 이상이에요'])
    if (bets.length === 1 && !list[list.length - 1].is_bet) out.push(['warn', '베팅 문제가 맨 마지막이 아니에요'])
    const dup = list.map((q) => q.q).filter((x, i, a) => a.indexOf(x) !== i)
    if (dup.length) out.push(['err', `같은 문제가 두 번 있어요: ${dup[0].slice(0, 20)}…`])
    if (list.length < 8) out.push(['warn', `문제가 ${list.length}개라 너무 짧아요 (12~15개 추천)`])
    if (list.length > 18) out.push(['warn', `문제가 ${list.length}개라 길어요 (12~15개 추천)`])
    const mins = Math.round(list.reduce((a, q) => a + q.limit_sec + 75, 0) / 60)
    setRes({ out, total: list.length, mins })
  }
  return <div className="check">
    <button className="ghost" onClick={check}><ClipboardCheck size={15} style={{ verticalAlign: -2 }} /> 문항 점검하기</button>
    {res && <div className="check-res">
      <p className="num">총 {res.total}문제 · 예상 진행 시간 약 {res.mins}분</p>
      {res.out.length === 0 && <p className="ok"><CheckCircle2 size={16} /> 문제 없어요. 바로 진행해도 돼요!</p>}
      {res.out.map(([lv, t], i) => <p key={i} className={lv}>{lv === 'err' ? <AlertTriangle size={15} /> : '·'} {t}</p>)}
    </div>}
  </div>
}

// 자동 리허설: 가상 참가자 30명으로 첫 문제부터 마무리 화면까지 알아서 넘긴다. 끝나면 새 게임으로 정리.
function AutoRehearsal({ admin, view, setMsg }) {
  const [running, setRunning] = useState(false)
  const stop = useRef(false)
  const live = useRef(view); live.current = view
  const wait = (ms) => new Promise((r) => setTimeout(r, ms))
  async function go() {
    if ((view.humans ?? 0) > 0) { setMsg(`실제 참가자 ${view.humans}명이 들어와 있어서 자동 리허설을 할 수 없어요 (끝나면 기록이 지워져요)`); return }
    if (!confirm('자동 리허설을 시작할까요?\n가상 참가자 30명으로 끝까지 빠르게 진행한 뒤, 새 게임으로 정리해요.\n(실제 참가자가 있으면 그분들도 같이 진행돼요)')) return
    stop.current = false; setRunning(true)
    try {
      await admin('bots', { n: 30 })
      for (let guard = 0; guard < 120 && !stop.current; guard++) {
        const v = live.current
        if (v.phase === 'end') break
        if (v.phase === 'draw') { await admin('draw', { n: 2 }); await wait(4500) }
        await admin('next', { from_phase: v.phase, from_qi: v.qi })
        const ph = live.current.phase
        await wait(ph === 'q' ? 6000 : ph === 'answer' ? 2500 : 2000)
      }
      if (!stop.current) { await wait(3000); await admin('reset'); setMsg('자동 리허설 완료! 새 게임으로 정리해 뒀어요') }
    } catch { /* admin() 이 메시지를 띄운다 */ } finally { setRunning(false) }
  }
  return running
    ? <button className="ghost" onClick={() => { stop.current = true }}><Square size={15} style={{ verticalAlign: -2 }} /> 자동 리허설 멈추기</button>
    : <button className="ghost" disabled={view.phase !== 'lobby'} onClick={go}><PlayCircle size={15} style={{ verticalAlign: -2 }} /> 자동 리허설 (끝까지 빠르게)</button>
}

// 참가자 화면 미리보기: 실제 폰 화면과 같은 모양으로 문제·타이머·사진 연출을 재생한다. 점수나 서버 상태는 건드리지 않는다.
function PreviewModal({ list, start, admin, images, audios = [], bank = false, onAdd, onClose, onSaved }) {
  const [view, setView] = useState('player')   // player | host
  const ckKey = 'hq-checked'
  const sig = (x) => `${x.q}|${(x.opts ?? []).join(',')}|${x.answer}`
  const [checked, setChecked] = useState(() => { try { return JSON.parse(localStorage.getItem(ckKey) ?? '[]') } catch { return [] } })
  const toggleCheck = (k) => setChecked((c) => { const n = c.includes(k) ? c.filter((x) => x !== k) : [...c, k]; try { localStorage.setItem(ckKey, JSON.stringify(n)) } catch { /* noop */ } return n })
  const doneCount = list.filter((x) => checked.includes(sig(x))).length
  const [idx, setIdx] = useState(start)
  const q = list[idx] ?? {}
  const hasImage = images.includes(idx)
  const limit = q.limit_sec ?? 15
  const [img, setImg] = useState(undefined)
  const [t0, setT0] = useState(() => Date.now())
  const [now, setNow] = useState(Date.now())
  const [reveal, setReveal] = useState(false)
  useEffect(() => {
    setImg(undefined); setReveal(false); setT0(Date.now())
    if (hasImage) admin('image_get', { idx }).then((d) => setImg(d ?? null)).catch(() => setImg(null))
  }, [idx]) // eslint-disable-line
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 200); return () => clearInterval(t) }, [])
  const left = reveal ? 0 : Math.max(0, limit - (now - t0) / 1000)
  const pq = { ...q, idx, has_image: hasImage, limit_sec: limit }
  const opts = q.type ? options(pq) : []
  const ox = q.type === 'ox'
  return <div className="qr-overlay" onClick={onClose} role="dialog" aria-label="참가자 화면 미리보기">
    <div className="preview" onClick={(e) => e.stopPropagation()}>
      <div className="preview-bar">
        <b className="num">{idx + 1} / {list.length}번 · <span style={{ color: 'var(--soju)' }}>{doneCount}개 확인</span></b>
        <button aria-label="닫기" onClick={onClose}><Close size={20} /></button>
      </div>
      <div className="seg review-seg">
        <button type="button" className={view === 'player' ? 'on' : ''} onClick={() => setView('player')}>참가자 화면</button>
        <button type="button" className={view === 'host' ? 'on' : ''} onClick={() => setView('host')}>진행자 화면</button>
      </div>
      {view === 'host' && <HostReview q={q} idx={idx} hasImage={hasImage} img={img} hasAudio={audios.includes(idx)} admin={admin} onSaved={bank ? null : onSaved} bank={bank} />}
      {view === 'player' && <div className="phone preview-phone">
        <div className="round">{q.round} · {idx + 1}번</div>
        {!reveal && <div className={`timer ${left <= 5 ? 'hurry' : ''}`}>
          <div className="bar"><i style={{ width: `${(left / limit) * 100}%` }} /></div><b className="num">{Math.ceil(left)}</b></div>}
        <h1 className="title">{q.q}</h1>
        {q.media && <div className="music"><span className="eq"><i /><i /><i /><i /></span>노래 퀴즈 · 진행자 폰에서 노래가 나와요</div>}
        {q.type === 'survey' && <p className="rule-hint">다수결! 가장 많은 사람이 고른 답이 정답이에요</p>}
        {q.type === 'minority' && <p className="rule-hint">소수결! 가장 적은 사람이 고른 답이 정답이에요</p>}
        {q.type === 'poll' && <p className="lead">정답 없는 투표예요. 점수엔 영향 없어요.</p>}
        {q.is_bet && <p className="rule-hint">마지막 올인 베팅 문제예요 (실전에선 이 앞에 베팅 화면)</p>}
        {hasImage && (img === undefined ? <div className="qimg"><span className="lead">사진 불러오는 중…</span></div>
          : img ? <QImage q={pq} left={reveal ? null : left} src={img} /> : null)}
        <div className={`choices ${ox ? 'ox' : ''}`}>
          {opts.map(([lbl, k, bg, dark], i) => {
            const dim = reveal && q.answer != null && i !== q.answer
            return <div key={i} className={`choice ${dark ? 'dark' : ''}`} style={{ background: bg, opacity: dim ? 0.3 : 1, outline: reveal && i === q.answer ? '4px solid #fff' : 'none', ...(ox ? { fontSize: 56, minHeight: 120 } : {}) }}>
              {ox ? lbl : <><span className="k">{k}</span>{lbl}</>}</div>
          })}
        </div>
        {reveal && q.note && <div className="panel note"><span>{q.note}</span></div>}
      </div>}
      <div className="preview-actions">
        <button className="ghost" disabled={idx === 0} onClick={() => setIdx((v) => v - 1)} aria-label="이전 문제"><ChevronLeft size={18} style={{ verticalAlign: -3 }} /> 이전</button>
        <button className="ghost" onClick={() => setReveal((r) => !r)}>{reveal ? '문제 보기' : '정답 보기'}</button>
        <button className="ghost" onClick={() => { setReveal(false); setT0(Date.now()) }} aria-label="다시 재생"><RotateCw size={16} style={{ verticalAlign: -3 }} /></button>
        {bank && onAdd && <button className="ghost" onClick={() => onAdd(q)}><Plus size={16} style={{ verticalAlign: -3 }} /> 세트에 넣기</button>}
        <button className={`ghost ${checked.includes(sig(q)) ? 'checked' : ''}`} onClick={() => toggleCheck(sig(q))}><CheckCircle2 size={16} style={{ verticalAlign: -3 }} /> {checked.includes(sig(q)) ? '확인함' : '확인'}</button>
        <button className="go" disabled={idx >= list.length - 1} onClick={() => setIdx((v) => v + 1)} aria-label="다음 문제">다음 <ChevronRight size={18} style={{ verticalAlign: -3 }} /></button>
      </div>
    </div>
  </div>
}

// 노래 바로 재생: 유튜브 공식 플레이어를 진행자 화면에 넣고, 누르면 지정 구간을 15초 재생 후 자동 정지.
// 소리는 진행자 폰(또는 연결한 스피커)에서만 난다. 참가자 폰마다 틀면 박자가 어긋나서 진행자 폰 하나로.
function SongPlayer({ media }) {
  const yt = parseYouTube(media)
  const [play, setPlay] = useState(0)
  const [len, setLen] = useState(15)
  if (!yt) return null
  const src = `https://www.youtube-nocookie.com/embed/${yt.id}?autoplay=1&start=${yt.start}&end=${yt.start + len}&controls=1&playsinline=1&rel=0`
  return <div className="song">
    {play > 0 && <iframe key={play} src={src} title="노래 재생" allow="autoplay; encrypted-media" className="song-frame" />}
    <div className="song-row">
      <button className="music-btn" onClick={() => setPlay((n) => n + 1)}><Music size={22} /><span>{play ? '다시 듣기' : '노래 바로 재생'}<small>{yt.start >= 60 ? `${Math.floor(yt.start / 60)}분 ${yt.start % 60}초부터 ` : yt.start ? `${yt.start}초부터 ` : '처음부터 '}{len}초 재생</small></span></button>
      <div className="seg song-len">{[10, 15, 30].map((n) => <button key={n} type="button" className={len === n ? 'on' : ''} onClick={() => setLen(n)}>{n}초</button>)}</div>
    </div>
    <a className="song-alt" href={`https://www.youtube.com/watch?v=${yt.id}${yt.start ? `&t=${yt.start}s` : ''}`} target="_blank" rel="noreferrer">영상이 안 나오면 유튜브 앱에서 열기</a>
  </div>
}

// 올려 둔 음원 조각 재생(진행자 폰에서만). 유튜브 없이 바로, 오프라인 지연 없이.
function ClipPlayer({ admin, idx }) {
  const [src, setSrc] = useState(null)
  const [playing, setPlaying] = useState(false)
  const el = useRef(null)
  useEffect(() => { admin('audio_get', { idx }).then(setSrc).catch(() => {}) }, [idx]) // eslint-disable-line
  const toggle = () => {
    const a = el.current; if (!a) return
    if (playing) { a.pause(); a.currentTime = 0; setPlaying(false) } else { a.currentTime = 0; a.play().then(() => setPlaying(true)).catch(() => {}) }
  }
  return <div className="song">
    {src && <audio ref={el} src={src} preload="auto" onEnded={() => setPlaying(false)} />}
    <button className="music-btn" style={{ border: 0, width: '100%', textAlign: 'left' }} disabled={!src} onClick={toggle}>
      <Music size={22} /><span>{!src ? '음원 불러오는 중…' : playing ? '정지' : '노래 바로 재생'}<small>올려 둔 음원 · 약 20초 · 진행자 폰에서만 나와요</small></span></button>
  </div>
}

// 진행 탭의 노래 플레이어(유튜브). 다음 문제가 노래면 정답 공개 화면에서 미리 띄워 광고를 넘겨 두고,
// 문제를 열면 같은 플레이어가 그대로 이어진다(key 가 문제 번호라서 다시 만들어지지 않음).
function LiveSong({ view, questions, audios, admin, onSaved }) {
  const isSong = (i) => i != null && questions[i] && parseYouTube(questions[i].media) && !audios.includes(i)
  const cur = view.phase === 'q' ? view.qi : null
  const nxt = ['lobby', 'answer', 'bet'].includes(view.phase) ? view.qi + 1 : null
  const idx = isSong(cur) ? cur : isSong(nxt) ? nxt : null
  if (idx == null) return null
  const media = questions[idx].media
  return <div className={idx === nxt ? 'song-next' : ''}>
    {idx === nxt && <p className="lead" style={{ fontSize: 15, margin: '0 0 6px' }}>다음 {idx + 1}번은 노래 문제예요. <b>광고 먼저 넘기기</b>를 눌러 두면 문제를 열 때 바로 노래가 나와요.</p>}
    <YTPlayer key={`yt${idx}`} media={media} onSaveStart={async (sec) => { await admin('set_media', { idx, media: withStart(media, sec) }); onSaved() }} />
  </div>
}

// 점검 모드의 진행자 화면: 문제를 열었을 때 진행자가 보게 될 정보 전부(정답·멘트·해설·사진 원본·노래)
function HostReview({ q, idx, hasImage, img, hasAudio, admin, onSaved, bank = false }) {
  const label = q.answer != null && q.type ? options({ ...q, idx })[q.answer]?.[0] : q.type === 'survey' ? '공개할 때 결정 (가장 많이 고른 답)' : q.type === 'minority' ? '공개할 때 결정 (가장 적게 고른 답)' : '정답 없음 (투표)'
  const typeKo = { mc: '4지선다', ox: 'O/X', poll: '투표', survey: '다수결', minority: '소수결' }[q.type] ?? q.type
  const revealKo = { zoom: '확대 → 점점 작게', blur: '흐림 → 선명', pixel: '모자이크 → 선명', silhouette: '흑백 윤곽 → 원본' }[String(q.reveal ?? '').split('@')[0]]
  const problems = []
  if (q.reveal && !hasImage) problems.push('사진 연출 문제인데 사진이 없어요')
  if ((q.opts ?? []).some((o) => /^\(이름 \d\)$/.test(String(o).trim()))) problems.push("보기에 '(이름 1)' 같은 자리 표시가 남아 있어요")
  if (!q.note) problems.push('해설이 비어 있어요 (정답 공개 때 할 말이 없어요)')
  return <div className="phone preview-phone host-review">
    <div className="round">{q.round} · {bank ? `난이도 ${['', '쉬움', '보통', '어려움'][q.diff]} · 출제 ${q.used}회` : `${idx + 1}번`} · {typeKo} · {q.limit_sec ?? 15}초{q.is_bet ? ' · 올인 베팅' : ''}</div>
    <h1 className="title" style={{ fontSize: 24 }}>{q.q}</h1>
    {problems.map((p) => <div key={p} className="warn"><AlertTriangle size={16} />{p}</div>)}
    <div className="host-say"><Mic size={18} /><p>{q.host || `${idx + 1}번 문제! ${q.limit_sec ?? 15}초 드립니다. 빨리 누를수록 점수가 높아요!`}</p></div>
    <div className="host-ans"><Eye size={16} />정답 <b>{label}</b></div>
    {q.note && <div className="panel note"><span>해설 · {q.note}</span></div>}
    {hasImage && <div className="review-img">{img ? <img src={img} alt="사진 원본" /> : <span className="lead">사진 불러오는 중…</span>}<small>사진 원본 · 연출: {revealKo ?? '그대로'}</small></div>}
    {hasAudio && <ClipPlayer admin={admin} idx={idx} key={`rc${idx}`} />}
    {!hasAudio && q.media && parseYouTube(q.media) && <YTPlayer media={q.media} key={`ry${idx}`} onSaveStart={onSaved ? async (sec) => { await admin('set_media', { idx, media: withStart(q.media, sec) }); onSaved() } : undefined} />}
    {!hasAudio && q.media && !parseYouTube(q.media) && <div className="warn"><AlertTriangle size={16} />노래 검색어만 있어요 ("{q.media}") · 유튜브 링크나 음원을 넣으면 바로 재생돼요</div>}
  </div>
}

// 문제 은행 둘러보기: 카테고리를 고르면 그 카테고리 전체 문제를 참가자·진행자 화면으로 넘겨 본다
const BANK_CATS = [['추억', '추억 소환'], ['가요', '추억의 가요'], ['노래', '노래 퀴즈'], ['요즘 말', '요즘 말 테스트'], ['예능', '예능·드라마'],
  ['이모지', '이모지 퀴즈'], ['회사', '회사 생활'], ['상식', '상식 퀴즈'], ['다수결', '100명에게 물었습니다'], ['소수결', '소수가 이긴다'], ['베팅', '올인 베팅']]
function BankBrowser({ admin, phase, setMsg, onPreview, onAdded }) {
  const [stats, setStats] = useState(null)
  const [cat, setCat] = useState(null)
  const [items, setItems] = useState([])
  useEffect(() => { admin('bank_stats').then(setStats).catch(() => {}) }, []) // eslint-disable-line
  const total = (c) => stats?.[c] ? (stats[c]['1'] ?? 0) + (stats[c]['2'] ?? 0) + (stats[c]['3'] ?? 0) : 0
  const all = stats ? Object.keys(stats).reduce((a, c) => a + total(c), 0) : 0
  const asQ = (b, round) => ({ ...b, round, limit_sec: b.media ? 25 : 15, is_bet: b.cat === '베팅', reveal: '' })
  async function open(c) {
    setCat(c)
    try { setItems(await admin('bank_list', { cat: c })) } catch { /* 메시지 표시됨 */ }
  }
  const add = async (q) => {
    if (phase !== 'lobby') return setMsg('문제는 게임 시작 전(대기 단계)에만 넣을 수 있어요')
    try { await admin('bank_add', { id: q.id }); setMsg(`"${q.q.slice(0, 18)}…"을(를) 지금 세트에 넣었어요 (베팅 문제 앞, 고정)`); onAdded() } catch { /* 메시지 표시됨 */ }
  }
  const round = BANK_CATS.find(([c]) => c === cat)?.[1]
  return <details className="group fold bank-browse">
    <summary><Library size={18} />문제 은행 둘러보기 <small className="num" style={{ color: 'var(--mute)', fontWeight: 500 }}>· {all}문제</small></summary>
    <div className="cat-chips">{BANK_CATS.map(([c]) => <button key={c} type="button" className={cat === c ? 'on' : ''} onClick={() => open(c)}>{c} <b className="num">{total(c)}</b></button>)}</div>
    {cat && <div className="bank-items">
      <button className="row-btn" onClick={() => onPreview(items.map((b) => asQ(b, round)), 0, { bank: true, onAdd: add })}>
        <Smartphone size={20} /><span>{cat} {items.length}문제 처음부터 넘겨 보기<small>참가자·진행자 화면으로 확인</small></span><ChevronRight size={18} /></button>
      {items.map((b, i) => <button key={b.id} className="bank-item" onClick={() => onPreview(items.map((x) => asQ(x, round)), i, { bank: true, onAdd: add })}>
        <span className={`diff d${b.diff}`}>{['', '쉬움', '보통', '어려움'][b.diff]}</span>
        <span className="bq">{b.q}</span>
        <small className="num">{b.used ? `${b.used}회` : '새 문제'}</small>
      </button>)}
    </div>}
  </details>
}
