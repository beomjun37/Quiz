import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY
if (!url || !key) throw new Error('.env 에 VITE_SUPABASE_URL 과 VITE_SUPABASE_PUBLISHABLE_KEY 가 필요합니다.')

export const supabase = createClient(url, key, {
  auth: { persistSession: false }, // Supabase Auth 미사용. 참가자는 이름 + 테이블 번호로만 들어온다.
  realtime: { params: { eventsPerSecond: 10 } },
})

const NETWORK = /fetch|network|load failed|timeout|aborted|connection/i

/**
 * RPC 호출. 서버가 거절한 에러(BAD_PIN, TOO_LATE 등)는 그대로 던지고,
 * 통신이 끊긴 경우(탭 전환, 와이파이·5G 순간 끊김)는 최대 4번까지 다시 보낸다.
 * 다시 보내도 안전하도록 서버 쪽 동작은 전부 중복 실행에 안전하게 만들어 뒀다.
 */
export async function rpc(fn, args, { retry = true } = {}) {
  let last
  for (let i = 0; i < (retry ? 4 : 1); i++) {
    if (i) await new Promise((r) => setTimeout(r, 400 * 2 ** (i - 1)))
    try {
      const { data, error } = await supabase.rpc(fn, args)
      if (!error) {
        // 서버가 예외 대신 { ok: false, error } 로 거절한 경우(예: PIN 실패 횟수 기록)
        if (data && data.ok === false && data.error) throw new Error(data.error)
        return data
      }
      if (!NETWORK.test(error.message) || error.code) throw new Error(error.message)
      last = new Error(error.message)
    } catch (e) {
      if (!NETWORK.test(e.message)) throw e
      last = e
    }
  }
  throw last
}
