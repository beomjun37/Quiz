import { useEffect, useState } from 'react'
import { RefreshCw } from 'lucide-react'

/* global __BUILD__ */
// 새 버전이 배포됐는지 1분마다 확인(캐시 무시). 바뀌었으면 화면 위에 새로고침 안내를 띄운다.
export function UpdateBanner() {
  const [stale, setStale] = useState(false)
  useEffect(() => {
    const check = async () => {
      try {
        const r = await fetch(`${import.meta.env.BASE_URL}version.json?t=${Date.now()}`, { cache: 'no-store' })
        if (!r.ok) return
        const { build } = await r.json()
        if (build && build !== __BUILD__) setStale(true)
      } catch { /* 오프라인 등은 무시 */ }
    }
    check()
    const t = setInterval(check, 60000)
    const vis = () => { if (document.visibilityState === 'visible') check() }
    document.addEventListener('visibilitychange', vis)
    return () => { clearInterval(t); document.removeEventListener('visibilitychange', vis) }
  }, [])
  if (!stale) return null
  return <button className="update-banner" onClick={() => location.reload()}>
    <RefreshCw size={18} />새 버전이 있어요 · 눌러서 새로고침
  </button>
}
