-- 예시 문항. 실제 행사 전에는 관리자 화면 [문항] 탭에서 바꾼다.
delete from hq_questions;
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet) values (0,'R1 추억 소환','ox','2002 월드컵에서 한국은 4강에 올랐다.','[]'::jsonb,0,'4강 신화! 그날 어디서 보셨어요?',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet) values (1,'R1 추억 소환','mc','스타크래프트에서 "Show me the money"를 치면?','["유닛 무적", "자원 1만", "맵 전체 보기", "건설 즉시 완료"]'::jsonb,1,'PC방 시간당 1,000원이던 시절',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet) values (2,'R1 추억 소환','mc','삐삐 숫자 "8282"의 뜻은?','["사랑해", "빨리빨리", "잘자", "보고싶어"]'::jsonb,1,'"1004"는 천사, "486"은 사랑해',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet) values (3,'R1 추억 소환','ox','싸이월드 화폐 이름은 "도토리"였다.','[]'::jsonb,0,'BGM 사려고 도토리 충전하셨죠?',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet) values (4,'R2 부장님 마음 맞히기','mc','부장님 최애 회식 안주는?','["삼겹살", "회", "치킨", "골뱅이"]'::jsonb,0,'부장님 한 말씀 부탁드립니다!',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet) values (5,'R2 부장님 마음 맞히기','mc','부장님 노래방 18번은 몇 년대 노래?','["80년대", "90년대", "2000년대", "최신곡"]'::jsonb,1,'2차 노래방에서 검증 예정',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet) values (6,'R3 올인 베팅','mc','1997년 IMF 때 국민이 모은 금은 약 몇 톤?','["약 50톤", "약 120톤", "약 227톤", "약 500톤"]'::jsonb,2,'약 350만 명 참여',true);
