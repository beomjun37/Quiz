// 진행자가 고른 음원 파일에서 start 초부터 dur 초만 잘라 작은 WAV(모노 22kHz)로 만든다.
// 전부 브라우저 안에서 처리하고, 원본 파일은 어디에도 올리지 않는다. 20초면 약 0.9MB.
export async function makeClip(file, start = 0, dur = 20) {
  const buf = await file.arrayBuffer()
  const AC = window.AudioContext || window.webkitAudioContext
  const ctx = new AC()
  const src = await ctx.decodeAudioData(buf)
  ctx.close?.()
  const s = Math.max(0, Math.min(start, Math.max(0, src.duration - 1)))
  const len = Math.min(dur, src.duration - s)
  const rate = 22050
  const off = new OfflineAudioContext(1, Math.ceil(len * rate), rate)
  const node = off.createBufferSource()
  node.buffer = src
  // 앞뒤 0.3초 페이드(뚝 끊기지 않게)
  const g = off.createGain()
  g.gain.setValueAtTime(0, 0); g.gain.linearRampToValueAtTime(1, 0.3)
  g.gain.setValueAtTime(1, Math.max(0.3, len - 0.3)); g.gain.linearRampToValueAtTime(0, len)
  node.connect(g).connect(off.destination)
  node.start(0, s, len)
  const out = await off.startRendering()
  return { data: toWavDataUrl(out.getChannelData(0), rate), seconds: Math.round(len) }
}

function toWavDataUrl(samples, rate) {
  const n = samples.length, bytes = new DataView(new ArrayBuffer(44 + n * 2))
  const w = (o, str) => { for (let i = 0; i < str.length; i++) bytes.setUint8(o + i, str.charCodeAt(i)) }
  w(0, 'RIFF'); bytes.setUint32(4, 36 + n * 2, true); w(8, 'WAVE'); w(12, 'fmt ')
  bytes.setUint32(16, 16, true); bytes.setUint16(20, 1, true); bytes.setUint16(22, 1, true)
  bytes.setUint32(24, rate, true); bytes.setUint32(28, rate * 2, true); bytes.setUint16(32, 2, true); bytes.setUint16(34, 16, true)
  w(36, 'data'); bytes.setUint32(40, n * 2, true)
  for (let i = 0; i < n; i++) { const v = Math.max(-1, Math.min(1, samples[i])); bytes.setInt16(44 + i * 2, v < 0 ? v * 0x8000 : v * 0x7fff, true) }
  let bin = ''; const u8 = new Uint8Array(bytes.buffer)
  for (let i = 0; i < u8.length; i += 0x8000) bin += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000))
  return 'data:audio/wav;base64,' + btoa(bin)
}
