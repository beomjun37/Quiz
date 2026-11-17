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
  BAD_PIN: 'PIN이 틀렸어요',
  ONLY_IN_LOBBY: '문항은 시작 전(대기 단계)에만 바꿀 수 있어요',
}
export const errText = (m) => ERR[Object.keys(ERR).find((k) => m?.includes(k))] ?? '연결이 잠깐 끊겼어요. 다시 눌러 주세요'

// 닉네임 주사위 — 입력이 귀찮은 사람용
const A = ['소맥', '삼겹살', '노래방', '칼퇴', '골뱅이', '건배사', '야근', '엑셀', '등산', '낚시', '막걸리', '치맥']
const B = ['황제', '장인', '요정', '킬러', '달인', '반장', '고수', '대장', '마스터', '전설']
export const randomNick = () => A[Math.floor(Math.random() * A.length)] + B[Math.floor(Math.random() * B.length)]

export const fmt = (n) => (n ?? 0).toLocaleString('ko-KR')
