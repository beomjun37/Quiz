// 효과음·진동. 브라우저는 사용자가 한 번 터치한 뒤에야 소리를 허락하므로 첫 터치 때 unlock 한다.
let ctx = null
export function unlockAudio() {
  try {
    ctx ??= new (window.AudioContext || window.webkitAudioContext)()
    if (ctx.state === 'suspended') ctx.resume()
  } catch { /* 지원 안 하는 브라우저 */ }
}
function tone(freq, start, dur, type = 'sine', gain = 0.18) {
  if (!ctx) return
  const o = ctx.createOscillator(), g = ctx.createGain()
  o.type = type; o.frequency.value = freq
  g.gain.setValueAtTime(0, ctx.currentTime + start)
  g.gain.linearRampToValueAtTime(gain, ctx.currentTime + start + 0.01)
  g.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + start + dur)
  o.connect(g).connect(ctx.destination)
  o.start(ctx.currentTime + start); o.stop(ctx.currentTime + start + dur + 0.05)
}
const vibrate = (p) => { try { navigator.vibrate?.(p) } catch { /* iOS 미지원 */ } }
export const fx = {
  correct() { tone(660, 0, 0.15); tone(880, 0.12, 0.25); vibrate(60) },
  wrong() { tone(196, 0, 0.35, 'triangle', 0.22); vibrate([80, 60, 80]) },
  tick() { tone(1200, 0, 0.05, 'square', 0.05) },
  fanfare() { [523, 659, 784, 1047].forEach((f, i) => tone(f, i * 0.12, 0.3)); vibrate([60, 40, 60, 40, 200]) },
}
