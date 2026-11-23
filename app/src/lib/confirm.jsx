import { useEffect, useState } from 'react'

// iOS 스타일 확인 시트(아래에서 올라옴). 브라우저 기본 confirm 대신 쓴다(카톡 인앱 브라우저에서도 확실히 뜨게).
// 사용: if (!(await ask('정말 지울까요?', { ok: '지우기', danger: true }))) return
let push = null
export function ask(message, { ok = '확인', cancel = '취소', danger = false } = {}) {
  return new Promise((resolve) => {
    if (!push) return resolve(window.confirm(message))
    push({ message, ok, cancel, danger, resolve })
  })
}

export function ConfirmHost() {
  const [req, setReq] = useState(null)
  useEffect(() => { push = setReq; return () => { push = null } }, [])
  if (!req) return null
  const done = (v) => { req.resolve(v); setReq(null) }
  const [title, ...rest] = req.message.split('\n')
  return <div className="sheet-bg confirm-layer" onClick={() => done(false)}>
    <div className="action-sheet" onClick={(e) => e.stopPropagation()} role="alertdialog" aria-label={title}>
      <div className="as-group">
        <div className="as-msg"><b>{title}</b>{rest.length > 0 && <span>{rest.join(' ')}</span>}</div>
        <button className={`as-btn ${req.danger ? 'danger' : ''}`} onClick={() => done(true)} autoFocus>{req.ok}</button>
      </div>
      <button className="as-btn as-cancel" onClick={() => done(false)}>{req.cancel}</button>
    </div>
  </div>
}
