import { useCallback, useEffect, useRef, useState } from 'react'
import { rpc, supabase } from './supabase'
import { noteServerTime, serverNow } from './clock'

/**
 * 모든 화면의 데이터 소스. 원본 워크샵 앱과 같은 3중 안전망:
 *  1) hq_state Realtime 구독 → 진행자가 단계를 넘기면 1초 안에 재조회
 *  2) 폴링 (소켓이 조용히 죽는 LTE 환경 대비)
 *  3) 화면 복귀·온라인 복귀 시 재조회 + 재구독
 */
export function useView(playerId, pollMs = 3000) {
  const [view, setView] = useState(null)
  const [error, setError] = useState(null)
  const idRef = useRef(playerId)
  idRef.current = playerId

  const refetch = useCallback(async () => {
    try {
      const asked = idRef.current ?? null
      const v = await rpc('hq_view', { p_player: asked })
      noteServerTime(v.server_now)
      if (asked !== (idRef.current ?? null)) return // 그 사이 입장/퇴장했으면 낡은 응답은 버린다
      v._for = asked
      setView(v); setError(null)
      return v
    } catch (e) { setError(e.message) }
  }, [])

  useEffect(() => { refetch() }, [playerId, refetch])

  useEffect(() => {
    let channel = null, dead = false
    const connect = () => {
      if (channel) supabase.removeChannel(channel)
      channel = supabase.channel(`hq_state:${crypto.randomUUID()}`)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'hq_state' }, () => { if (!dead) refetch() })
        .subscribe()
    }
    connect()
    const resync = () => { if (document.visibilityState === 'visible') { refetch(); connect() } }
    document.addEventListener('visibilitychange', resync)
    addEventListener('online', resync); addEventListener('focus', resync)
    const t = setInterval(() => { if (document.visibilityState === 'visible') refetch() }, pollMs)
    return () => {
      dead = true; clearInterval(t)
      document.removeEventListener('visibilitychange', resync)
      removeEventListener('online', resync); removeEventListener('focus', resync)
      if (channel) supabase.removeChannel(channel)
    }
  }, [refetch, pollMs])

  return { view, error, refetch }
}

/** 남은 초 (서버 시각 기준). 250ms 마다 갱신. */
export function useCountdown(startIso, limit) {
  const calc = () => (startIso ? Math.max(0, limit - (serverNow() - Date.parse(startIso)) / 1000) : 0)
  const [left, setLeft] = useState(calc)
  useEffect(() => { setLeft(calc()); const t = setInterval(() => setLeft(calc()), 250); return () => clearInterval(t) }, [startIso, limit]) // eslint-disable-line
  return left
}
