# 아키텍처 상세

## 테이블 (공개 여부)
- state(1행, 공개 읽기): phase(lobby|q|answer|final|draw…), qi, q_started_at, end_msg, end_credits
- players(비공개): name, score, streak, max_streak, prev_* 스냅샷(정답 공개 되돌리기용), is_bot
- questions(비공개): idx, round, type(ox|mc|poll|survey|minority), q, opts jsonb, answer, note, host(진행자 멘트), limit_sec, media, reveal, pinned
- answers, bets, reactions, images(data URL), audio(WAV data URL), draw(winner_ids), bank, config(pin_hash, fails, locked_until)

## RPC
- 참가자: join(name)→id 반환, answer(id,qi,choice), card(찬스카드), react, leave, view(id) — 화면에 필요한 것만 담은 JSON 한 덩어리.
- 진행자: admin(pin, action, arg). action: check, next, back, skip, goto, draw, restart, reset, bots, questions, questions_get, compose(은행에서 랜덤 세트), bank_*, image/audio 업로드·조회, end_msg, set_pin.
- 정답·노래 검색어처럼 답이 새는 값은 view에 싣지 말고 admin current로만.

## 유형별 채점
- ox/mc: 정답 + 빠를수록 보너스 + 연속 정답 보너스.
- survey(다수결)/minority(소수결): 정답 없음, 공개 시점 응답 분포로 정답 결정.
- poll: 점수 없음.
- 사진 연출: zoom(초점 좌표에서 축소), blur, pixel, silhouette — 시간 경과에 따라 CSS로 풀린다.
