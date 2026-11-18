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
  won boolean not null default false,           -- 추첨 당첨(중복 당첨 방지)
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
-- hq_players 는 공개하지 않는다: id 가 새면 남의 답을 대신 낼 수 있다. 화면은 전부 hq_view 로 본다.
drop policy if exists hq_players_read on hq_players;

alter table hq_players add column if not exists won boolean not null default false;
alter table hq_players add column if not exists prev_score int not null default 0;
alter table hq_players add column if not exists prev_rank int;
alter table hq_players add column if not exists last_gain int not null default 0;
alter table hq_players add column if not exists streak int not null default 0;          -- 연속 정답 수
alter table hq_players add column if not exists last_bonus jsonb not null default '{}';  -- 이번 문제 보너스 내역
alter table hq_players add column if not exists card text;                               -- 사용한 찬스 카드: fifty | double
alter table hq_players add column if not exists card_qi int;                             -- 카드를 쓴 문제
alter table hq_players add column if not exists card_hide jsonb;                         -- 50:50 으로 지운 보기

alter table hq_questions add column if not exists host text not null default '';  -- 진행자 멘트(선택)

-- 투표형(정답 없음) 문항 허용
alter table hq_questions alter column answer drop not null;
alter table hq_questions drop constraint if exists hq_questions_type_check;
alter table hq_questions add constraint hq_questions_type_check check (type in ('ox','mc','poll'));

-- 문항 이미지(어린 시절 사진 등). 폰에서 줄인 JPEG data URL. 현재 문제일 때만 RPC 로 꺼낼 수 있다.
create table if not exists hq_images (idx int primary key, data text not null);
alter table hq_images enable row level security;

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
-- 주의: Supabase API 경로는 WHERE 없는 UPDATE/DELETE 를 막는다(pg-safeupdate). 전체 대상이면 `where true`.

-- 점수: 정답이면 500 + 남은시간 비율 × 500 (빨리 맞힐수록 최대 1000)
create or replace function hq_points(p_correct boolean, p_started timestamptz, p_at timestamptz, p_limit int)
returns int language sql immutable set search_path = public as $$
  select case when not coalesce(p_correct, false) then 0
    else round(500 + 500 * greatest(0, p_limit - extract(epoch from (p_at - p_started))) / p_limit)::int end
$$;

create or replace function hq_nopts(q hq_questions)
returns int language sql immutable set search_path = public as $$
  select case when q.type = 'ox' then 2 else jsonb_array_length(q.opts) end
$$;

