# 테스트와 배포

## 로컬 RPC 테스트
- Postgres 16을 로컬에 띄우고 SQL 파일을 그대로 적용(Supabase 전용 객체는 조건부로 감싸 두면 로컬에서도 돈다).
- Playwright에서 `context.route(/supabase\.co/)`로 RPC 호출을 가로채 psql로 실행해 응답. 큰 인자는 커맨드 라인이 아니라 stdin으로 넘긴다.
- bots 액션으로 가짜 참가자 N명을 넣고 next를 반복해 한 판 끝까지 검증.
- 폰 크기 스크린샷 여러 장을 PIL로 가로로 이어 붙여 한 번에 확인.

## 원격 DB 적용
- Supabase Management API `/v1/projects/<ref>/database/query`로 SQL 실행(토큰은 환경 자격증명으로). 시드는 빼고 스키마+RPC+은행만 적용해 운영 중 세트를 덮지 않는다.
- 적용 전 UPDATE/DELETE에 WHERE가 있는지 스크립트로 검사.

## 배포
- 작업 브랜치 → PR → main 머지 → GitHub Actions가 Pages로 배포. vite base는 저장소 이름(`/Quiz/`).
- index.html no-cache 메타 + version.json 업데이트 배너.
- 브라우저에서 못 하는 확인(유튜브, 실제 폰 소리)은 사용자에게 체크리스트로 넘긴다.
