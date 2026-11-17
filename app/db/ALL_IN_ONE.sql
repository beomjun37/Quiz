-- 한잔 퀴즈 — 스키마. 기존 프로젝트와 섞여도 안전하도록 모든 객체에 hq_ 접두어.
-- 재실행하려면 맨 아래 주석의 drop 문을 먼저 실행한다.
create extension if not exists pgcrypto;

create table if not exists hq_state (
  id int primary key default 1 check (id = 1),
  phase text not null default 'lobby',          -- lobby | bet | q | answer | final | draw
  qi int not null default -1,                   -- 현재 문항 index (0부터)
  q_started_at timestamptz,
  tables int not null default 6 check (tables between 2 and 20),
  winner_id uuid,
  drawn_at timestamptz,
  updated_at timestamptz not null default now()
);
insert into hq_state (id) values (1) on conflict do nothing;

create table if not exists hq_players (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 12),
  table_no int not null,
  score int not null default 0,
  active boolean not null default false,        -- 1문항 이상 응답 → 팀 평균 분모에 포함
  is_bot boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists hq_questions (
  idx int primary key,
  round text not null,
  type text not null check (type in ('ox','mc')),
  q text not null,
  opts jsonb not null default '[]',
  answer int not null,
  note text not null default '',
  is_bet boolean not null default false,
  limit_sec int not null default 15
);

create table if not exists hq_answers (
  player_id uuid references hq_players(id) on delete cascade,
  qi int not null,
  choice int not null,
  at timestamptz not null default now(),
  primary key (player_id, qi)
);

create table if not exists hq_bets (
  player_id uuid primary key references hq_players(id) on delete cascade,
  pct int not null check (pct in (0,50,100))
);

create table if not exists hq_config (
  id int primary key default 1 check (id = 1),
  pin_hash text not null
);

-- RLS: 상태·참가자(이름/테이블/점수)만 공개 읽기. 정답·응답·베팅·PIN 은 전면 차단(RPC 로만 접근).
alter table hq_state enable row level security;
alter table hq_players enable row level security;
alter table hq_questions enable row level security;
alter table hq_answers enable row level security;
alter table hq_bets enable row level security;
alter table hq_config enable row level security;
drop policy if exists hq_state_read on hq_state;
create policy hq_state_read on hq_state for select using (true);
drop policy if exists hq_players_read on hq_players;
create policy hq_players_read on hq_players for select using (true);

-- Realtime: hq_state 한 행만 구독하면 된다.
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table hq_state; exception when duplicate_object then null; end;
  end if;
end $$;

-- 관리자 PIN 설정 (배포 직후 반드시 바꾼다):
--   insert into hq_config (id, pin_hash) values (1, crypt('1234', gen_salt('bf')))
--   on conflict (id) do update set pin_hash = excluded.pin_hash;

-- 전체 삭제:
--   drop table if exists hq_bets, hq_answers, hq_questions, hq_players, hq_state, hq_config cascade;
-- 한잔 퀴즈 — RPC. 전부 create or replace 라 여러 번 실행해도 안전하다.
-- 채점·마감·추첨은 전부 서버에서 한다. 클라이언트는 보여주기만 한다.

-- 점수: 정답이면 500 + 남은시간 비율 × 500 (빨리 맞힐수록 최대 1000)
create or replace function hq_points(p_correct boolean, p_started timestamptz, p_at timestamptz, p_limit int)
returns int language sql immutable as $$
  select case when not p_correct then 0
    else round(500 + 500 * greatest(0, p_limit - extract(epoch from (p_at - p_started))) / p_limit)::int end
$$;

