import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY
if (!url || !key) throw new Error('.env 에 VITE_SUPABASE_URL 과 VITE_SUPABASE_PUBLISHABLE_KEY 가 필요합니다.')

export const supabase = createClient(url, key, {
  auth: { persistSession: false }, // Supabase Auth 미사용. 참가자는 이름 + 테이블 번호로만 들어온다.
  realtime: { params: { eventsPerSecond: 10 } },
})

/** RPC 호출. 에러 메시지(BAD_PIN, TOO_LATE 등)를 그대로 던진다. */
export async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args)
  if (error) throw new Error(error.message)
  return data
}
