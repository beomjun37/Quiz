import { useEffect, useState } from 'react'
import { ArrowDown, ArrowUp, Braces, ImagePlus, Plus, Save, Smartphone, Trash2 } from 'lucide-react'

const TYPES = [['mc', '4지선다'], ['ox', 'O/X'], ['survey', '다수결'], ['minority', '소수결'], ['poll', '투표']]
const NO_ANSWER = ['poll', 'survey', 'minority']
const LIMITS = [10, 15, 20, 30]
// 부장님 마음 맞히기 템플릿: 넣은 뒤 부장님께 받은 답으로 정답만 찍으면 된다.
const BOSS = [
  ['부장님 최애 회식 안주는?', ['삼겹살', '회', '치킨', '골뱅이']],
  ['부장님 노래방 18번은 몇 년대 노래?', ['80년대', '90년대', '2000년대', '최신곡']],
  ['부장님 주말에 가장 많이 하는 것은?', ['골프', '등산', '낚시', '집에서 휴식']],
  ['부장님의 첫 휴대폰 브랜드는?', ['애니콜', '싸이언', '스카이', '모토로라']],
  ['부장님 주량은?', ['소주 1병 미만', '소주 1~2병', '소주 2~3병', '측정 불가']],
  ['부장님이 신입 때 가장 많이 들은 말은?', ['다시 해 와', '수고했어', '내일 얘기하자', '밥은 먹었어?']],
  ['부장님의 학창 시절 별명 스타일은?', ['외모 관련', '이름 관련', '성격 관련', '별명 없음']],
]
const bossQ = ([q, opts]) => ({ ...blank(), round: '부장님 마음 맞히기', q, opts, note: '부장님 한 말씀 부탁드립니다!', host: '부장님은 표정 관리 부탁드려요! 정답은 부장님이 직접 공개합니다.', pinned: true })
const blank = () => ({ round: '', type: 'mc', q: '', opts: ['', '', '', ''], answer: 0, note: '', host: '', is_bet: false, limit_sec: 15, reveal: '', pinned: true })

// 서버 형식 ↔ 편집 형식
const fromServer = (r) => ({
  round: r.round ?? '', type: r.type, q: r.q ?? '', note: r.note ?? '', host: r.host ?? '',
  opts: r.type === 'ox' ? ['', '', '', ''] : [...(r.opts ?? []), '', '', '', ''].slice(0, 4),
  answer: r.answer, is_bet: !!r.is_bet, limit_sec: r.limit_sec ?? 15, reveal: r.reveal ?? '', pinned: !!r.pinned,
})
const toServer = (e) => ({
  round: e.round.trim(), type: e.type, q: e.q.trim(), note: e.note.trim(), host: e.host.trim(),
  opts: e.type === 'ox' ? [] : e.opts.map((o) => o.trim()),
  answer: NO_ANSWER.includes(e.type) ? null : e.answer, is_bet: e.type !== 'poll' && e.is_bet, limit_sec: e.limit_sec, reveal: e.reveal, pinned: e.pinned,
})

function problems(list) {
  const out = []
  list.forEach((e, i) => {
    const n = `${i + 1}번`
    if (!e.q.trim()) out.push(`${n}: 문제를 적어 주세요`)
    if (e.type !== 'ox' && e.opts.some((o) => !o.trim())) out.push(`${n}: 보기 4개를 모두 채워 주세요`)
    if (!NO_ANSWER.includes(e.type) && (e.answer == null || e.answer < 0)) out.push(`${n}: 정답을 골라 주세요`)
  })
  if (list.filter((e) => e.is_bet).length > 1) out.push('베팅 문제는 하나만 둘 수 있어요')
  return out
}

/**
 * 진행자용 문항 편집기. 폰에서도 고칠 수 있게 칸 채우기 방식.
 * 저장은 대기 단계에서만 된다(게임 중 문항이 바뀌면 점수가 꼬이므로 서버가 막는다).
 */
