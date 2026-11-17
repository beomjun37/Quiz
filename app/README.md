# 🍻 한잔 퀴즈 — 부서 회식용 실시간 퀴즈

20~100명. 테이블 = 팀. 글쓰기 없이 터치만. R1 추억 소환 → R2 부장님 마음 맞히기 → R3 올인 베팅 → 행운의 추첨.

| 화면 | 주소 | 누가 |
|---|---|---|
| 참가자 | `…/Quiz/` | 모두의 폰 (스크린 QR) |
| 스크린 | `…/Quiz/#/screen` | TV·빔프로젝터 |
| 진행자 | `…/Quiz/#/admin` | 진행자 (PIN, 임시 1234) |

## 행사 전 체크
1. 진행자 화면 → 테이블 수 선택 → [리허설] 100명 채우기로 한 바퀴 → **전체 초기화**
2. [문항 편집] 불러오기 → 부서 문항으로 수정 → 저장 (대기 단계에서만 가능)
3. PIN 변경 (Supabase SQL Editor):
   `update hq_config set pin_hash = extensions.crypt('새PIN', extensions.gen_salt('bf'));`
4. 행사 후 **전체 초기화** = 참가자 이름·점수 삭제

## 구조
- 프론트: React + Vite, GitHub Pages (`main` 푸시 시 자동 배포)
- 백엔드: Supabase. 테이블은 전부 `hq_` 접두어. 채점·마감·베팅·추첨은 서버 RPC 에서만.
- 동기화: `hq_state` Realtime + 2~3초 폴링 + 화면 복귀 시 재구독
- DB 설치/갱신: `db/ALL_IN_ONE.sql` 을 SQL Editor 에서 실행 (재실행 안전, 단 예시 문항으로 덮어씀)

## 로컬
```
npm install && npm run dev   # http://localhost:5173/Quiz/
```
