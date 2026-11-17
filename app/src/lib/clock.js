// 서버 시각 보정 — 폰 시계가 틀려도 타이머가 맞도록 hq_view 응답의 server_now 로 오프셋을 잡는다.
let offset = 0
export const noteServerTime = (iso) => { const t = Date.parse(iso); if (Number.isFinite(t)) offset = t - Date.now() }
export const serverNow = () => Date.now() + offset
