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
export const errText = (m) => ERR[Object.keys(ERR).find((k) => m?.includes(k))] ?? (/fetch|network|load failed|timeout/i.test(m ?? '') ? '연결이 잠깐 끊겼어요. 다시 눌러 주세요' : '처리 중 문제가 생겼어요')

// 닉네임 주사위: 조합형은 어색해서, 회식 자리에서 웃길 만한 완성형만 골라 둔다(12자 이내).
const NICKS = [
  '검토해 보겠습니다', '긍정적으로 검토 중', '일단 킵하시죠', '다음 주에 다시 봅시다', 'ASAP 수신자',
  '참조로만 사는 사람', '회의록 안 읽은 자', '컨펌 대기 중', '읽씹 장인', '퇴근 5분 전',
  '월요병 말기', '연차 소진 장인', '주 52시간 수호자', '법카의 수호자', '점심 메뉴 결정권자',
  '1차만 하고 갑니다', '2차는 제가 쏩니다', '막차 사수대', '숙취는 내일의 몫', '소맥 비율 연구소장',
  '건배사 준비 안 함', '노래방 예약 담당', '오늘은 안 취함', '사실 정답 앎', '찍기의 신',
  '감으로 푸는 사람', 'PC방 고인물', '도토리 부자', '삐삐 세대 대표', '2002의 함성',
]
export const randomNick = (prev) => {
  let n
  do n = NICKS[Math.floor(Math.random() * NICKS.length)]; while (n === prev && NICKS.length > 1)
  return n
}

export const fmt = (n) => (n ?? 0).toLocaleString('ko-KR')
