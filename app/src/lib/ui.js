export const OPT_COLORS = ['var(--c1)', 'var(--c2)', 'var(--c3)', 'var(--c4)']
const DARK = [false, false, true, true] // 앰버·초록 위엔 어두운 글자(대비 확보)

/** 선택지 목록: [표시글, 키, 배경, 어두운글자여부] */
export function options(q) {
  if (q.type === 'ox') return [['O', 'O', 'var(--o)', false], ['X', 'X', 'var(--x)', false]]
  return q.opts.map((o, i) => [o, String(i + 1), OPT_COLORS[i], DARK[i]])
}

export const ERR = {
  NAME_TAKEN: '이미 있는 닉네임이에요. 다른 걸로 해볼까요?',
  BAD_NAME: '닉네임을 1~12자로 적어 주세요',
  TOO_LATE: '시간이 지났어요',
  NOT_OPEN: '지금은 답을 낼 수 없어요',
  NO_PLAYER: '다시 입장해 주세요',
  CARD_USED: '찬스 카드는 한 게임에 한 장만 쓸 수 있어요',
  CARD_NOT_NOW: '이 문제에서는 그 카드를 쓸 수 없어요',
  IMAGE_TOO_BIG: '사진이 너무 커요. 다른 사진을 골라 주세요',
  BAD_NEW_PIN: 'PIN은 4~12자리로 정해 주세요',
  NOT_LOBBY: '게임이 시작된 뒤에는 닉네임을 바꿀 수 없어요',
  BAD_PIN: 'PIN이 틀렸어요',
  ONLY_IN_LOBBY: '문항은 시작 전(대기 단계)에만 바꿀 수 있어요',
}
export const errText = (m) => ERR[Object.keys(ERR).find((k) => m?.includes(k))] ?? (/fetch|network|load failed|timeout/i.test(m ?? '') ? '연결이 잠깐 끊겼어요. 다시 눌러 주세요' : '처리 중 문제가 생겼어요')

// 닉네임 주사위: 조합형은 어색해서, 회식 자리에서 웃길 만한 완성형만 골라 둔다(12자 이내).
const NICKS = [
  '검토해 보겠습니다', '긍정적으로 검토 중', '일단 킵하시죠', '다음 주에 다시 봅시다', 'ASAP 수신자',
  '참조로만 사는 사람', '회의록 안 읽은 자', '컨펌 대기 중', '읽씹 장인', '퇴근 5분 전',
  '월요병 말기', '연차 소진 장인', '주 52시간 수호자', '법카의 수호자', '점심 메뉴 결정권자',
  '칼퇴 요정', '오늘 안주 담당', '막차 사수대', '숙취는 내일의 몫', '소맥 비율 연구소장',
  '건배사 준비 안 함', '노래방 예약 담당', '오늘은 안 취함', '사실 정답 앎', '찍기의 신',
  '감으로 푸는 사람', 'PC방 고인물', '도토리 부자', '삐삐 세대 대표', '2002의 함성',
]
export const randomNick = (prev) => {
  let n
  do n = NICKS[Math.floor(Math.random() * NICKS.length)]; while (n === prev && NICKS.length > 1)
  return n
}

export const fmt = (n) => (n ?? 0).toLocaleString('ko-KR')

export const REACT_EMOJI = { clap: '👏', lol: '😂', beer: '🍺', fire: '🔥' }

// 가장 많이 고른 오답이 20% 이상이면 "오늘의 함정"
export function trap(q, dist) {
  if (!dist || q.answer == null) return null
  const total = dist.reduce((a, b) => a + b, 0)
  let best = -1
  dist.forEach((n, i) => { if (i !== q.answer && (best < 0 || n > dist[best])) best = i })
  if (best < 0 || total === 0 || dist[best] / total < 0.2) return null
  return { label: options(q)[best][0], n: dist[best] }
}

// 사진 연출 값: 'zoom', 'zoom@0.35,0.53'(확대 시작 위치), 'blur', 'pixel', 'silhouette'
export function revealOf(q) {
  const [mode = '', at] = String(q?.reveal ?? '').split('@')
  const [x, y] = (at ?? '0.5,0.5').split(',').map(Number)
  return { mode, x: Number.isFinite(x) ? x : 0.5, y: Number.isFinite(y) ? y : 0.5 }
}
