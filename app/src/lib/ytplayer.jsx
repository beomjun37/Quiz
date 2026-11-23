import { useEffect, useRef, useState } from 'react'
import { FastForward, Music, Rewind, Save, Square, Zap } from 'lucide-react'
import { parseYouTube } from './ui'

// 유튜브 IFrame API 를 한 번만 불러온다
let apiPromise = null
function loadYT() {
  if (window.YT?.Player) return Promise.resolve(window.YT)
  apiPromise ??= new Promise((resolve) => {
    const prev = window.onYouTubeIframeAPIReady
    window.onYouTubeIframeAPIReady = () => { prev?.(); resolve(window.YT) }
    const s = document.createElement('script'); s.src = 'https://www.youtube.com/iframe_api'; document.head.appendChild(s)
  })
  return apiPromise
}

const fmt = (t) => `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, '0')}`

/**
 * 진행자 폰의 노래 플레이어.
 * - 미리 준비: 소리를 끈 채 먼저 틀어 광고를 이때 넘기고, 시작 지점에서 멈춰 둔다
 * - 재생: 시작 지점부터 len 초 재생 후 자동 정지
 * - 시작 지점 맞추기: 재생하며 ±5초로 후렴을 찾고 "여기부터 시작"으로 저장(onSaveStart)
 */
export default function YTPlayer({ media, len = 15, onSaveStart, compact = false, title = '' }) {
  const yt = parseYouTube(media)
  const box = useRef(null), player = useRef(null), stopAt = useRef(null)
  const [state, setState] = useState('idle')   // idle | preparing | ready | playing
  const [now, setNow] = useState(0)
  const [start, setStart] = useState(yt?.start ?? 0)
  const [saved, setSaved] = useState(false)
  const stateRef = useRef(state); stateRef.current = state

  useEffect(() => () => { try { player.current?.destroy() } catch { /* noop */ } }, [])
  useEffect(() => {
    const t = setInterval(() => {
      const p = player.current; if (!p?.getCurrentTime) return
      const c = p.getCurrentTime() || 0; setNow(c)
      if (stopAt.current != null && c >= stopAt.current) { p.pauseVideo(); stopAt.current = null; setState('ready') }
    }, 250)
    return () => clearInterval(t)
  }, [])
  if (!yt) return null

  async function ensure(muted) {
    if (player.current) return player.current
    const YT = await loadYT()
    return new Promise((resolve) => {
      player.current = new YT.Player(box.current, {
        videoId: yt.id, width: '100%', height: '100%',
        playerVars: { playsinline: 1, rel: 0, modestbranding: 1, start },
        events: {
          // 100 삭제·비공개, 101/150 퍼가기 금지, 2/5 잘못된 링크·재생 오류
          onError: () => setState('error'),
          onReady: (e) => { if (muted) e.target.mute(); resolve(e.target) },
          onStateChange: (e) => {
            // 준비 중: 광고가 끝나고 본 영상이 재생되기 시작하면 시작 지점에서 멈춰 둔다
            if (e.data === 1 && stateRef.current === 'preparing') { e.target.pauseVideo(); e.target.seekTo(start, true); e.target.unMute(); setState('ready') }
          },
        },
      })
    })
  }

  async function prepare() { setState('preparing'); const p = await ensure(true); p.mute(); p.playVideo() }
  async function play() {
    const p = await ensure(false)
    p.unMute(); p.seekTo(start, true); p.playVideo(); stopAt.current = start + len; setState('playing')
  }
  function stop() { player.current?.pauseVideo(); stopAt.current = null; setState('ready') }
  function nudge(d) { const p = player.current; if (!p) return; const t = Math.max(0, (p.getCurrentTime() || 0) + d); p.seekTo(t, true); if (stopAt.current != null) stopAt.current = t + len }
  function setHere() { const t = Math.floor(player.current?.getCurrentTime?.() || 0); setStart(t); setSaved(false) }

  const search = `https://www.youtube.com/results?search_query=${encodeURIComponent((title.replace(/[「」()0-9]/g, ' ') || '') + ' 노래')}`
  if (state === 'error') return <div className="song">
    <div className="notice bad"><span>이 영상은 재생할 수 없어요(비공개·삭제·퍼가기 금지). 유튜브에서 같은 노래를 찾아 틀거나, 문제를 건너뛰어 주세요.</span></div>
    <a className="song-alt" href={search} target="_blank" rel="noreferrer">유튜브에서 이 노래 검색</a>
  </div>
  return <div className="song">
    <div className="song-frame"><div ref={box} /></div>
    <div className="song-row">
      {state === 'playing'
        ? <button className="music-btn" onClick={stop}><Square size={20} /><span>정지<small className="num">{fmt(now)} · {fmt(start)}부터 {len}초</small></span></button>
        : <button className="music-btn" onClick={play}><Music size={22} /><span>노래 바로 재생<small className="num">{fmt(start)}부터 {len}초</small></span></button>}
      {state === 'idle' && !compact && <button className="ghost prep" onClick={prepare}><Zap size={16} />광고 먼저 넘기기</button>}
      {state === 'preparing' && <span className="prep-note">준비 중… 광고가 나오면 '건너뛰기'를 눌러 주세요</span>}
      {state === 'ready' && <span className="prep-note ok">준비 완료 · 바로 재생돼요</span>}
    </div>
    <div className="song-tools">
      <button className="ghost" onClick={() => nudge(-5)} aria-label="5초 뒤로"><Rewind size={16} />5초</button>
      <button className="ghost" onClick={() => nudge(10)} aria-label="10초 앞으로"><FastForward size={16} />10초</button>
      {onSaveStart && <>
        <button className="ghost" onClick={setHere}>지금 지점({fmt(now)})을 시작으로</button>
        {start !== (yt.start ?? 0) && !saved && <button className="ghost save" onClick={async () => { await onSaveStart(start); setSaved(true) }}><Save size={15} />{fmt(start)}부터로 저장</button>}
        {saved && <span className="prep-note ok">저장했어요</span>}
      </>}
    </div>
    <a className="song-alt" href={`https://www.youtube.com/watch?v=${yt.id}&t=${start}s`} target="_blank" rel="noreferrer">영상이 안 나오면 유튜브 앱에서 열기</a>
  </div>
}

// 유튜브 링크의 시작 시각만 바꾼 새 링크
export function withStart(media, sec) {
  const yt = parseYouTube(media); if (!yt) return media
  return `https://youtu.be/${yt.id}?t=${Math.max(0, Math.floor(sec))}`
}