-- 참가 ----------------------------------------------------------------
drop function if exists hq_join(text, int);
drop function if exists hq_join(text);
-- 개인전: 닉네임만 받는다(대소문자·공백 무시하고 중복 불가).
-- p_id: 폰이 미리 만든 id. 통신이 끊겨 같은 요청이 다시 와도 같은 사람으로 처리한다.
create or replace function hq_join(p_name text, p_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r hq_players;
begin
  if p_id is not null then
    select * into r from hq_players where id = p_id;
    if found then return to_jsonb(r); end if;
  end if;
  p_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  if char_length(p_name) < 1 or char_length(p_name) > 12 then raise exception 'BAD_NAME'; end if;
  if exists (select 1 from hq_players where lower(replace(name, ' ', '')) = lower(replace(p_name, ' ', ''))) then
    raise exception 'NAME_TAKEN';
  end if;
  insert into hq_players (id, name, table_no) values (coalesce(p_id, gen_random_uuid()), p_name, 0) returning * into r;
  return to_jsonb(r);
end $$;

create or replace function hq_answer(p_player uuid, p_choice int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s hq_state; q hq_questions; p hq_players;
begin
  select * into s from hq_state where id = 1;
  if s.phase <> 'q' then raise exception 'NOT_OPEN'; end if;
  select * into q from hq_questions where idx = s.qi;
  select * into p from hq_players where id = p_player;
  if p.id is null then raise exception 'NO_PLAYER'; end if;
  if p_choice < 0 or p_choice >= hq_nopts(q) then raise exception 'BAD_CHOICE'; end if;
  if p.card = 'fifty' and p.card_qi = s.qi and p.card_hide ? p_choice::text then raise exception 'BAD_CHOICE'; end if;
  if now() > s.q_started_at + make_interval(secs => q.limit_sec + 2) then raise exception 'TOO_LATE'; end if;
  insert into hq_answers (player_id, qi, choice) values (p_player, s.qi, p_choice) on conflict do nothing;  -- 한 번 내면 못 바꾼다
  return jsonb_build_object('ok', true);
end $$;

-- 찬스 카드: 게임 전체에서 딱 한 장. 문제가 열려 있고 아직 답을 안 냈을 때만.
--   fifty  : 4지선다에서 오답 2개를 지운다
--   double : 이번 문제를 맞히면 문제 점수 2배 (틀려도 감점 없음)
create or replace function hq_card(p_player uuid, p_kind text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s hq_state; q hq_questions; p hq_players; hide jsonb;
begin
  select * into s from hq_state where id = 1;
  select * into q from hq_questions where idx = s.qi;
  select * into p from hq_players where id = p_player for update;
  if p.id is null then raise exception 'NO_PLAYER'; end if;
  if p.card is not null then
    if p.card = p_kind and p.card_qi = s.qi then return jsonb_build_object('ok', true); end if;  -- 재전송
    raise exception 'CARD_USED';
  end if;
  if s.phase <> 'q' or q.type = 'poll' or q.is_bet then raise exception 'CARD_NOT_NOW'; end if;
  if exists (select 1 from hq_answers where player_id = p_player and qi = s.qi) then raise exception 'CARD_NOT_NOW'; end if;
  if p_kind = 'fifty' then
    if q.type <> 'mc' then raise exception 'CARD_NOT_NOW'; end if;
    select jsonb_agg(i) into hide from (
      select i from generate_series(0, hq_nopts(q) - 1) i where i <> q.answer order by random() limit 2) z;
  elsif p_kind <> 'double' then
    raise exception 'BAD_CARD';
  end if;
  update hq_players set card = p_kind, card_qi = s.qi, card_hide = hide where id = p_player;
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

-- 시작 전(대기 단계)에만 스스로 나갈 수 있다 — 닉네임 바꾸기용
create or replace function hq_leave(p_player uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if (select phase from hq_state where id = 1) <> 'lobby' then raise exception 'NOT_LOBBY'; end if;
  delete from hq_players where id = p_player;
  return jsonb_build_object('ok', true);
end $$;

-- 문항 이미지: 지금 열려 있는 문제의 것만 꺼낼 수 있다(다음 문제 사진을 미리 못 보게).
create or replace function hq_image(p_idx int)
returns text language plpgsql security definer set search_path = public as $$
declare s hq_state;
begin
  select * into s from hq_state where id = 1;
  if s.qi <> p_idx or s.phase not in ('q', 'answer') then return null; end if;
  return (select data from hq_images where idx = p_idx);
end $$;

-- 조회 (모든 화면 공용) ----------------------------------------------------
-- 정답·해설·분포는 phase='answer' 이후에만 실린다. 봇 응답은 at 이 미래일 수 있어 at<=now() 만 센다.
create or replace function hq_view(p_player uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s hq_state; q hq_questions; nq hq_questions; revealed boolean; me jsonb;
begin
  select * into s from hq_state where id = 1;
  select * into q from hq_questions where idx = s.qi;
  select * into nq from hq_questions where idx = s.qi + 1;
  revealed := s.phase = 'answer';

  if p_player is not null then
    select jsonb_build_object(
      'id', p.id, 'name', p.name, 'score', p.score, 'gain', p.last_gain, 'prev_rank', p.prev_rank,
      'streak', p.streak, 'bonus', p.last_bonus, 'card', p.card,
      'hide', case when p.card = 'fifty' and p.card_qi = s.qi then p.card_hide end,
      'double_now', p.card = 'double' and p.card_qi = s.qi,
      'answer', (select choice from hq_answers a where a.player_id = p.id and a.qi = s.qi and a.at <= now()),
      'bet', (select pct from hq_bets b where b.player_id = p.id),
      'won', p.won,
      'rank', (select count(*) + 1 from hq_players o where o.score > p.score))
    into me from hq_players p where p.id = p_player;
  end if;

  return jsonb_build_object(
    'server_now', now(),
    'phase', s.phase, 'qi', s.qi, 'q_started_at', s.q_started_at,
    'total_q', (select count(*) from hq_questions),
    'next_is_bet', coalesce(nq.is_bet, false),
    'players', (select count(*) from hq_players),
    'me', me,
    'question', case when q.idx is null then null else jsonb_build_object(
        'idx', q.idx, 'round', q.round, 'type', q.type, 'q', q.q, 'opts', q.opts, 'limit_sec', q.limit_sec, 'is_bet', q.is_bet,
        'has_image', exists (select 1 from hq_images where idx = q.idx),
        'answer', case when revealed then q.answer end,
        'note', case when revealed then q.note end) end,
    'submitted', (select count(*) from hq_answers a where a.qi = s.qi and a.at <= now()),
    'dist', case when revealed then (
        select jsonb_agg(coalesce((select count(*) from hq_answers a where a.qi = s.qi and a.choice = i), 0) order by i)
        from generate_series(0, hq_nopts(q) - 1) i) end,
    'bets', case when s.phase = 'bet' then (
        select jsonb_build_object('0', count(*) filter (where pct = 0), '50', count(*) filter (where pct = 50), '100', count(*) filter (where pct = 100)) from hq_bets) end,
    -- 개인 순위 TOP 10. prev_rank 로 순위 변동 화살표를 그린다.
    'ranking', (select coalesce(jsonb_agg(x order by x.rank, x.created_at), '[]') from (
        select name, score, last_gain as gain, prev_rank, streak, created_at, id = p_player as is_me,
               rank() over (order by score desc)::int as rank
        from hq_players where active order by score desc, created_at limit 10) x),
    'winner', (select jsonb_build_object('name', name, 'is_me', id = p_player) from hq_players where id = s.winner_id),
    'drawn_at', s.drawn_at,
    'drawn', (select count(*) from hq_players where won),
    'spin', case when s.phase = 'draw' then (select coalesce(jsonb_agg(name), '[]') from (select name from hq_players order by random() limit 30) z) end
  );
end $$;

-- 진행자 ----------------------------------------------------------------
create or replace function hq_admin(p_pin text, p_action text, p_arg jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s hq_state; nq hq_questions; n int; i int;
begin
  if not exists (select 1 from hq_config where id = 1 and pin_hash = crypt(p_pin, pin_hash)) then
    raise exception 'BAD_PIN';
  end if;
  select * into s from hq_state where id = 1 for update;

  if p_action = 'check' then
    return jsonb_build_object('ok', true);

  elsif p_action = 'next' then                      -- 진행 버튼 하나로 다음 단계
    -- 재전송·연타 대비: 버튼을 누를 때 보던 단계와 지금 단계가 다르면 이미 처리된 요청이다.
    if p_arg ? 'from_phase' and (p_arg->>'from_phase' <> s.phase or (p_arg->>'from_qi')::int <> s.qi) then
      return jsonb_build_object('ok', true, 'skipped', true);
    end if;
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

  elsif p_action = 'draw' then
    -- 행운상: 1~3등(순위 상품 대상)은 빼고, 이미 뽑힌 사람도 뺀 나머지에서 서버가 무작위로 뽑는다.
    update hq_state set phase = 'draw', drawn_at = now(), updated_at = now(),
      winner_id = coalesce(
        (select id from (select id, won, rank() over (order by score desc) rk from hq_players) r
         where not won and rk > 3 order by random() limit 1),
        (select id from hq_players where not won order by random() limit 1))
    where id = 1;
    update hq_players set won = true where id = (select winner_id from hq_state where id = 1);

  elsif p_action = 'bots' then                      -- 리허설용 가상 참가자
    n := (p_arg->>'n')::int - (select count(*) from hq_players);
    for i in 1..greatest(n, 0) loop
      insert into hq_players (name, table_no, is_bot)
      values ((array['찍기의 신','검토해보겠습니다','PC방 고인물','도토리 부자','월요병 말기','막차 사수대','오늘 안 취함','일단 킵하시죠','퇴근 5분 전','법카의 수호자','연차 장인','읽씹 장인'])[1 + (i % 12)] || ' ' || (select count(*) + 1 from hq_players),
              0, true);
    end loop;

  elsif p_action = 'questions' then                 -- 문항 통째로 교체
    if s.phase <> 'lobby' then raise exception 'ONLY_IN_LOBBY'; end if;
    delete from hq_questions where true;
    insert into hq_questions (idx, round, type, q, opts, answer, note, is_bet, limit_sec, host)
    select (ord - 1)::int, coalesce(e->>'round', ''), e->>'type', e->>'q', coalesce(e->'opts', '[]'), (e->>'answer')::int,
           coalesce(e->>'note', ''), coalesce((e->>'is_bet')::boolean, false), coalesce((e->>'limit_sec')::int, 15), coalesce(e->>'host', '')
    from jsonb_array_elements(p_arg->'list') with ordinality as t(e, ord);
    delete from hq_images where idx >= (select count(*) from hq_questions);

  elsif p_action = 'image' then                     -- 문항 이미지 올리기 / 지우기(data 없으면 삭제)
    if p_arg->>'data' is null then
      delete from hq_images where idx = (p_arg->>'idx')::int;
    else
      if length(p_arg->>'data') > 800000 then raise exception 'IMAGE_TOO_BIG'; end if;
      insert into hq_images (idx, data) values ((p_arg->>'idx')::int, p_arg->>'data')
      on conflict (idx) do update set data = excluded.data;
    end if;

  elsif p_action = 'images_list' then
    return (select coalesce(jsonb_agg(idx order by idx), '[]') from hq_images);

  elsif p_action = 'restart' then                   -- 한 판 더: 참가자는 그대로, 점수·답안·베팅·카드·추첨만 비운다. 가상 참가자는 뺀다.
    delete from hq_answers where true; delete from hq_bets where true; delete from hq_players where is_bot;
    update hq_players set score = 0, active = false, won = false, prev_score = 0, prev_rank = null, last_gain = 0,
      streak = 0, last_bonus = '{}', card = null, card_qi = null, card_hide = null where true;
    update hq_state set phase = 'lobby', qi = -1, q_started_at = null, winner_id = null, drawn_at = null, updated_at = now() where id = 1;

  elsif p_action = 'reset' then                     -- 새 게임 / 행사 후 개인정보 삭제
    delete from hq_answers where true; delete from hq_bets where true; delete from hq_players where true;
    update hq_state set phase = 'lobby', qi = -1, q_started_at = null, winner_id = null, drawn_at = null, updated_at = now() where id = 1;

  elsif p_action = 'current' then                   -- 진행자 전용: 지금 문제와 다음 문제의 정답·해설·멘트 (참가자에겐 공개 전까지 안 내려간다)
    return jsonb_build_object(
      'now', (select jsonb_build_object('idx', idx, 'answer', answer, 'note', note, 'host', host) from hq_questions where idx = s.qi),
      'next', (select jsonb_build_object('idx', idx, 'q', q, 'type', type, 'opts', opts, 'answer', answer, 'host', host, 'is_bet', is_bet)
               from hq_questions where idx = s.qi + 1),
      'correct', (select count(*) from hq_answers a join hq_questions q on q.idx = a.qi where a.qi = s.qi and a.choice = q.answer and a.at <= now()));

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
  n := hq_nopts(q);
  -- 봇은 1.5~12초 사이 미래 시각으로 미리 답을 넣는다(65% 정답). 조회는 at<=now() 만 센다.
  insert into hq_answers (player_id, qi, choice, at)
  select id, q.idx,
         case when q.answer is not null and random() < 0.65 then q.answer else floor(random() * n)::int end,
         now() + make_interval(secs => 1.5 + random() * 10.5)
  from hq_players where is_bot
  on conflict do nothing;
end $$;

-- 채점 -------------------------------------------------------------------
--   기본     : 정답 500 + 빠르기 최대 500
--   2배 카드 : 이번 문제 기본 점수 한 번 더
--   콤보     : 3연속 정답부터 맞힐 때마다 +200
--   역전     : 문제 직전 순위가 하위 30%인 사람이 맞히면 기본 점수의 50% 추가
--   베팅     : 건 점수만큼 맞히면 더하고 틀리면(안 풀어도) 뺀다
--   투표     : 정답이 없어 점수·콤보에 영향 없음
create or replace function hq_reveal()
returns void language plpgsql security definer set search_path = public as $$
declare s hq_state; q hq_questions; total int; cut int;
begin
  select * into s from hq_state where id = 1;
  select * into q from hq_questions where idx = s.qi;
  -- 마감 후 들어온(또는 아직 미래인 봇) 응답은 무효
  delete from hq_answers where qi = s.qi and at > least(now(), s.q_started_at + make_interval(secs => q.limit_sec + 2));
  -- 순위 변동·이번 문제 득점 표시용 스냅샷
  update hq_players p set prev_score = p.score, prev_rank = r.rk, last_bonus = '{}'
  from (select id, rank() over (order by score desc)::int rk from hq_players) r where r.id = p.id;

  if q.type = 'poll' then
    update hq_players p set active = true from hq_answers a where a.player_id = p.id and a.qi = s.qi;
  else
    select count(*) into total from hq_players;
    cut := ceil(total * 0.7);
    update hq_players p set
      score = p.score + c.base + c.dbl + c.under + c.combo + c.bet,
      streak = case when c.correct then p.streak + 1 else 0 end,
      active = p.active or c.answered,
      last_bonus = jsonb_strip_nulls(jsonb_build_object(
        'double', nullif(c.dbl, 0), 'underdog', nullif(c.under, 0), 'combo', nullif(c.combo, 0),
        'bet', case when c.stake > 0 then c.bet end, 'streak', case when c.correct then p.streak + 1 end))
    from (
      select x.*,
             case when x.correct and x.card = 'double' and x.card_qi = s.qi then x.base else 0 end as dbl,
             case when x.correct and x.prev_rank > cut and total >= 4 then round(x.base * 0.5)::int else 0 end as under,
             case when x.correct and x.streak + 1 >= 3 then 200 else 0 end as combo,
             case when x.stake = 0 then 0 when x.correct then x.stake else -x.stake end as bet
      from (
        select p2.id, p2.card, p2.card_qi, p2.prev_rank, p2.streak,
               a.player_id is not null as answered,
               coalesce(a.choice = q.answer, false) as correct,
               hq_points(a.choice = q.answer, s.q_started_at, a.at, q.limit_sec) as base,
               case when q.is_bet then round(p2.score * coalesce(b.pct, 0) / 100.0)::int else 0 end as stake
        from hq_players p2
        left join hq_answers a on a.player_id = p2.id and a.qi = s.qi
        left join hq_bets b on b.player_id = p2.id
      ) x
    ) c
    where p.id = c.id;
  end if;
  update hq_players set last_gain = score - prev_score where true;
  update hq_state set phase = 'answer', updated_at = now() where id = 1;
end $$;

-- 권한: 내부 함수는 직접 못 부르게, 공개 RPC 만 열어 둔다
revoke all on function hq_open_q() from public;
revoke all on function hq_reveal() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on function hq_open_q() from anon, authenticated;
    revoke all on function hq_reveal() from anon, authenticated;
    grant execute on function hq_join(text, uuid), hq_leave(uuid), hq_answer(uuid,int), hq_card(uuid,text), hq_bet(uuid,int),
      hq_image(int), hq_view(uuid), hq_admin(text,text,jsonb) to anon, authenticated;
  end if;
end $$;
-- 예시 문항. 실제 행사 전에는 진행자 화면 [문항 편집]에서 바꾼다.
delete from hq_questions where true;
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,host) values (0,'R1 추억 소환','ox','2002 월드컵에서 한국은 4강에 올랐다.','[]'::jsonb,0,'4강 신화! 그날 어디서 보셨어요?',false,'자, 첫 문제는 몸풀기! 2002년 그 여름 기억나시죠? 빨리 누를수록 점수가 높습니다!');
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,host) values (1,'R1 추억 소환','mc','스타크래프트에서 "Show me the money"를 치면?','["유닛 무적", "자원 1만", "맵 전체 보기", "건설 즉시 완료"]'::jsonb,1,'PC방 시간당 1,000원이던 시절',false,'PC방 좀 다녀 보신 분들은 바로 아실 겁니다. 부장님도 아실까요?');
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,host) values (2,'R1 추억 소환','mc','삐삐 숫자 "8282"의 뜻은?','["사랑해", "빨리빨리", "잘자", "보고싶어"]'::jsonb,1,'"1004"는 천사, "486"은 사랑해',false,'삐삐 세대 손! 이건 손이 먼저 기억할 거예요.');
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,host) values (3,'R1 추억 소환','ox','싸이월드 화폐 이름은 "도토리"였다.','[]'::jsonb,0,'BGM 사려고 도토리 충전하셨죠?',false,'싸이월드 미니홈피 BGM, 다들 하나씩 있었잖아요?');
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,host) values (4,'R2 부장님 마음 맞히기','mc','부장님 최애 회식 안주는?','["삼겹살", "회", "치킨", "골뱅이"]'::jsonb,0,'부장님 한 말씀 부탁드립니다!',false,'이제 진짜 문제입니다. 부장님 마음을 맞혀 보세요. 부장님은 표정 관리 부탁드려요!');
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,host) values (5,'R2 부장님 마음 맞히기','mc','부장님 노래방 18번은 몇 년대 노래?','["80년대", "90년대", "2000년대", "최신곡"]'::jsonb,1,'2차 노래방에서 검증 예정',false,'부장님 18번, 2차 노래방에서 실제로 검증합니다. 신중하게!');
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,host) values (6,'쉬어가기 투표','poll','오늘 2차, 어디로 갈까요?','["노래방", "호프", "포장마차", "집에 갑니다"]'::jsonb,null,'점수와 상관없는 투표예요',false,'잠깐 쉬어 갑니다. 점수와 상관없는 투표예요. 오늘 2차, 여러분이 정합니다!');
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,host) values (7,'R3 올인 베팅','mc','1997년 IMF 때 국민이 모은 금은 약 몇 톤?','["약 50톤", "약 120톤", "약 227톤", "약 500톤"]'::jsonb,2,'약 350만 명 참여',true,'마지막 문제! 지금까지 모은 점수를 걸고 역전을 노려 보세요.');
insert into hq_config (id, pin_hash) values (1, extensions.crypt('1234', extensions.gen_salt('bf'))) on conflict (id) do nothing;
