import { useEffect, useState } from 'react'

// 업무 위장 테마: 참가자 폰 화면을 엑셀 / VS Code 처럼 보이게 한다.
// 고른 테마는 이 폰에 기억하고, 주소에 ?skin=excel 처럼 붙여서 열어도 된다.
const SKINS = ['', 'excel', 'vscode']
const LABEL = { '': '기본', excel: '엑셀', vscode: 'VS Code' }

function initial() {
  try {
    const q = new URLSearchParams(location.search).get('skin') ?? new URLSearchParams(location.hash.split('?')[1] ?? '').get('skin')
    if (q != null && SKINS.includes(q)) return q
    return localStorage.getItem('hq-skin') ?? ''
  } catch { return '' }
}

export function useSkin() {
  const [skin, setSkinState] = useState(initial)
  useEffect(() => {
    const el = document.documentElement
    if (skin) el.dataset.skin = skin; else delete el.dataset.skin
    try { localStorage.setItem('hq-skin', skin) } catch { /* noop */ }
    return () => { delete el.dataset.skin }
  }, [skin])
  return [skin, setSkinState]
}

const next = (s) => SKINS[(SKINS.indexOf(s) + 1) % SKINS.length]

// 화면 위·아래 가짜 프로그램 테두리. 제목줄을 누르면 테마가 바뀐다.
export function SkinChrome({ skin, setSkin, children }) {
  if (!skin) return <>
    <button className="skin-pill" onClick={() => setSkin('excel')} aria-label="업무 모드로 바꾸기">업무 모드</button>
    {children}
  </>
  if (skin === 'excel') return <div className="skin-frame">
    <div className="xl-title" onClick={() => setSkin(next(skin))} role="button" aria-label="테마 바꾸기">
      <span className="xl-logo">X</span><span className="xl-file">2026_예산안_최종_v3.xlsx</span><span className="xl-mode">{LABEL[next(skin)]} ▸</span>
    </div>
    <div className="xl-ribbon">{['파일', '홈', '삽입', '수식', '데이터', '검토'].map((t, i) => <span key={t} className={i === 1 ? 'on' : ''}>{t}</span>)}</div>
    <div className="xl-formula"><span className="xl-cell">B7</span><span className="xl-fx">fx</span><span className="xl-input">=SUMIFS(실적!D:D, 실적!A:A, "4분기")</span></div>
    <div className="xl-cols"><span /> {['A', 'B', 'C', 'D', 'E'].map((c) => <span key={c}>{c}</span>)}</div>
    <div className="skin-body xl-body">{children}</div>
    <div className="xl-sheets"><span className="on">4분기 실적</span><span>예산</span><span>Sheet1</span><b>준비</b></div>
  </div>
  return <div className="skin-frame">
    <div className="vs-title" onClick={() => setSkin(next(skin))} role="button" aria-label="테마 바꾸기">
      <span className="vs-dots"><i /><i /><i /></span><span className="vs-file">report-service — Visual Studio Code</span><span className="vs-mode">{LABEL[next(skin)]} ▸</span>
    </div>
    <div className="vs-tabs"><span className="on">QuarterlyReport.tsx</span><span>api.ts</span><span>README.md</span></div>
    <div className="vs-crumb">src › reports › QuarterlyReport.tsx</div>
    <div className="skin-body vs-body">{children}</div>
    <div className="vs-status"><span>⎇ main</span><span>⊗ 0 ⚠ 0</span><span className="r">Ln 42, Col 7 · UTF-8 · TypeScript React</span></div>
  </div>
}