export default function QuestionEditor({ admin, phase, setMsg, images, onImage, onPreview }) {
  const [list, setList] = useState(null)
  const [dirty, setDirty] = useState(false)
  const [json, setJson] = useState(null)
  const [busy, setBusy] = useState(false)

  const load = () => admin('questions_get').then((r) => { setList(r.map(fromServer)); setDirty(false) }).catch(() => {})
  useEffect(() => { load() }, []) // eslint-disable-line

  const edit = (i, patch) => { setList((l) => l.map((e, k) => (k === i ? { ...e, ...patch } : e))); setDirty(true) }
  const move = (i, d) => { setList((l) => { const c = [...l]; [c[i], c[i + d]] = [c[i + d], c[i]]; return c }); setDirty(true) }
  const remove = (i) => { if (confirm(`${i + 1}번 문제를 지울까요?`)) { setList((l) => l.filter((_, k) => k !== i)); setDirty(true) } }

  async function save() {
    const bad = problems(list)
    if (bad.length) return setMsg(bad.slice(0, 3).join(' · '))
    // 사진 문제의 '(이름 1)' 같은 자리 표시는 막지 않고 한 번 확인만 한다(나중에 채워도 되게)
    const todo = list.map((e, i) => (e.opts.some((o) => /^\(이름 \d\)$/.test(o.trim())) ? i + 1 : 0)).filter(Boolean)
    if (todo.length && !confirm(`${todo.join(', ')}번 문제의 보기가 아직 '(이름 1)' 같은 자리 표시예요.\n그대로 저장할까요? (게임 전에 채우거나 지워 주세요)`)) return
    setBusy(true)
    try { await admin('questions', { list: list.map(toServer) }); setMsg(`${list.length}개 문항을 저장했어요`); setDirty(false) }
    catch { /* admin() 이 메시지를 띄운다 */ } finally { setBusy(false) }
  }

  if (!list) return <p className="lead">문항 불러오는 중…</p>
  const locked = phase !== 'lobby'

  if (json != null) return <div className="qe">
    <div className="qe-bar"><b>JSON 직접 편집</b>
      <button className="ghost" onClick={() => { try { setList(JSON.parse(json).map(fromServer)); setDirty(true); setJson(null) } catch { setMsg('JSON 형식이 잘못됐어요') } }}>폼으로 돌아가기</button></div>
    <textarea value={json} onChange={(e) => setJson(e.target.value)} />
  </div>

  return <div className="qe">
    {locked && <p className="err">게임 중에는 문항을 바꿀 수 없어요. 새 게임이나 한 판 더를 누르면 다시 편집할 수 있어요.</p>}
    {list.map((e, i) => (
      <fieldset key={i} className="qe-card" disabled={locked}>
        {e.reveal && !images.includes(i) && !dirty && <div className="warn">사진 연출 문제인데 사진이 아직 없어요. 아래 '사진 붙이기'를 눌러 주세요.</div>}
        <div className="qe-head">
          <b className="num">{i + 1}</b>
          <input className="qe-round" placeholder="라운드 이름 (예: R1 추억 소환)" value={e.round} onChange={(ev) => edit(i, { round: ev.target.value })} />
          <button type="button" aria-label="위로" disabled={i === 0} onClick={() => move(i, -1)}><ArrowUp size={16} /></button>
          <button type="button" aria-label="아래로" disabled={i === list.length - 1} onClick={() => move(i, 1)}><ArrowDown size={16} /></button>
          <button type="button" aria-label="삭제" onClick={() => remove(i)}><Trash2 size={16} /></button>
        </div>
        <div className="seg">{TYPES.map(([v, l]) => (
          <button type="button" key={v} className={e.type === v ? 'on' : ''} onClick={() => edit(i, { type: v, answer: NO_ANSWER.includes(v) ? null : (e.answer ?? 0), is_bet: v === 'poll' ? false : e.is_bet })}>{l}</button>))}
        </div>
        {e.type === 'survey' && <p className="lead" style={{ fontSize: 13, margin: 0 }}>다수결: 정답은 공개할 때 가장 많이 고른 보기로 정해져요</p>}
        {e.type === 'minority' && <p className="lead" style={{ fontSize: 13, margin: 0 }}>소수결: 정답은 공개할 때 가장 적게 고른 보기로 정해져요</p>}
        <textarea className="qe-q" rows={2} placeholder="문제" value={e.q} onChange={(ev) => edit(i, { q: ev.target.value })} />
        {e.type === 'ox'
          ? <div className="qe-ox">{['O', 'X'].map((l, k) => (
              <button type="button" key={l} className={e.answer === k ? 'on' : ''} onClick={() => edit(i, { answer: k })}>{l}{e.answer === k && ' · 정답'}</button>))}</div>
          : <div className="qe-opts">{e.opts.map((o, k) => (
              <div key={k} className={`qe-opt ${e.type === 'mc' && e.answer === k ? 'on' : ''}`}>
                {e.type === 'mc'
                  ? <button type="button" aria-label={`${k + 1}번을 정답으로`} onClick={() => edit(i, { answer: k })}>{e.answer === k ? '정답' : k + 1}</button>
                  : <span>{k + 1}</span>}
                <input placeholder={`보기 ${k + 1}`} value={o} onChange={(ev) => edit(i, { opts: e.opts.map((x, j) => (j === k ? ev.target.value : x)) })} />
              </div>))}</div>}
        <input placeholder="해설 (정답 공개 때 보여요)" value={e.note} onChange={(ev) => edit(i, { note: ev.target.value })} />
        <input placeholder="진행자 멘트 (문제 열 때 읽을 말, 선택)" value={e.host} onChange={(ev) => edit(i, { host: ev.target.value })} />
        <div className="qe-foot">
          <label>제한 시간 <select value={e.limit_sec} onChange={(ev) => edit(i, { limit_sec: +ev.target.value })}>
            {LIMITS.map((s) => <option key={s} value={s}>{s}초</option>)}</select></label>
          <label>사진 연출 <select value={e.reveal} onChange={(ev) => edit(i, { reveal: ev.target.value })}>
            <option value="">그대로</option><option value="zoom">확대 → 점점 작게</option><option value="blur">흐림 → 점점 선명</option><option value="pixel">모자이크 → 점점 선명</option><option value="silhouette">그림자 → 원본</option></select></label>
          <label title="랜덤 세트를 다시 만들어도 이 문제는 남아요"><input type="checkbox" checked={e.pinned} onChange={(ev) => edit(i, { pinned: ev.target.checked })} /> 고정</label>
          {e.type !== 'poll' && <label><input type="checkbox" checked={e.is_bet} onChange={(ev) => edit(i, { is_bet: ev.target.checked })} /> 베팅 문제</label>}
          {!dirty && <label className="qe-img"><ImagePlus size={16} /> {images.includes(i) ? '사진 바꾸기' : '사진 붙이기'}
            <input type="file" accept="image/*" hidden onChange={(ev) => { onImage(i, ev.target.files?.[0]); ev.target.value = '' }} /></label>}
          {!dirty && images.includes(i) && <button type="button" className="qe-img" onClick={() => onImage(i, null)}><Trash2 size={14} /> 사진 빼기</button>}
          <button type="button" className="qe-img" onClick={() => onPreview(toServer(e), i)}><Smartphone size={14} /> 미리보기</button>
        </div>
      </fieldset>
    ))}
    <div className="qe-bar">
      <button className="ghost" disabled={locked} onClick={() => { setList((l) => [...l, blank()]); setDirty(true) }}><Plus size={15} style={{ verticalAlign: -2 }} /> 문제 추가</button>
      <select className="ghost" disabled={locked} value="" style={{ color: 'var(--fg)', border: 0, font: 'inherit' }}
        onChange={(ev) => { const t = BOSS[+ev.target.value]; if (!t) return
          setList((l) => { const k = l.findIndex((x) => x.is_bet); const c = [...l]; c.splice(k < 0 ? c.length : k, 0, bossQ(t)); return c }); setDirty(true) }}>
        <option value="">+ 부장님 문제 템플릿</option>
        {BOSS.map(([q], i) => <option key={i} value={i}>{q}</option>)}
      </select>
      <button className="go" disabled={locked || busy || !dirty} onClick={save}><Save size={18} />{busy ? '저장 중…' : dirty ? '저장하기' : '저장됨'}</button>
      <button className="ghost" onClick={() => setJson(JSON.stringify(list.map(toServer), null, 1))}><Braces size={15} style={{ verticalAlign: -2 }} /> JSON</button>
    </div>
    {dirty && <p className="lead" style={{ fontSize: 13 }}>사진은 저장한 뒤에 붙일 수 있어요(문항 번호가 정해져야 해서요).</p>}
  </div>
}
