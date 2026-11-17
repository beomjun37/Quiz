export const OPT_COLORS = ['var(--c1)', 'var(--c2)', 'var(--c3)', 'var(--c4)']
export const OX = [['O', 'var(--o)'], ['X', 'var(--x)']]
export function options(q) {
  return q.type === 'ox' ? OX : q.opts.map((o, i) => [`${i + 1}. ${o}`, OPT_COLORS[i]])
}
export const ERR = {
  BAD_NAME: '이름을 1~12자로 입력해 주세요', BAD_TABLE: '테이블 번호를 다시 골라 주세요',
  TOO_LATE: '시간이 지났어요', NOT_OPEN: '지금은 제출할 수 없어요', NO_PLAYER: '다시 입장해 주세요',
  BAD_PIN: 'PIN 이 틀렸어요', ONLY_IN_LOBBY: '문항은 시작 전(대기 단계)에만 바꿀 수 있어요',
}
export const errText = (m) => ERR[Object.keys(ERR).find((k) => m?.includes(k))] ?? m