-- 참가 ----------------------------------------------------------------
create or replace function hq_join(p_name text, p_table int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s hq_state; r hq_players;
begin
  select * into s from hq_state where id = 1;
  p_name := btrim(coalesce(p_name, ''));
  if char_length(p_name) < 1 or char_length(p_name) > 12 then raise exception 'BAD_NAME'; end if;
  if p_table < 1 or p_table > s.tables then raise exception 'BAD_TABLE'; end if;
  insert into hq_players (name, table_no) values (p_name, p_table) returning * into r;
  return to_jsonb(r);
end $$;

create or replace function hq_answer(p_player uuid, p_choice int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s hq_state; q hq_questions;
begin
  select * into s from hq_state where id = 1;
  if s.phase <> 'q' then raise exception 'NOT_OPEN'; end if;
  select * into q from hq_questions where idx = s.qi;
  if not exists (select 1 from hq_players where id = p_player) then raise exception 'NO_PLAYER'; end if;
  if p_choice < 0 or p_choice >= (case when q.type = 'ox' then 2 else jsonb_array_length(q.opts) end) then raise exception 'BAD_CHOICE'; end if;
  if now() > s.q_started_at + make_interval(secs => q.limit_sec + 2) then raise exception 'TOO_LATE'; end if;
  insert into hq_answers (player_id, qi, choice) values (p_player, s.qi, p_choice) on conflict do nothing;  -- 한 번 내면 못 바꾼다
  return jsonb_build_object('ok', true);
end $$;

create or replace function hq_bet(p_player uuid, p_pct int)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if (select phase from hq_state where id = 1) <> 'bet' then raise exception 'NOT_BET'; end if;
  insert into hq_bets (player_id, pct) values (p_player, p_pct)
  on conflict (player_id) do update set pct = excluded.pct;            -- 마감 전까지 바꿀 수 있다
  return jsonb_build_object('ok', true);
end $$;

-- 조회 (폰·스크린·관리자 공용) ----------------------------------------
-- 정답·해설·분포는 phase='answer' 이후에만 실린다. 봇 응답은 at 이 미래일 수 있어 at<=now() 만 센다.
create or replace function hq_view(p_player uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s hq_state; q hq_questions; nq hq_questions; revealed boolean; me jsonb; res jsonb;
begin
  select * into s from hq_state where id = 1;
  select * into q from hq_questions where idx = s.qi;
  select * into nq from hq_questions where idx = s.qi + 1;
  revealed := s.phase in ('answer');

  if p_player is not null then
    select jsonb_build_object(
      'id', p.id, 'name', p.name, 'table_no', p.table_no, 'score', p.score,
      'answer', (select choice from hq_answers a where a.player_id = p.id and a.qi = s.qi),
      'bet', (select pct from hq_bets b where b.player_id = p.id),
      'rank', (select count(*) + 1 from hq_players o where o.score > p.score))
    into me from hq_players p where p.id = p_player;
  end if;

  res := jsonb_build_object(
    'server_now', now(),
    'phase', s.phase, 'qi', s.qi, 'q_started_at', s.q_started_at, 'tables', s.tables,
    'total_q', (select count(*) from hq_questions),
    'next_is_bet', coalesce(nq.is_bet, false),
    'players', (select count(*) from hq_players),
    'me', me,
    'question', case when q.idx is null then null else jsonb_build_object(
        'idx', q.idx, 'round', q.round, 'type', q.type, 'q', q.q, 'opts', q.opts, 'limit_sec', q.limit_sec, 'is_bet', q.is_bet,
        'answer', case when revealed then q.answer end,
        'note', case when revealed then q.note end) end,
    'submitted', (select count(*) from hq_answers a where a.qi = s.qi and a.at <= now()),
    'dist', case when revealed then (
        select jsonb_agg(coalesce((select count(*) from hq_answers a where a.qi = s.qi and a.choice = i), 0) order by i)
        from generate_series(0, case when q.type = 'ox' then 1 else jsonb_array_length(q.opts) - 1 end) i) end,
    'bets', case when s.phase = 'bet' then (
        select jsonb_build_object('0', count(*) filter (where pct = 0), '50', count(*) filter (where pct = 50), '100', count(*) filter (where pct = 100)) from hq_bets) end,
    -- 팀 점수 = 응답한 적 있는 팀원 점수 평균 (인원 많은 테이블이 유리하지 않게)
    'teams', (select coalesce(jsonb_agg(t order by t.avg desc, t.table_no), '[]') from (
        select table_no, count(*) as n, coalesce(round(avg(score) filter (where active)), 0)::int as avg
        from hq_players group by table_no) t),
    'top', (select coalesce(jsonb_agg(x), '[]') from (
        select name, table_no, score from hq_players where active order by score desc, created_at limit 5) x),
    'winner', (select jsonb_build_object('name', name, 'table_no', table_no, 'id', id) from hq_players where id = s.winner_id),
    'drawn_at', s.drawn_at,
    'spin', case when s.phase = 'draw' then (select coalesce(jsonb_agg(name), '[]') from (select name from hq_players order by random() limit 30) z) end
  );
  return res;
end $$;

-- 진행자 ----------------------------------------------------------------
create or replace function hq_admin(p_pin text, p_action text, p_arg jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s hq_state; q hq_questions; nq hq_questions; n int; i int;
begin
  if not exists (select 1 from hq_config where id = 1 and pin_hash = crypt(p_pin, pin_hash)) then
    raise exception 'BAD_PIN';
  end if;
  select * into s from hq_state where id = 1 for update;

  if p_action = 'check' then
    return jsonb_build_object('ok', true);

  elsif p_action = 'next' then                      -- 진행 버튼 하나로 다음 단계
    select * into nq from hq_questions where idx = s.qi + 1;
    if s.phase in ('lobby', 'answer') then
      if nq.idx is null then
        update hq_state set phase = 'final', updated_at = now() where id = 1;
      elsif nq.is_bet then
        update hq_state set phase = 'bet', updated_at = now() where id = 1;
        insert into hq_bets (player_id, pct)        -- 리허설 봇도 베팅
          select id, (array[0,50,100])[1 + floor(random() * 3)::int] from hq_players where is_bot
          on conflict do nothing;
      else
        perform hq_open_q();
      end if;
    elsif s.phase = 'bet' then
      perform hq_open_q();
    elsif s.phase = 'q' then
      perform hq_reveal();
    elsif s.phase = 'final' then
      update hq_state set phase = 'draw', winner_id = null, drawn_at = null, updated_at = now() where id = 1;
    end if;

  elsif p_action = 'draw' then                      -- 추첨은 서버가 뽑는다(조작 시비 방지). 이미 뽑힌 사람은 제외.
    update hq_state set phase = 'draw', drawn_at = now(), updated_at = now(),
      winner_id = (select id from hq_players
                   where id <> all(coalesce((select array_agg((x)::uuid) from jsonb_array_elements_text(p_arg->'exclude') x), '{}'))
                   order by random() limit 1)
    where id = 1;

  elsif p_action = 'tables' then
    update hq_state set tables = (p_arg->>'n')::int, updated_at = now() where id = 1;

  elsif p_action = 'bots' then                      -- 리허설용 가상 참가자
    n := (p_arg->>'n')::int - (select count(*) from hq_players);
    for i in 1..greatest(n, 0) loop
      insert into hq_players (name, table_no, is_bot)
      values ((array['김부장','이차장','박과장','최대리','정사원','강부장','조차장','윤과장','장대리','한팀장','오수석','서책임'])[1 + (i % 12)] || i,
              1 + (i % s.tables), true);
    end loop;

  elsif p_action = 'questions' then                 -- 문항 통째로 교체
    if s.phase <> 'lobby' then raise exception 'ONLY_IN_LOBBY'; end if;
    delete from hq_questions;
    insert into hq_questions (idx, round, type, q, opts, answer, note, is_bet, limit_sec)
    select (ord - 1)::int, e->>'round', e->>'type', e->>'q', coalesce(e->'opts', '[]'), (e->>'answer')::int,
           coalesce(e->>'note', ''), coalesce((e->>'is_bet')::boolean, false), coalesce((e->>'limit_sec')::int, 15)
    from jsonb_array_elements(p_arg->'list') with ordinality as t(e, ord);

  elsif p_action = 'reset' then                     -- 리허설 후 / 행사 후 개인정보 삭제
    delete from hq_answers; delete from hq_bets; delete from hq_players;
    update hq_state set phase = 'lobby', qi = -1, q_started_at = null, winner_id = null, drawn_at = null, updated_at = now() where id = 1;

  elsif p_action = 'questions_get' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by idx), '[]') from hq_questions x);

  else
    raise exception 'BAD_ACTION';
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function hq_open_q()
returns void language plpgsql security definer set search_path = public as $$
declare q hq_questions; n int;
begin
  update hq_state set qi = qi + 1, phase = 'q', q_started_at = now(), updated_at = now() where id = 1;
  select hq_questions.* into q from hq_questions, hq_state where idx = hq_state.qi;
  n := case when q.type = 'ox' then 2 else jsonb_array_length(q.opts) end;
  -- 봇은 1.5~12초 사이 미래 시각으로 미리 답을 넣는다(65% 정답). 조회는 at<=now() 만 센다.
  insert into hq_answers (player_id, qi, choice, at)
  select id, q.idx, case when random() < 0.65 then q.answer else floor(random() * n)::int end,
         now() + make_interval(secs => 1.5 + random() * 10.5)
  from hq_players where is_bot
  on conflict do nothing;
end $$;

create or replace function hq_reveal()
returns void language plpgsql security definer set search_path = public as $$
declare s hq_state; q hq_questions;
begin
  select * into s from hq_state where id = 1;
  select * into q from hq_questions where idx = s.qi;
  -- 마감 후 들어온(또는 아직 미래인 봇) 응답은 무효
  delete from hq_answers where qi = s.qi and at > least(now(), s.q_started_at + make_interval(secs => q.limit_sec + 2));

  if q.is_bet then
    -- 베팅: 맞히면 건 점수 + 문제 점수, 틀리거나 안 풀면 건 점수를 잃는다.
    update hq_players p set
      score = p.score + case when a.choice = q.answer
                then round(p.score * coalesce(b.pct, 0) / 100.0)::int + hq_points(true, s.q_started_at, a.at, q.limit_sec)
                else -round(p.score * coalesce(b.pct, 0) / 100.0)::int end,
      active = p.active or a.player_id is not null
    from hq_players p2
    left join hq_answers a on a.player_id = p2.id and a.qi = s.qi
    left join hq_bets b on b.player_id = p2.id
    where p.id = p2.id;
  else
    update hq_players p set score = p.score + hq_points(a.choice = q.answer, s.q_started_at, a.at, q.limit_sec), active = true
    from hq_answers a where a.player_id = p.id and a.qi = s.qi;
  end if;
  update hq_state set phase = 'answer', updated_at = now() where id = 1;
end $$;

-- 내부 함수는 직접 못 부르게
revoke all on function hq_open_q() from public;
revoke all on function hq_reveal() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on function hq_open_q() from anon, authenticated;
    revoke all on function hq_reveal() from anon, authenticated;
    grant execute on function hq_join(text,int), hq_answer(uuid,int), hq_bet(uuid,int), hq_view(uuid), hq_admin(text,text,jsonb) to anon, authenticated;
  end if;
end $$;
-- 예시 문항. 실제 행사 전에는 관리자 화면 [문항] 탭에서 바꾼다.
delete from hq_questions;
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet) values (0,'R1 추억 소환','ox','2002 월드컵에서 한국은 4강에 올랐다.','[]'::jsonb,0,'4강 신화! 그날 어디서 보셨어요?',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet) values (1,'R1 추억 소환','mc','스타크래프트에서 "Show me the money"를 치면?','["유닛 무적", "자원 1만", "맵 전체 보기", "건설 즉시 완료"]'::jsonb,1,'PC방 시간당 1,000원이던 시절',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet) values (2,'R1 추억 소환','mc','삐삐 숫자 "8282"의 뜻은?','["사랑해", "빨리빨리", "잘자", "보고싶어"]'::jsonb,1,'"1004"는 천사, "486"은 사랑해',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet) values (3,'R1 추억 소환','ox','싸이월드 화폐 이름은 "도토리"였다.','[]'::jsonb,0,'BGM 사려고 도토리 충전하셨죠?',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet) values (4,'R2 부장님 마음 맞히기','mc','부장님 최애 회식 안주는?','["삼겹살", "회", "치킨", "골뱅이"]'::jsonb,0,'부장님 한 말씀 부탁드립니다!',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet) values (5,'R2 부장님 마음 맞히기','mc','부장님 노래방 18번은 몇 년대 노래?','["80년대", "90년대", "2000년대", "최신곡"]'::jsonb,1,'2차 노래방에서 검증 예정',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet) values (6,'R3 올인 베팅','mc','1997년 IMF 때 국민이 모은 금은 약 몇 톤?','["약 50톤", "약 120톤", "약 227톤", "약 500톤"]'::jsonb,2,'약 350만 명 참여',true);
insert into hq_config (id, pin_hash) values (1, extensions.crypt('1234', extensions.gen_salt('bf'))) on conflict (id) do update set pin_hash = excluded.pin_hash;
