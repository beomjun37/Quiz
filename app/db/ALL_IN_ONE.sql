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

alter table hq_players add column if not exists max_streak int not null default 0;   -- 최고 연속 정답
alter table hq_state add column if not exists winner_ids uuid[] not null default '{}';  -- (더 이상 쓰지 않음: hq_state 는 공개라 id 가 샌다)
-- 방금 뽑힌 행운상: 참가자 id 가 들어 있으므로 공개 테이블(hq_state)이 아니라 비공개 테이블에 둔다
create table if not exists hq_draw (id int primary key default 1 check (id = 1), winner_ids uuid[] not null default '{}');
insert into hq_draw (id) values (1) on conflict do nothing;
alter table hq_draw enable row level security;
update hq_state set winner_ids = '{}' where id = 1;
-- 진행자 PIN 무차별 대입 방지: 10번 틀리면 5분 잠금
alter table hq_config add column if not exists fails int not null default 0;
alter table hq_config add column if not exists locked_until timestamptz;
alter table hq_state add column if not exists end_msg text not null default '오늘 함께해 주셔서 감사합니다! 즐거운 저녁 되세요';

-- 사진 연출: '' | zoom(확대→축소) | blur(흐림→선명) | pixel(모자이크→선명) | silhouette(그림자→원본)
alter table hq_questions add column if not exists reveal text not null default '';

-- 문항 고정: 랜덤 세트를 다시 만들어도 남는 문제(사진 문제처럼 직접 만든 것)
alter table hq_questions add column if not exists pinned boolean not null default false;

-- 문제 은행: 랜덤 세트 재료. used 가 적은 문제부터 뽑아 매번 다른 문제가 나오게 한다.
create table if not exists hq_bank (
  id serial primary key,
  cat text not null,                 -- 추억 | 요즘 말 | 예능 | 상식 | 베팅
  diff int not null check (diff between 1 and 3),   -- 1 쉬움 2 보통 3 어려움
  type text not null check (type in ('ox','mc')),
  q text not null, opts jsonb not null default '[]', answer int not null,
  note text not null default '', host text not null default '',
  used int not null default 0,
  unique (q)
);
alter table hq_bank enable row level security;
alter table hq_bank add column if not exists topic text not null default '';  -- 같은 주제는 한 세트에 하나만
-- 다수결(survey)·소수결(minority): 정답이 참가자 응답으로 정해져서 은행에는 정답이 없다
alter table hq_bank alter column answer drop not null;
alter table hq_bank drop constraint if exists hq_bank_type_check;
alter table hq_bank add constraint hq_bank_type_check check (type in ('ox','mc','survey','minority'));

-- 마무리 화면 맨 아래 작은 글씨(사진 출처 등)
alter table hq_state add column if not exists end_credits text not null default '';

-- 노래 퀴즈: 진행자가 자기 폰으로 틀 노래의 검색어(예: "쿨 해변의 여인"). 음원은 앱에 넣지 않는다.
-- 정답이 드러나므로 참가자용 hq_view 에는 싣지 않고 진행자 RPC(current)로만 내려준다.
alter table hq_questions add column if not exists media text not null default '';
alter table hq_bank add column if not exists media text not null default '';
-- 노래 문제는 문제 글이 같아서(지금 나오는 노래 제목은?) 문제 글 + 노래 검색어로 구분한다
alter table hq_bank drop constraint if exists hq_bank_q_key;
create unique index if not exists hq_bank_q_media on hq_bank (q, media);

-- 노래 음원 조각(진행자가 자기 폰에서 올린 20초 클립, WAV data URL). 진행자 PIN 으로만 꺼낼 수 있다.
create table if not exists hq_audio (idx int primary key, data text not null);
alter table hq_audio enable row level security;

-- 정답 공개 되돌리기용 스냅샷
alter table hq_players add column if not exists prev_streak int not null default 0;
alter table hq_players add column if not exists prev_max_streak int not null default 0;
alter table hq_players add column if not exists prev_active boolean not null default false;

-- 정답 공개 때 리액션(👏😂🍺🔥) 집계
create table if not exists hq_reactions (qi int not null, kind text not null check (kind in ('clap','lol','beer','fire')), n int not null default 0, primary key (qi, kind));
alter table hq_reactions enable row level security;

-- 투표형(정답 없음) 문항 허용
alter table hq_questions alter column answer drop not null;
alter table hq_questions drop constraint if exists hq_questions_type_check;
alter table hq_questions add constraint hq_questions_type_check check (type in ('ox','mc','poll','survey','minority'));

-- 문항 이미지(어린 시절 사진 등). 폰에서 줄인 JPEG data URL. 현재 문제일 때만 RPC 로 꺼낼 수 있다.
create table if not exists hq_images (idx int primary key, data text not null);
alter table hq_images enable row level security;

-- 정답 추가 인정(복수 정답): 공개 후 진행자가 '이것도 정답'으로 인정한 보기들
alter table hq_questions add column if not exists alt jsonb not null default '[]';
-- 현장에서 '문제 교체'된 은행 문제: 다음 랜덤 뽑기에서 빼고 점검 화면에서 모아 본다
alter table hq_bank add column if not exists flagged boolean not null default false;

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
  p_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  -- 재전송이면 같은 사람으로 처리. 단 닉네임까지 같을 때만(남의 id 만 알아서는 그 사람이 될 수 없게)
  if p_id is not null then
    select * into r from hq_players where id = p_id and lower(replace(name, ' ', '')) = lower(replace(p_name, ' ', ''));
    if found then return to_jsonb(r); end if;
    if exists (select 1 from hq_players where id = p_id) then p_id := null; end if;
  end if;
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

-- 리액션: 정답 공개 화면에서만. 한 번에 1씩, 문제당 종류별로 센다.
create or replace function hq_react(p_kind text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s hq_state;
begin
  select * into s from hq_state where id = 1;
  if s.phase <> 'answer' then return jsonb_build_object('ok', false); end if;
  insert into hq_reactions (qi, kind, n) values (s.qi, p_kind, 1)
  on conflict (qi, kind) do update set n = hq_reactions.n + 1;
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
      'won', p.won, 'max_streak', p.max_streak,
      'correct', (select count(*) from hq_answers a join hq_questions qq on qq.idx = a.qi
                  where a.player_id = p.id and qq.type <> 'poll' and (a.choice = qq.answer or qq.alt @> to_jsonb(a.choice)) and a.qi < s.qi + (case when s.phase in ('answer','final','draw','end') then 1 else 0 end)),
      'rank', (select count(*) + 1 from hq_players o where o.score > p.score))
    into me from hq_players p where p.id = p_player;
  end if;

  return jsonb_build_object(
    'server_now', now(),
    'phase', s.phase, 'qi', s.qi, 'q_started_at', s.q_started_at,
    'total_q', (select count(*) from hq_questions),
    'next_is_bet', coalesce(nq.is_bet, false),
    'players', (select count(*) from hq_players),
    'humans', (select count(*) from hq_players where not is_bot),
    -- 전체 참가자 명단(순위 포함): 들어온 순서가 아니라 점수 순, 같은 점수는 먼저 들어온 사람이 위
    'roster', (select coalesce(jsonb_agg(x order by x.score desc, x.created_at), '[]') from (
        select name, score, is_bot as bot, id = p_player as is_me, created_at,
               rank() over (order by score desc)::int as rank
        from hq_players) x),
    'me', me,
    'question', case when q.idx is null then null else jsonb_build_object(
        'idx', q.idx, 'round', q.round, 'type', q.type, 'q', q.q, 'opts', q.opts, 'limit_sec', q.limit_sec, 'is_bet', q.is_bet,
        'has_image', exists (select 1 from hq_images where idx = q.idx), 'reveal', q.reveal, 'music', q.media <> '' or exists (select 1 from hq_audio where idx = q.idx),
        'answer', case when revealed then q.answer end,
        'alt', case when revealed then q.alt end,
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
    'winners', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'is_me', id = p_player)), '[]') from hq_players where id = any(select unnest(winner_ids) from hq_draw where id = 1)),
    'lucky_all', case when s.phase in ('draw','end') then (select coalesce(jsonb_agg(name order by name), '[]') from hq_players where won) end,
    'end_msg', s.end_msg, 'end_credits', case when s.phase = 'end' then s.end_credits end,
    'reactions', case when revealed then (select coalesce(jsonb_object_agg(kind, n), '{}') from hq_reactions where qi = s.qi) end,
    'end_stats', case when s.phase = 'end' then jsonb_build_object(
        'streak_king', (select jsonb_build_object('name', name, 'n', max_streak) from hq_players where max_streak > 0 order by max_streak desc, score desc limit 1),
        'questions', (select count(*) from hq_questions where type <> 'poll'),
        'answers', (select count(*) from hq_answers)) end,
    'drawn_at', s.drawn_at,
    'drawn', (select count(*) from hq_players where won),
    'spin', case when s.phase = 'draw' then (select coalesce(jsonb_agg(name), '[]') from (select name from hq_players order by random() limit 30) z) end
  );
end $$;

-- 진행자 ----------------------------------------------------------------
create or replace function hq_admin(p_pin text, p_action text, p_arg jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s hq_state; nq hq_questions; n int; i int; c_cat text; c_round text;
begin
  if exists (select 1 from hq_config where id = 1 and locked_until > now()) then raise exception 'PIN_LOCKED'; end if;
  if not exists (select 1 from hq_config where id = 1 and pin_hash = crypt(p_pin, pin_hash)) then
    -- 10번 틀리면 5분 잠금(무차별 대입 방지). 예외로 끝나면 이 갱신도 되돌려지므로 별도 함수로 커밋한다.
    update hq_config set
      locked_until = case when fails + 1 >= 10 then now() + interval '5 minutes' end,
      fails = case when fails + 1 >= 10 then 0 else fails + 1 end where id = 1;
    return jsonb_build_object('ok', false, 'error', 'BAD_PIN');  -- 예외 대신 반환해야 실패 횟수가 저장된다
  end if;
  update hq_config set fails = 0 where id = 1 and fails > 0;
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
      update hq_state set phase = 'draw', winner_ids = '{}', drawn_at = null, updated_at = now() where id = 1;
      update hq_draw set winner_ids = '{}' where id = 1;
    elsif s.phase = 'draw' then
      update hq_state set phase = 'end', updated_at = now() where id = 1;
    end if;

  elsif p_action = 'draw' then
    -- 행운상: 1~3등과 이미 뽑힌 사람을 빼고, 서버가 n명을 한 번에 무작위로 뽑는다.
    if s.phase not in ('final', 'draw') then raise exception 'NOT_DRAW'; end if;
    -- 재전송 방지: 화면에서 보던 추첨 시각과 지금 시각이 다르면 이미 처리된 요청
    if p_arg ? 'from_drawn' and coalesce(s.drawn_at::text, '') <> coalesce(p_arg->>'from_drawn', '') then
      return jsonb_build_object('ok', true, 'skipped', true);
    end if;
    n := least(greatest(coalesce((p_arg->>'n')::int, 1), 1), 20);
    update hq_draw set winner_ids = coalesce((select array_agg(id) from (
        select id from (select id, won, row_number() over (order by score desc, created_at) rk from hq_players) r
        where not won and rk > 3 order by random() limit n) z), '{}')  -- 공동 순위여도 위에서 3명만 뺀다
    where id = 1;
    if (select cardinality(winner_ids) from hq_draw where id = 1) = 0 then raise exception 'NO_CANDIDATE'; end if;
    update hq_players set won = true where id = any(select unnest(winner_ids) from hq_draw where id = 1);
    update hq_state set phase = 'draw', drawn_at = now(), updated_at = now() where id = 1;

  elsif p_action = 'set_pin' then                   -- PIN 바꾸기 (4~12자)
    if char_length(coalesce(p_arg->>'pin', '')) not between 4 and 12 then raise exception 'BAD_NEW_PIN'; end if;
    update hq_config set pin_hash = crypt(p_arg->>'pin', gen_salt('bf')) where id = 1;

  elsif p_action = 'back' then                      -- 실수 되돌리기: 한 단계 뒤로
    if p_arg ? 'from_phase' and (p_arg->>'from_phase' <> s.phase or (p_arg->>'from_qi')::int <> s.qi) then
      return jsonb_build_object('ok', true, 'skipped', true);
    end if;
    if s.phase = 'q' then
      -- 문제 열기 취소: 이 문제 답안을 지우고 직전 단계로(시간은 다시 열 때 새로 시작)
      delete from hq_answers where qi = s.qi;
      update hq_players set card = null, card_qi = null, card_hide = null where card_qi = s.qi;
      update hq_state set qi = qi - 1, q_started_at = null, updated_at = now(),
        phase = case when exists (select 1 from hq_questions where idx = s.qi and is_bet) then 'bet'
                     when s.qi = 0 then 'lobby' else 'answer' end
      where id = 1;
    elsif s.phase = 'answer' then
      -- 정답 공개 취소: 점수·연속 기록을 공개 직전으로 되돌리고 다시 '문제 푸는 중'으로
      update hq_players set score = prev_score, streak = prev_streak, max_streak = prev_max_streak,
        active = prev_active, last_gain = 0, last_bonus = '{}' where true;
      update hq_questions set answer = null, alt = '[]' where idx = s.qi and type in ('survey', 'minority');
      delete from hq_reactions where qi = s.qi;
      update hq_state set phase = 'q', q_started_at = now(), updated_at = now() where id = 1;  -- 다시 풀 수 있게 시간도 새로
    elsif s.phase = 'bet' then
      update hq_state set phase = case when s.qi < 0 then 'lobby' else 'answer' end, updated_at = now() where id = 1;
    elsif s.phase = 'final' then
      update hq_state set phase = 'answer', updated_at = now() where id = 1;
    elsif s.phase = 'draw' then
      update hq_state set phase = 'final', winner_ids = '{}', updated_at = now() where id = 1;
      update hq_draw set winner_ids = '{}' where id = 1;
    elsif s.phase = 'end' then
      update hq_state set phase = 'draw', updated_at = now() where id = 1;
    end if;

  elsif p_action = 'skip' then                      -- 문제 건너뛰기: 이 문제 답안을 지우고 점수 없이 다음 단계로
    if p_arg ? 'from_phase' and (p_arg->>'from_phase' <> s.phase or (p_arg->>'from_qi')::int <> s.qi) then
      return jsonb_build_object('ok', true, 'skipped', true);
    end if;
    if s.phase <> 'q' then raise exception 'NOT_OPEN'; end if;
    delete from hq_answers where qi = s.qi;
    update hq_players set card = null, card_qi = null, card_hide = null where card_qi = s.qi;
    select * into nq from hq_questions where idx = s.qi + 1;
    if nq.idx is null then
      update hq_state set phase = 'final', updated_at = now() where id = 1;
    elsif nq.is_bet then
      update hq_state set phase = 'bet', updated_at = now() where id = 1;
      insert into hq_bets (player_id, pct)
        select id, (array[0,50,100])[1 + floor(random() * 3)::int] from hq_players where is_bot on conflict do nothing;
    else
      perform hq_open_q();
    end if;

  elsif p_action = 'accept' then                    -- 정답 추가 인정: 공개 후 '이 보기도 정답'으로 인정하고 점수를 다시 매긴다
    if s.phase <> 'answer' then raise exception 'NOT_REVEALED'; end if;
    select * into nq from hq_questions where idx = s.qi;
    if nq.type not in ('ox', 'mc') then raise exception 'NO_ANSWER_TYPE'; end if;
    i := (p_arg->>'choice')::int;
    if i is null or i < 0 or i >= hq_nopts(nq) then raise exception 'BAD_CHOICE'; end if;
    if i = nq.answer or nq.alt @> to_jsonb(i) then return jsonb_build_object('ok', true, 'skipped', true); end if;
    -- 공개 직전 점수로 되돌린 뒤 같은 마감 기준으로 다시 채점한다
    update hq_players set score = prev_score, streak = prev_streak, max_streak = prev_max_streak,
      active = prev_active, last_gain = 0, last_bonus = '{}' where true;
    update hq_questions set alt = alt || to_jsonb(i) where idx = s.qi;
    perform hq_reveal();

  elsif p_action = 'replace' then                   -- 문제 교체: 이 문제를 무효로 하고 같은 영역의 다른 은행 문제를 같은 자리에 넣어 다시 연다
    if p_arg ? 'from_phase' and (p_arg->>'from_phase' <> s.phase or (p_arg->>'from_qi')::int <> s.qi) then
      return jsonb_build_object('ok', true, 'skipped', true);
    end if;
    if s.phase not in ('q', 'answer') then raise exception 'NOT_OPEN'; end if;
    select * into nq from hq_questions where idx = s.qi;
    if s.phase = 'answer' then                      -- 공개된 점수는 되돌린다
      update hq_players set score = prev_score, streak = prev_streak, max_streak = prev_max_streak,
        active = prev_active, last_gain = 0, last_bonus = '{}' where true;
    end if;
    delete from hq_answers where qi = s.qi;
    delete from hq_reactions where qi = s.qi;
    update hq_players set card = null, card_qi = null, card_hide = null where card_qi = s.qi;
    -- 원래 문제의 영역: 은행에서 온 문제면 그 카테고리, 아니면 회차 이름으로 짐작
    c_cat := (select cat from hq_bank where q = nq.q and media = nq.media limit 1);
    update hq_bank set flagged = true where q = nq.q and media = nq.media;
    if c_cat is null then
      c_cat := case when nq.is_bet then '베팅' else (select v.cat from (values ('추억', '추억 소환'), ('다수결', '100명에게 물었습니다'), ('요즘 말', '요즘 말 테스트'),
        ('가요', '추억의 가요'), ('회사', '회사 생활'), ('소수결', '소수가 이긴다'), ('예능', '예능·드라마 소환'), ('이모지', '이모지 퀴즈'),
        ('노래', '노래 퀴즈'), ('상식', '상식 퀴즈')) v(cat, r) where v.r = nq.round) end;
    end if;
    -- 같은 영역 → (없으면) 아무 영역. 이미 세트에 있는 문제·주제, 교체된 문제는 뺀다. 사진 없이 돌아가는 문제만.
    select b.id, b.cat into n, c_round from hq_bank b
      where not b.flagged and (b.cat = '베팅') = nq.is_bet
        and not exists (select 1 from hq_questions x where x.q = b.q and x.media = b.media)
      order by (b.cat = coalesce(c_cat, '')) desc, b.used, random() limit 1;
    if n is null then raise exception 'NO_SPARE'; end if;
    delete from hq_images where idx = s.qi;
    delete from hq_audio where idx = s.qi;
    update hq_questions q set type = b.type, q = b.q, opts = b.opts, answer = b.answer, note = b.note, host = b.host, media = b.media,
        alt = '[]', reveal = '', pinned = false, limit_sec = case when b.media <> '' then 25 else 15 end,
        round = case when b.cat = coalesce(c_cat, '') then q.round else coalesce((select v.r from (values ('추억', '추억 소환'), ('다수결', '100명에게 물었습니다'), ('요즘 말', '요즘 말 테스트'),
          ('가요', '추억의 가요'), ('회사', '회사 생활'), ('소수결', '소수가 이긴다'), ('예능', '예능·드라마 소환'), ('이모지', '이모지 퀴즈'),
          ('노래', '노래 퀴즈'), ('상식', '상식 퀴즈'), ('베팅', '올인 베팅')) v(cat, r) where v.cat = b.cat), q.round) end
      from hq_bank b where b.id = n and q.idx = s.qi;
    update hq_bank set used = used + 1 where id = n;
    -- 같은 번호로 새로 연다(시간도 새로)
    update hq_state set qi = qi - 1 where id = 1;
    perform hq_open_q();
    return jsonb_build_object('ok', true, 'same_cat', coalesce(c_round = c_cat, false), 'cat', c_round);

  elsif p_action = 'goto' then                      -- 연습용: 원하는 문제로 바로 이동(그 문제부터 답안·카드를 지우고 새로 연다)
    n := least(greatest((p_arg->>'qi')::int, 0), (select count(*) from hq_questions) - 1);
    delete from hq_answers where qi >= n;
    update hq_players set card = null, card_qi = null, card_hide = null where card_qi >= n;
    update hq_state set qi = n - 1, winner_ids = '{}', drawn_at = null, updated_at = now() where id = 1;
    update hq_draw set winner_ids = '{}' where id = 1;
    if (select is_bet from hq_questions where idx = n) then
      update hq_state set phase = 'bet', q_started_at = null where id = 1;
    else
      perform hq_open_q();
    end if;

  elsif p_action = 'end_msg' then
    update hq_state set end_msg = left(coalesce(p_arg->>'msg', ''), 120), updated_at = now() where id = 1;

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
    insert into hq_questions (idx, round, type, q, opts, answer, note, is_bet, limit_sec, host, reveal, pinned, media)
    select (ord - 1)::int, coalesce(e->>'round', ''), e->>'type', e->>'q', coalesce(e->'opts', '[]'), (e->>'answer')::int,
           coalesce(e->>'note', ''), coalesce((e->>'is_bet')::boolean, false), coalesce((e->>'limit_sec')::int, 15), coalesce(e->>'host', ''), coalesce(e->>'reveal', ''), coalesce((e->>'pinned')::boolean, false), coalesce(e->>'media', '')
    from jsonb_array_elements(p_arg->'list') with ordinality as t(e, ord);
    delete from hq_images where idx >= (select count(*) from hq_questions);
    delete from hq_audio where idx >= (select count(*) from hq_questions);

  elsif p_action = 'image' then                     -- 문항 이미지 올리기 / 지우기(data 없으면 삭제)
    if p_arg->>'data' is null then
      delete from hq_images where idx = (p_arg->>'idx')::int;
    else
      if length(p_arg->>'data') > 800000 then raise exception 'IMAGE_TOO_BIG'; end if;
      insert into hq_images (idx, data) values ((p_arg->>'idx')::int, p_arg->>'data')
      on conflict (idx) do update set data = excluded.data;
    end if;

  elsif p_action = 'image_get' then                 -- 진행자 미리보기용: 아무 문제의 사진이나 꺼낸다(PIN 필요)
    return to_jsonb((select data from hq_images where idx = (p_arg->>'idx')::int));

  elsif p_action = 'audio' then                     -- 노래 음원 조각 올리기/지우기. 올리면 그 문제는 고정(랜덤 다시 뽑아도 남게)
    if p_arg->>'data' is null then
      delete from hq_audio where idx = (p_arg->>'idx')::int;
    else
      if length(p_arg->>'data') > 3000000 then raise exception 'AUDIO_TOO_BIG'; end if;
      insert into hq_audio (idx, data) values ((p_arg->>'idx')::int, p_arg->>'data')
      on conflict (idx) do update set data = excluded.data;
      update hq_questions set pinned = true where idx = (p_arg->>'idx')::int;
    end if;

  elsif p_action = 'set_media' then                 -- 노래 시작 지점 저장 등: 한 문제의 노래 링크만 바꾼다(게임 중에도 가능)
    update hq_questions set media = coalesce(p_arg->>'media', '') where idx = (p_arg->>'idx')::int;

  elsif p_action = 'audio_get' then
    return to_jsonb((select data from hq_audio where idx = (p_arg->>'idx')::int));

  elsif p_action = 'audio_list' then
    return (select coalesce(jsonb_agg(idx order by idx), '[]') from hq_audio);

  elsif p_action = 'images_list' then
    return (select coalesce(jsonb_agg(idx order by idx), '[]') from hq_images);

  elsif p_action = 'restart' then                   -- 한 판 더: 참가자는 그대로, 점수·답안·베팅·카드·추첨만 비운다. 가상 참가자는 뺀다.
    delete from hq_answers where true; delete from hq_bets where true; delete from hq_reactions where true; delete from hq_players where is_bot;
    update hq_players set score = 0, active = false, won = false, prev_score = 0, prev_rank = null, last_gain = 0,
      streak = 0, max_streak = 0, last_bonus = '{}', card = null, card_qi = null, card_hide = null where true;
    update hq_state set phase = 'lobby', qi = -1, q_started_at = null, winner_ids = '{}', drawn_at = null, updated_at = now() where id = 1;
    update hq_draw set winner_ids = '{}' where id = 1;
    update hq_questions set answer = null, alt = '[]' where type in ('survey', 'minority');  -- 지난 판에 정해진 다수결·소수결 정답 지우기
    delete from hq_reactions where true;

  elsif p_action = 'reset' then                     -- 새 게임 / 행사 후 개인정보 삭제
    delete from hq_answers where true; delete from hq_bets where true; delete from hq_reactions where true; delete from hq_players where true;
    update hq_state set phase = 'lobby', qi = -1, q_started_at = null, winner_ids = '{}', drawn_at = null, updated_at = now() where id = 1;
    update hq_draw set winner_ids = '{}' where id = 1;
    update hq_questions set answer = null, alt = '[]' where type in ('survey', 'minority');  -- 지난 판에 정해진 다수결·소수결 정답 지우기
    delete from hq_reactions where true;

  elsif p_action = 'current' then                   -- 진행자 전용: 지금 문제와 다음 문제의 정답·해설·멘트 (참가자에겐 공개 전까지 안 내려간다)
    return jsonb_build_object(
      'now', (select jsonb_build_object('idx', idx, 'answer', answer, 'alt', alt, 'note', note, 'host', host, 'media', media) from hq_questions where idx = s.qi),
      'next', (select jsonb_build_object('idx', idx, 'q', q, 'type', type, 'opts', opts, 'answer', answer, 'host', host, 'is_bet', is_bet,
               'round', round, 'note', note, 'limit_sec', limit_sec, 'media', media,
               'reveal', reveal, 'has_image', exists (select 1 from hq_images i where i.idx = hq_questions.idx))
               from hq_questions where idx = s.qi + 1),
      'correct', (select count(*) from hq_answers a join hq_questions q on q.idx = a.qi where a.qi = s.qi and (a.choice = q.answer or q.alt @> to_jsonb(a.choice)) and a.at <= now()));

  elsif p_action = 'bank_stats' then                -- 문제 은행 현황: 카테고리 × 난이도 개수
    return (select coalesce(jsonb_object_agg(cat, x), '{}') from (
      select cat, jsonb_build_object('1', count(*) filter (where diff = 1), '2', count(*) filter (where diff = 2),
                                     '3', count(*) filter (where diff = 3)) x from hq_bank group by cat) z);

  elsif p_action = 'bank_list' then                 -- 문제 은행 둘러보기: 카테고리별 전체 문제
    return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'cat', cat, 'diff', diff, 'type', type, 'q', q, 'opts', opts,
              'answer', answer, 'note', note, 'host', host, 'media', media, 'used', used) order by diff, id), '[]')
            from hq_bank where cat = p_arg->>'cat');

  elsif p_action = 'bank_add' then                  -- 은행 문제를 지금 세트에 넣기(베팅 문제 앞, 고정). 대기 단계에서만
    if s.phase <> 'lobby' then raise exception 'ONLY_IN_LOBBY'; end if;
    if exists (select 1 from hq_questions q join hq_bank b on b.q = q.q and b.media = q.media where b.id = (p_arg->>'id')::int) then raise exception 'ALREADY_IN_SET'; end if;
    n := coalesce((select min(idx) from hq_questions where is_bet), (select count(*) from hq_questions));
    update hq_questions set idx = idx + 1000 where idx >= n;
    update hq_images set idx = idx + 1000 where idx >= n;
    update hq_audio set idx = idx + 1000 where idx >= n;
    insert into hq_questions (idx, round, type, q, opts, answer, note, is_bet, limit_sec, host, reveal, pinned, media)
      select n, (case cat when '추억' then '추억 소환' when '가요' then '추억의 가요' when '노래' then '노래 퀴즈' when '요즘 말' then '요즘 말 테스트'
                 when '예능' then '예능·드라마 소환' when '회사' then '회사 생활' when '상식' then '상식 퀴즈' when '다수결' then '100명에게 물었습니다'
                 when '소수결' then '소수가 이긴다' when '이모지' then '이모지 퀴즈' else '올인 베팅' end),
             type, q, opts, answer, note, false, case when media <> '' then 25 else 15 end, host, '', true, media
      from hq_bank where id = (p_arg->>'id')::int;
    update hq_questions set idx = idx - 999 where idx >= 1000;
    update hq_images set idx = idx - 999 where idx >= 1000;
    update hq_audio set idx = idx - 999 where idx >= 1000;
    update hq_bank set used = used + 1 where id = (p_arg->>'id')::int;

  elsif p_action = 'compose' then
    -- 랜덤 세트 만들기. 순서: 은행 카테고리(추억→요즘 말→예능→상식) → 고정 문항(원래 순서) → 베팅 1문제.
    -- p_arg: {"counts": {"추억": 3, ...}, "min_diff": 2, "bet": true}
    if s.phase <> 'lobby' then raise exception 'ONLY_IN_LOBBY'; end if;
    create temp table _pick (ord serial, round text, type text, q text, opts jsonb, answer int, note text, host text,
      is_bet boolean, limit_sec int, reveal text, pinned boolean, old_idx int, bank_id int, topic text, media text default '') on commit drop;
    -- 카테고리를 순서대로 하나씩 뽑는다. 같은 주제(topic)는 세트 전체에서 한 문제만(앞 카테고리에서 나온 주제는 제외).
    -- 순서도 흐름을 고려: 몸풀기(추억) → 다수결 → 요즘 말 → 가요 → 회사 → 소수결 → 예능 → 상식
    for c_cat, c_round in select * from (values ('추억', '추억 소환'), ('다수결', '100명에게 물었습니다'), ('요즘 말', '요즘 말 테스트'),
                                                ('가요', '추억의 가요'), ('회사', '회사 생활'), ('소수결', '소수가 이긴다'),
                                                ('예능', '예능·드라마 소환'), ('이모지', '이모지 퀴즈'), ('노래', '노래 퀴즈'), ('상식', '상식 퀴즈')) v(cat, r) loop
      insert into _pick (round, type, q, opts, answer, note, host, is_bet, limit_sec, reveal, pinned, bank_id, topic, media)
      select c_round, u.type, u.q, u.opts, u.answer, u.note, u.host, false, case when u.media <> '' then 25 else 15 end, '', false, u.id, nullif(u.topic, ''), u.media
      from (select distinct on (case when b0.topic = '' then b0.id::text else b0.topic end) b0.*
            from hq_bank b0
            where b0.cat = c_cat and not b0.flagged and b0.diff >= coalesce((p_arg->>'min_diff')::int, 1)
              and (b0.topic = '' or b0.topic not in (select topic from _pick where topic is not null))
            order by case when b0.topic = '' then b0.id::text else b0.topic end, b0.used, random()) u
      order by u.used, random()
      limit greatest(coalesce((p_arg->'counts'->>c_cat)::int, 0), 0);
    end loop;
    insert into _pick (round, type, q, opts, answer, note, host, is_bet, limit_sec, reveal, pinned, old_idx, media)
      select round, type, q, opts, answer, note, host, false, limit_sec, reveal, true, idx, media
      from hq_questions where pinned and not is_bet order by idx;
    if coalesce((p_arg->>'bet')::boolean, true) then
      insert into _pick (round, type, q, opts, answer, note, host, is_bet, limit_sec, reveal, pinned, bank_id)
        select '올인 베팅', type, q, opts, answer, note, host, true, 15, '', false, id
        from hq_bank where cat = '베팅' and not flagged and (topic = '' or topic not in (select topic from _pick where topic is not null))
        order by used, random() limit 1;
    end if;
    if not exists (select 1 from _pick) then raise exception 'EMPTY_SET'; end if;
    -- 고정 문항의 사진은 새 번호로 옮기고 나머지 사진은 정리
    -- 최종 순서: 사진 문제는 은행 문제 사이에 고르게 흩고(첫 문제는 사진으로 시작), 그 밖의 고정 문제는 뒤로, 베팅은 맨 끝.
    alter table _pick add column sk numeric;
    n := (select count(*) from _pick where bank_id is not null and not is_bet);
    i := (select count(*) from _pick where pinned and reveal <> '');
    update _pick p set sk = case
      when p.is_bet then 1e9
      when p.bank_id is not null then (select count(*) from _pick x where x.bank_id is not null and not x.is_bet and x.ord < p.ord) * 10 + 5
      when p.reveal <> '' then round((select count(*) from _pick x where x.pinned and x.reveal <> '' and x.ord < p.ord) * n::numeric / greatest(i, 1)) * 10
      else 1e8 + p.ord end
    where true;  -- Supabase 는 WHERE 없는 UPDATE 를 막는다
    create temp table _ord on commit drop as select ord, row_number() over (order by sk, ord) - 1 as idx from _pick;
    create temp table _img on commit drop as
      select o.idx, i.data from _pick p join _ord o on o.ord = p.ord join hq_images i on i.idx = p.old_idx;
    delete from hq_images where true;
    insert into hq_images (idx, data) select idx, data from _img;
    create temp table _aud on commit drop as
      select o.idx, a.data from _pick p join _ord o on o.ord = p.ord join hq_audio a on a.idx = p.old_idx;
    delete from hq_audio where true;
    insert into hq_audio (idx, data) select idx, data from _aud;
    delete from hq_questions where true;
    insert into hq_questions (idx, round, type, q, opts, answer, note, is_bet, limit_sec, host, reveal, pinned, media)
      select o.idx, round, type, q, opts, answer, note, is_bet, limit_sec, host, reveal, pinned, media from _pick p join _ord o on o.ord = p.ord;
    update hq_bank set used = used + 1 where id in (select bank_id from _pick where bank_id is not null);
    return jsonb_build_object('ok', true, 'total', (select count(*) from _pick));

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
  update hq_players p set prev_score = p.score, prev_rank = r.rk, last_bonus = '{}',
    prev_streak = p.streak, prev_max_streak = p.max_streak, prev_active = p.active
  from (select id, rank() over (order by score desc)::int rk from hq_players) r where r.id = p.id;

  -- 다수결: 가장 많이 고른 보기가 정답 / 소수결: (한 명 이상 고른 보기 중) 가장 적게 고른 보기가 정답
  if q.type in ('survey', 'minority') then
    -- 동률이면 같은 수를 받은 보기를 전부 정답으로 인정한다(하나를 무작위로 고르면 억울한 사람이 생긴다)
    with c as (select choice, count(*) n from hq_answers where qi = s.qi and at <= now() group by choice),
         best as (select case when q.type = 'survey' then max(n) else min(n) end m from c)
    select min(choice), coalesce(jsonb_agg(choice order by choice) filter (where choice > (select min(choice) from c, best where c.n = best.m)), '[]')
      into q.answer, q.alt from c, best where c.n = best.m;
    update hq_questions set answer = q.answer, alt = coalesce(q.alt, '[]') where idx = s.qi;
    if q.answer is null then  -- 아무도 안 냈으면 채점(연속 정답·베팅 포함)을 건너뛴다
      update hq_players set last_gain = 0 where true;
      update hq_state set phase = 'answer', updated_at = now() where id = 1;
      return;
    end if;
  end if;

  if q.type = 'poll' then
    update hq_players p set active = true from hq_answers a where a.player_id = p.id and a.qi = s.qi;
  else
    select count(*) into total from hq_players;
    cut := ceil(total * 0.7);
    update hq_players p set
      score = p.score + c.base + c.dbl + c.under + c.combo + c.bet,
      streak = case when c.correct then p.streak + 1 else 0 end,
      max_streak = greatest(p.max_streak, case when c.correct then p.streak + 1 else 0 end),
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
               coalesce(a.choice = q.answer or q.alt @> to_jsonb(a.choice), false) as correct,
               hq_points(a.choice = q.answer or q.alt @> to_jsonb(a.choice), s.q_started_at, a.at, q.limit_sec) as base,
               case when q.is_bet then round(greatest(p2.score, 0) * coalesce(b.pct, 0) / 100.0)::int else 0 end as stake
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
      hq_image(int), hq_react(text), hq_view(uuid), hq_admin(text,text,jsonb) to anon, authenticated;
  end if;
end $$;
-- 예시 문항 15개. 진행자 화면 [문항 편집]에서 바꾼다. R4 사진 퀴즈 2문제는 사진과 보기를 진행자가 채워야 한다.
delete from hq_questions where true;
delete from hq_images where true;
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,limit_sec,host,reveal,pinned) values (0,'추억 소환','ox','2002 월드컵에서 한국은 4강에 올랐다.','[]'::jsonb,0,'4강 신화! 그날 어디서 보셨어요?',false,15,'몸풀기 갑니다! 2002년 그 여름, 다들 기억나시죠? 빨리 누를수록 점수가 높아요!','',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,limit_sec,host,reveal,pinned) values (1,'추억 소환','mc','1988 서울 올림픽의 마스코트는?','["호돌이", "수호랑", "꿈돌이", "반다비"]'::jsonb,0,'꿈돌이는 93 대전 엑스포, 수호랑·반다비는 2018 평창이에요',false,15,'88 올림픽 때 초등학생이셨던 분 손! 마스코트 이름 기억하세요?','',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,limit_sec,host,reveal,pinned) values (2,'추억 소환','mc','삐삐 숫자 "8282"의 뜻은?','["사랑해", "빨리빨리", "잘 자", "보고 싶어"]'::jsonb,1,'"1004"는 천사, "486"은 사랑해',false,15,'삐삐 세대 나와 주세요. 이건 손이 먼저 기억할 거예요!','',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,limit_sec,host,reveal,pinned) values (5,'요즘 말 테스트','ox','"킹받네"는 "기분이 아주 좋다"는 뜻이다.','[]'::jsonb,1,'"열받네"를 더 세게 말한 거예요. 기분 나쁠 때 써요',false,10,'O일까요, X일까요? 단어만 보면 좋아 보이는데요…','',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,limit_sec,host,reveal,pinned) values (6,'예능 소환','mc','"1박 2일" 복불복의 대표 벌칙 음료는?','["까나리 액젓", "홍초", "매실 원액", "사과 식초"]'::jsonb,0,'한 모금이면 바로 표정 관리 실패',false,15,'이제 예능 소환입니다. 일요일 저녁 생각나시죠?','',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,limit_sec,host,reveal,pinned) values (7,'예능 소환','mc','"런닝맨"에서 상대를 탈락시키려면 등에 붙은 무엇을 떼야 할까?','["이름표", "번호표", "스티커", "손목 밴드"]'::jsonb,0,'이름표 뜯기, 해 본 분 계세요?',false,15,'이름표 뜯기! 오늘 회식 끝나고 해 볼까요?','',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,limit_sec,host,reveal,pinned) values (8,'예능 소환','mc','초성 퀴즈! "ㄱㄴㅅㅌㅇ" — 2012년 전 세계가 말춤을 춘 이 노래는?','["강남스타일", "젠틀맨", "챔피언", "새"]'::jsonb,0,'유튜브 조회수 10억을 처음 넘긴 뮤직비디오예요',false,15,'신서유기 초성 퀴즈 스타일로 갑니다!','',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,limit_sec,host,reveal,pinned) values (9,'예능 소환','mc','드라마 "응답하라 1988"의 배경이 된 동네는?','["쌍문동", "신촌", "성수동", "봉천동"]'::jsonb,0,'덕선이네 골목, 쌍문동이었죠',false,15,'응팔 정주행하신 분들은 바로 아실 거예요.','',false);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,limit_sec,host,reveal,pinned) values (10,'사진 퀴즈','mc','확대 사진! 이 연예인은 누구일까요?','["(이름 1)", "(이름 2)", "(이름 3)", "(이름 4)"]'::jsonb,0,'사진이 점점 작아질수록 쉬워지지만 점수는 줄어요',false,20,'화면이 점점 작아집니다. 빨리 알아볼수록 점수가 높아요!','zoom',true);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,limit_sec,host,reveal,pinned) values (11,'사진 퀴즈','mc','어린 시절 사진! 이 아이는 커서 어떤 연예인이 됐을까요?','["(이름 1)", "(이름 2)", "(이름 3)", "(이름 4)"]'::jsonb,0,'떡잎부터 달랐네요',false,20,'이 귀여운 아이가 누구로 자랐을까요? 사진이 점점 선명해집니다!','blur',true);
insert into hq_questions (idx,round,type,q,opts,answer,note,is_bet,limit_sec,host,reveal,pinned) values (14,'올인 베팅','mc','1997년 IMF 때 "금 모으기 운동"으로 모인 금은 약 몇 톤?','["약 50톤", "약 120톤", "약 227톤", "약 500톤"]'::jsonb,2,'약 350만 명이 참여했어요',true,15,'마지막 문제! 지금까지 모은 점수를 걸고 역전을 노려 보세요.','',false);
-- 문제 은행. 다시 실행해도 같은 문제는 중복으로 들어가지 않고 내용만 갱신된다(문제 글 기준).
delete from hq_bank where q in ('1997년 IMF 구제금융을 신청할 당시 대통령은?','MBTI에서 "E"가 뜻하는 것은?','엑셀에서 합계를 구하는 함수는?','초성 퀴즈! "ㄱㄴㅅㅌㅇ", 2012년 전 세계가 말춤을 춘 노래는?','듀스의 멤버는 김성재와 누구?','"잘못된 만남"을 부른 가수는?','함흥냉면은 원래 비빔냉면으로 유명하다.','2018 평창 동계올림픽의 마스코트는?','"포기하면 그 순간이 바로 시합 종료예요." 슬램덩크에서 이 말을 한 사람은?','골프에서 파(Par)보다 2타 적게 치면?','100명에게 물었습니다! 회식 2차로 가장 가고 싶은 곳은?');
delete from hq_bank where cat = '노래' and media not like 'https://%';
-- 보기 순서는 여기서 한 번 섞어서 넣는다(정답이 늘 1번이 되지 않게).
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','2002 월드컵 4강전, 한국의 상대 팀은?','["터키", "스페인", "독일", "이탈리아"]'::jsonb,2,'0:1 패배. 16강 이탈리아, 8강 스페인, 3·4위전은 터키였어요','4강까지는 다 아시죠? 그럼 4강 상대는요?','2002','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','2002 월드컵 16강 이탈리아전, 연장 골든골의 주인공은?','["박지성", "설기현", "황선홍", "안정환"]'::jsonb,3,'설기현 동점골, 안정환 헤딩 골든골!','반지 키스 기억나시는 분?','2002','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',1,'mc','2002 월드컵 한국 대표팀 히딩크 감독의 국적은?','["독일", "네덜란드", "덴마크", "벨기에"]'::jsonb,1,'거스 히딩크, 4강 신화 뒤 명예 국민이 됐어요','히딩크 감독, 어느 나라 사람이었을까요?','2002','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',1,'mc','1988 서울 올림픽의 마스코트는?','["반다비", "꿈돌이", "호돌이", "수호랑"]'::jsonb,2,'꿈돌이는 93 대전 엑스포, 수호랑·반다비는 2018 평창이에요','88 올림픽 마스코트, 기억하세요?','mascot','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','1993 대전 엑스포의 마스코트는?','["수호랑", "꿈돌이", "호돌이", "반다비"]'::jsonb,1,'외계에서 온 아기 요정 콘셉트였어요','수학여행으로 엑스포 다녀오신 분 손!','mascot','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',1,'mc','삐삐 숫자 "8282"의 뜻은?','["잘 자", "보고 싶어", "사랑해", "빨리빨리"]'::jsonb,3,'"1004"는 천사, "486"은 사랑해','삐삐 세대 나와 주세요. 손이 먼저 기억할 거예요!','pager','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','서태지와 아이들의 데뷔곡은?','["하여가", "교실 이데아", "컴백홈", "난 알아요"]'::jsonb,3,'1992년, 회오리 춤의 시작','회오리 춤 추실 수 있는 분?','seotaiji','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','1995년 "귀가시계"라 불린 드라마 "모래시계"의 방송사는?','["EBS", "SBS", "MBC", "KBS"]'::jsonb,1,'방송 시간엔 거리가 텅 빌 정도였어요','이 드라마 할 땐 다들 집에 일찍 들어갔다죠?','sandglass','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','"응답하라 1994"의 주무대는?','["쌍문동 골목", "대학로 극장", "신촌 하숙집", "건대 자취방"]'::jsonb,2,'신촌 하숙집, 쓰레기와 나정이','응사 보신 분들은 바로 아실 거예요.','reply','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',1,'mc','"응답하라 1988"의 배경이 된 동네는?','["신촌", "봉천동", "성수동", "쌍문동"]'::jsonb,3,'덕선이네 골목, 쌍문동이었죠','응팔 정주행하신 분들 손!','reply','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','1994년 드라마 "마지막 승부"의 소재가 된 스포츠는?','["축구", "농구", "배구", "야구"]'::jsonb,1,'장동건·손지창, 그리고 농구 붐','"마지막 승부" 주제곡 흥얼거리실 수 있는 분?','lastgame','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','만화 "슬램덩크" 강백호의 등번호는?','["7번", "4번", "11번", "10번"]'::jsonb,3,'서태웅이 11번, 채치수가 4번이에요','농구 좀 하셨던 분들, 등번호 기억나세요?','slamdunk','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','슬램덩크 명대사 "포기하면 그 순간이 시합 종료예요"의 주인공은?','["채치수", "서태웅", "안 선생님", "강백호"]'::jsonb,2,'북산고 안 선생님의 명대사','인생 명언 하나 갑니다.','slamdunk','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',1,'ox','싸이월드 화폐 이름은 "도토리"였다.','[]'::jsonb,0,'미니홈피 BGM 사려고 충전하셨죠?','도토리 충전해 보신 분?','cyworld','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','스타크래프트에서 "show me the money"를 입력하면?','["유닛이 무적이 된다", "건설이 바로 끝난다", "자원이 생긴다", "맵이 다 보인다"]'::jsonb,2,'PC방 시간당 1,000원이던 시절','PC방 좀 다니신 분들은 바로 아실 겁니다.','starcraft','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',3,'mc','스타크래프트 치트키 "power overwhelming"의 효과는?','["자원 획득", "빠른 건설", "맵 전체 보기", "유닛 무적"]'::jsonb,3,'"black sheep wall"은 맵 보기, "operation cwal"은 빠른 건설','이건 진짜 고수만 압니다.','starcraft','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('요즘 말',2,'mc','"중꺾마"의 뜻은?','["중요한 건 꺾이지 않는 마음", "중간에 꺾으면 마이너스", "중식은 꺾어 먹어야 제맛", "중년은 꺾여도 마음은 청춘"]'::jsonb,0,'2022년 롤드컵 데프트 선수 인터뷰에서 퍼진 말이에요','요즘 말 테스트입니다. 30대는 쉽겠죠?','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('요즘 말',2,'mc','"스불재"의 뜻은?','["스스로 불러온 재앙", "스페셜 불금 재미", "스트레스 불태우는 재택", "스타일 불타는 재력가"]'::jsonb,0,'야근 자청했다가 후회할 때 딱이에요','야근하다 한 번쯤 써 본 말입니다.','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('요즘 말',1,'ox','"킹받네"는 "기분이 아주 좋다"는 뜻이다.','[]'::jsonb,1,'"열받네"를 더 세게 말한 거예요','단어만 보면 좋아 보이는데요…','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('요즘 말',1,'mc','"점메추"의 뜻은?','["점잖게 메모 추가", "점심 메뉴 추천", "점점 메말라 가는 추억", "점수 메기기 추가"]'::jsonb,1,'점심 고민될 때 단톡방에 "점메추!"','이건 우리 매일 하는 거예요.','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('요즘 말',2,'mc','"갓생"의 뜻은?','["갓 쓰고 사는 선비의 삶", "부지런하고 알차게 사는 삶", "신을 믿는 생활", "갓 태어난 신입의 삶"]'::jsonb,1,'"갓생 산다" = 아침 운동하고 책 읽는 그런 삶','오늘 회식은 갓생일까요?','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('요즘 말',3,'mc','"알잘딱깔센"의 뜻은?','["알람 잘 딱 깔고 센스 있게 기상", "알바 잘하면 딱 깔끔한 센터", "알고 보면 잘생긴 딱 깔끔한 센스남", "알아서 잘 딱 깔끔하고 센스 있게"]'::jsonb,3,'일 잘하는 사람의 정석','일 잘하는 사람의 정석!','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('요즘 말',2,'mc','"삼귀다"의 뜻은?','["사귀기 전 썸 타는 단계", "셋이 함께 어울림", "세 번째 사귄 사람", "삼겹살 먹으며 친해짐"]'::jsonb,0,'"사귀다"의 "사(4)"보다 하나 모자란 "삼(3)"','숫자 말장난입니다.','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('요즘 말',3,'mc','"뇌절"의 뜻은?','["머리가 너무 좋아 끊김", "같은 말이나 행동을 질리게 반복함", "갑자기 아이디어가 떠오름", "회의 중 졸음"]'::jsonb,1,'아재 개그 세 번째부터가 뇌절이에요','회식 자리에서 특히 조심해야 할 것!','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('요즘 말',3,'mc','"추구미"의 뜻은?','["추천받은 구내식당 메뉴", "추가로 구매한 미용품", "추억 속 구미호", "내가 추구하는 이미지"]'::jsonb,3,'"내 추구미는 꾸안꾸"처럼 써요','이건 MZ 고수용입니다.','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('요즘 말',2,'mc','"어쩔티비"의 뜻은?','["어쩌다 TV 출연", "어쩌라고, 가서 TV나 봐", "어쩔 수 없이 TV 시청", "어쩐지 TV가 재밌더라"]'::jsonb,1,'"저쩔티비"로 받아치면 고수','이 말 들으면 킹받는 분들 계시죠?','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('요즘 말',3,'mc','"무지성"의 뜻은?','["무지개처럼 다양함", "깊이 생각하지 않고 그냥 함", "지성이 넘쳐흐름", "성실하게 무조건 함"]'::jsonb,1,'"무지성 결제" 같은 데 써요','이 문제는 무지성으로 찍지 마세요!','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('요즘 말',2,'mc','MBTI에서 "T"가 뜻하는 것은?','["직관형", "감정형", "판단형", "사고형"]'::jsonb,3,'"너 T야?" = 공감보다 해결책부터 말하는 사람','"너 T야?" 들어 보신 분?','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',1,'mc','"1박 2일" 복불복의 대표 벌칙 음료는?','["까나리 액젓", "홍초", "사과 식초", "매실 원액"]'::jsonb,0,'한 모금이면 바로 표정 관리 실패','일요일 저녁 생각나시죠?','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',1,'mc','"런닝맨"에서 상대를 탈락시키려면 등에 붙은 무엇을 떼야 할까?','["이름표", "번호표", "스티커", "손목 밴드"]'::jsonb,0,'이름표 뜯기, 해 본 분?','오늘 회식 끝나고 해 볼까요?','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',2,'mc','초성 퀴즈! "ㄱㄴㅅㅌㅇ", 2012년 전 세계를 휩쓴 이 노래는?','["챔피언", "젠틀맨", "새", "강남스타일"]'::jsonb,3,'유튜브 조회수 10억을 처음 넘긴 뮤직비디오','신서유기 초성 퀴즈 스타일로 갑니다!','chosung','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',2,'mc','초성 퀴즈! "ㅁㅎㄷㅈ", 토요일 저녁을 책임졌던 이 예능은?','["무릎팍도사", "무한도전", "미운 우리 새끼", "무엇이든 물어보살"]'::jsonb,1,'"무모한 도전"에서 시작했어요','초성만 보고 맞혀 보세요!','chosung','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',2,'mc','초성 퀴즈! "ㄴㅁㅎㄴ", 유재석의 부캐들이 탄생한 이 예능은?','["냉장고를 부탁해", "나 혼자 산다", "놀라운 토요일", "놀면 뭐하니?"]'::jsonb,3,'유산슬, 유두래곤, 지미유의 고향','부캐 부자 유재석!','chosung','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',2,'mc','"무한도전" 마지막 회가 방송된 해는?','["2018년", "2017년", "2016년", "2019년"]'::jsonb,0,'2018년 3월, 13년 만의 마무리','무도 마지막 회, 보면서 우신 분?','muhan','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',2,'mc','"무한도전" 무한상사에서 유재석의 직급은?','["사장", "과장", "부장", "대리"]'::jsonb,2,'유 부장, 박 차장, 정 과장…','우리 회사 얘기 같은 그 콩트!','muhan','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',2,'mc','"놀면 뭐하니?"에서 유재석의 트로트 가수 이름은?','["유고스타", "지미유", "유산슬", "유두래곤"]'::jsonb,2,'유고스타는 드러머, 유두래곤은 싹쓰리, 지미유는 제작자','"합정역 5번 출구" 아시는 분?','yoo','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',3,'mc','다음 중 "싹쓰리" 멤버가 아닌 사람은?','["유재석", "이효리", "엄정화", "비"]'::jsonb,2,'엄정화는 환불원정대 멤버예요','2020년 여름을 쓸어 담은 그 그룹!','yoo','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',3,'mc','다음 중 "환불원정대" 멤버가 아닌 사람은?','["엄정화", "화사", "선미", "제시"]'::jsonb,2,'엄정화·이효리·제시·화사, 제작자는 지미유','언니들의 그 그룹!','yoo','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',1,'mc','"전국노래자랑"을 34년 동안 진행한 국민 MC는?','["송해", "이상벽", "허참", "임성훈"]'::jsonb,0,'"전국~ 노래자랑!"','일요일 낮 12시 10분의 그분!','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',2,'mc','"가족오락관"을 오래 진행한 MC는?','["이덕화", "송해", "주병진", "허참"]'::jsonb,3,'"몇 대 몇!" 하던 그분','고요 속의 외침, 기억나세요?','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',2,'mc','"오징어 게임" 첫 번째 게임은?','["무궁화 꽃이 피었습니다", "딱지치기", "줄다리기", "구슬치기"]'::jsonb,0,'딱지치기는 게임 전 모집할 때 나왔어요','영희 인형 기억나시죠?','squid','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',2,'mc','"오징어 게임" 주인공 성기훈의 참가 번호는?','["456번", "067번", "218번", "001번"]'::jsonb,0,'1번은 오일남, 67번 강새벽, 218번 조상우','마지막 번호였죠!','squid','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',2,'mc','드라마 "더 글로리"에서 복수를 준비하는 주인공 이름은?','["문동은", "전재준", "박연진", "하도영"]'::jsonb,0,'"연진아~"','"멋지다, 연진아!" 아시는 분?','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',2,'mc','10원짜리 동전에 새겨진 탑은?','["미륵사지 석탑", "첨성대", "다보탑", "석가탑"]'::jsonb,2,'불국사 다보탑이에요','지갑에 10원짜리 있는 분, 보지 마세요!','money','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',3,'mc','1만 원권 뒷면에 그려진 것은?','["매화", "다보탑", "혼천의", "거북선"]'::jsonb,2,'조선의 천체 관측기구, 혼천의','지금 지갑 꺼내면 반칙입니다!','money','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',2,'mc','우리나라 최초의 고속도로는?','["영동고속도로", "호남고속도로", "경인고속도로", "경부고속도로"]'::jsonb,2,'1968년 12월, 서울~인천 구간 개통','드라이브 좋아하시는 분들!','highway','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',2,'mc','골프에서 파(Par)보다 1타 적게 치면?','["버디", "이글", "알바트로스", "보기"]'::jsonb,0,'1타 많으면 보기예요','주말 골퍼분들 나오세요!','golf','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',2,'mc','바둑판의 가로·세로 줄 수는?','["21줄", "17줄", "15줄", "19줄"]'::jsonb,3,'19×19 = 361개의 교차점','"응답하라 1988" 택이를 떠올려 보세요.','baduk','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',2,'mc','한국 프로야구가 출범한 해는?','["1982년", "1979년", "1988년", "1985년"]'::jsonb,0,'"어린이에게 꿈을, 젊은이에게 낭만을"','야구팬들 준비되셨나요?','baseball','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',3,'mc','야구에서 "사이클링 히트"란?','["한 경기 무안타", "한 경기 단타·2루타·3루타·홈런", "3연타석 홈런", "한 이닝 타자 일순"]'::jsonb,1,'KBO에서도 손에 꼽을 만큼 드문 기록','야구 고수만 아는 용어!','baseball','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',1,'mc','마라톤 풀코스의 거리는?','["42.195km", "40km", "45km", "42km"]'::jsonb,0,'1908년 런던 올림픽에서 처음 쓰인 거리예요','회식 다음 날 아침 조깅 하실 분?','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',2,'mc','월드컵 최다 우승국은?','["브라질", "이탈리아", "독일", "아르헨티나"]'::jsonb,0,'브라질 5회 우승','축구 좋아하시는 분들 나오세요!','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',2,'mc','올림픽 오륜기에 없는 색은?','["초록", "노랑", "파랑", "보라"]'::jsonb,3,'파랑·노랑·검정·초록·빨강, 그리고 흰 바탕','오륜기 떠올려 보세요!','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',2,'ox','라거 맥주는 비교적 낮은 온도에서 하면발효로 만든다.','[]'::jsonb,0,'에일은 상면발효, 라거는 하면발효','맥주 한 잔 드시면서 풀어 보세요!','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',2,'ox','"샴페인"은 프랑스 상파뉴 지역의 이름에서 왔다.','[]'::jsonb,0,'원칙적으로 상파뉴산만 샴페인이라 불러요','건배 전에 한 문제!','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',3,'mc','국보 1호로 불렸던 문화재는?','["흥인지문", "석굴암", "훈민정음", "숭례문"]'::jsonb,3,'2021년부터 지정 번호는 없어졌어요','남대문 하면 떠오르는 그것!','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',2,'mc','"너에게로 또다시"를 부른 가수는?','["이승환", "변진섭", "윤종신", "신승훈"]'::jsonb,1,'"발라드의 황태자" 변진섭의 대표곡','노래방 단골곡 하나 갑니다!','byun','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',2,'mc','신승훈의 데뷔곡은?','["I Believe", "처음 그 느낌처럼", "보이지 않는 사랑", "미소 속에 비친 그대"]'::jsonb,3,'1990년, 발라드 황제의 시작','발라드 황제의 첫 곡은?','shinseunghun','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',2,'mc','H.O.T.의 데뷔곡은?','["캔디", "행복", "빛", "전사의 후예"]'::jsonb,3,'1996년 데뷔. "캔디"는 그다음 히트곡','1세대 아이돌 갑니다!','idol1','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',2,'mc','god의 데뷔곡은?','["촛불하나", "길", "거짓말", "어머님께"]'::jsonb,3,'"어머님은 짜장면이 싫다고 하셨어"','짜장면 하면 떠오르는 그 노래!','idol1','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',2,'mc','S.E.S.의 데뷔곡은?','["꿈을 모아서", "Dreams Come True", "Just A Feeling", "I''m Your Girl"]'::jsonb,3,'1997년 데뷔','1세대 걸그룹입니다!','idol2','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',2,'mc','핑클의 데뷔곡은?','["블루레인", "Now", "영원한 사랑", "내 남자친구에게"]'::jsonb,0,'1998년 데뷔, 효리·주현·유리·진','핑클 팬클럽 출신 계세요?','idol2','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',1,'mc','"해변의 여인"을 부른 그룹은?','["쿨", "터보", "룰라", "클론"]'::jsonb,0,'여름 하면 쿨!','여름 노래의 정석!','summer','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',1,'mc','"꿍따리 샤바라"를 부른 그룹은?','["쿨", "듀스", "클론", "룰라"]'::jsonb,2,'구준엽·강원래','다 같이 꿍따리 샤바라~','clon','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',2,'mc','"날개 잃은 천사"를 부른 그룹은?','["룰라", "터보", "쿨", "R.ef"]'::jsonb,0,'1995년 대히트, 룰라 전성기!','룰라 춤 기억나세요?','roo','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',2,'mc','"나를 돌아봐", "여름 안에서"를 부른 2인조는?','["지누션", "듀스", "클론", "쿨"]'::jsonb,1,'이현도·김성재의 힙합 듀오','힙합 1세대!','deux','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',3,'mc','다음 중 서태지와 아이들 멤버가 아닌 사람은?','["이주노", "서태지", "이현도", "양현석"]'::jsonb,2,'이현도는 듀스 멤버예요','이건 헷갈리실걸요?','deux','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',2,'mc','015B의 대표곡은?','["슬픈 언약식", "아주 오래된 연인들", "미소 속에 비친 그대", "너에게로 또다시"]'::jsonb,1,'정석원·장호일의 프로젝트 그룹, 1990년 데뷔','공일오비 하면 이 노래!','015b','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',2,'mc','김광석의 노래가 아닌 것은?','["이등병의 편지", "서른 즈음에", "사랑했지만", "너에게로 또다시"]'::jsonb,3,'"너에게로 또다시"는 변진섭 노래예요','노래방 단골곡 후보!','kks','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',3,'mc','이문세의 "광화문 연가"를 작곡한 사람은?','["윤상", "이영훈", "김현철", "유재하"]'::jsonb,1,'이문세 명곡 대부분을 만든 작곡가','진짜 음악 애호가만 아는 문제!','lms','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('회사',1,'mc','"ASAP"의 뜻은?','["As Simple As Possible", "As Soon As Possible", "After Sales After Purchase", "All Staff All Present"]'::jsonb,1,'"가능한 한 빨리"인데, 보통은 "지금 당장"','업무 메일 단골 단어!','asap','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('회사',3,'mc','이메일의 "CC"는 무엇의 줄임말?','["Carbon Copy", "Common Contact", "Central Copy", "Copy Check"]'::jsonb,0,'먹지(카본지)로 복사하던 시절에서 온 말. BCC는 숨은 참조','매일 쓰는 참조, 원래 뜻은요?','email','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('회사',2,'mc','이메일에서 다른 수신자에게 보이지 않게 넣는 것은?','["전달(FW)", "숨은 참조(BCC)", "회신(RE)", "참조(CC)"]'::jsonb,1,'BCC = Blind Carbon Copy','실수하면 큰일 나는 그것!','email','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('회사',2,'mc','근로기준법상 1주 최대 근로시간(연장근로 포함)은?','["40시간", "52시간", "60시간", "48시간"]'::jsonb,1,'기본 40시간 + 연장 12시간','칼퇴 요정들 주목!','worklaw','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('회사',3,'mc','입사 1년 미만 직원이 한 달 개근하면 생기는 연차는?','["2일", "없음", "1일", "0.5일"]'::jsonb,2,'1년 미만은 한 달 개근마다 1일씩 생겨요','막내들 이거 꼭 아세요!','worklaw','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('회사',2,'mc','엑셀에서 조건에 맞는 값만 더하는 함수는?','["COUNTIF", "VLOOKUP", "SUMIF", "SUM"]'::jsonb,2,'=SUMIF(범위, 조건, 합계범위)','엑셀 장인 나와 주세요!','excel','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('회사',2,'mc','엑셀 함수 VLOOKUP의 "V"가 뜻하는 것은?','["Value", "Vertical", "Variable", "Visual"]'::jsonb,1,'세로 방향으로 찾는다는 뜻. 가로는 HLOOKUP','엑셀 고수 판별 문제!','excel','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('회사',2,'mc','파워포인트 슬라이드 쇼를 처음부터 시작하는 단축키는?','["Ctrl+P", "F12", "F1", "F5"]'::jsonb,3,'Shift+F5는 현재 슬라이드부터','발표 직전에 꼭 필요한 그 키!','ppt','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('회사',2,'mc','윈도우에서 자리 비울 때 화면을 잠그는 단축키는?','["윈도우 키 + D", "Ctrl + L", "윈도우 키 + L", "Alt + F4"]'::jsonb,2,'보안 점검 때 단골 지적 사항!','자리 비울 때 꼭 누르세요!','winkey','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('회사',1,'mc','"KPI"의 "K"는?','["Key", "Knowledge", "Korea", "Keep"]'::jsonb,0,'Key Performance Indicator, 핵심 성과 지표','평가 시즌 생각나시죠?','kpi','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('회사',2,'mc','회사에서 말하는 "R&R"의 뜻은?','["보상과 승진", "규칙과 규정", "역할과 책임", "보고와 결재"]'::jsonb,2,'Roles and Responsibilities','"R&R 정리해서 주세요"의 그 R&R!','rnr','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('회사',2,'mc','"OKR"의 "O"가 뜻하는 것은?','["Output", "Operations", "Overtime", "Objectives"]'::jsonb,3,'Objectives and Key Results','요즘 많이 쓰는 목표 관리 방식!','kpi','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',2,'mc','소주 "참이슬"을 만드는 회사는?','["무학", "하이트진로", "보해양조", "롯데칠성"]'::jsonb,1,'"처음처럼"은 롯데칠성','잔 비우기 전에 한 문제!','soju','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',2,'mc','부대찌개로 유명한 도시는?','["춘천", "의정부", "전주", "안동"]'::jsonb,1,'의정부 부대찌개 거리','술안주로도 최고!','foodcity','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',1,'mc','닭갈비로 유명한 도시는?','["춘천", "안동", "전주", "통영"]'::jsonb,0,'춘천 닭갈비, 막국수까지 한 세트','쉬운 문제 하나 드립니다!','foodcity','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',2,'ox','함흥냉면은 보통 비빔(회)냉면으로 즐긴다.','[]'::jsonb,0,'함흥은 비빔(회)냉면, 평양은 물냉면','냉면파 손!','naengmyeon','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',2,'mc','손흥민이 프리미어리그 득점왕에 오른 시즌은?','["2019-20", "2022-23", "2020-21", "2021-22"]'::jsonb,3,'23골로 공동 득점왕, 아시아 선수 최초','축구 좋아하시는 분들 나오세요!','son','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',2,'mc','박찬호가 메이저리그에 처음 입단한 팀은?','["뉴욕 양키스", "LA 다저스", "텍사스 레인저스", "샌디에이고 파드리스"]'::jsonb,1,'1994년 다저스로 데뷔','새벽에 박찬호 경기 보신 분?','mlb','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',1,'mc','김연아가 밴쿠버 올림픽에서 금메달을 딴 해는?','["2014년", "2006년", "2010년", "2008년"]'::jsonb,2,'당시 세계 기록 228.56점','그날 다 같이 울었던 그 경기!','yuna','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',3,'mc','박세리가 연못에 맨발로 들어가 샷을 한 US여자오픈 우승은 몇 년?','["2002년", "1996년", "1998년", "2000년"]'::jsonb,2,'IMF 시절 온 국민에게 힘을 준 장면','맨발 투혼, 기억하시죠?','golf','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('상식',2,'mc','차범근이 활약한 독일 프로축구 리그는?','["라리가", "분데스리가", "세리에 A", "프리미어리그"]'::jsonb,1,'"차붐", 프랑크푸르트와 레버쿠젠','레전드 중의 레전드!','bundes','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',1,'mc','2002 월드컵 응원 "대~한민국!" 뒤에 치는 박수는 몇 번?','["6번", "4번", "5번", "3번"]'::jsonb,2,'짝짝 짝 짝짝!','다 같이 한번 해 볼까요?','2002','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','국내에 처음 정식 출시된 아이폰은?','["아이폰 4", "아이폰 3G", "1세대 아이폰", "아이폰 3GS"]'::jsonb,3,'2009년 11월 KT로 출시','스마트폰 처음 산 날 기억나세요?','iphone','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','카카오톡이 처음 출시된 해는?','["2010년", "2014년", "2012년", "2008년"]'::jsonb,0,'문자 요금 아끼던 그 시절','단톡방의 시작!','kakao','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','"포켓몬 GO" 열풍으로 사람들이 속초로 몰려간 해는?','["2014년", "2020년", "2016년", "2018년"]'::jsonb,2,'출시 초기 국내에선 속초 일대만 됐어요','속초 가 보신 분 손!','pokemon','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','2018 평창 동계올림픽(패럴림픽 제외)의 마스코트는?','["호돌이", "꿈돌이", "반다비", "수호랑"]'::jsonb,3,'반다비는 패럴림픽 마스코트','평창 하면 떠오르는 하얀 호랑이!','mascot','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','BTS가 데뷔한 해는?','["2015년", "2013년", "2017년", "2011년"]'::jsonb,1,'"No More Dream"으로 데뷔','아미 계세요?','bts','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','BTS가 미국 빌보드 핫100에서 처음 1위를 한 곡은?','["Fake Love", "DNA", "Dynamite", "Butter"]'::jsonb,2,'2020년, 한국 가수 최초','빌보드 1위의 그 곡!','bts','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','영화 "기생충"이 아카데미 작품상을 받은 해는?','["2019년", "2020년", "2021년", "2018년"]'::jsonb,1,'비영어 영화 최초의 작품상','"오스카는 로컬 영화제" 명언!','parasite','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',3,'mc','국내 개봉 영화 역대 관객 수 1위는?','["명량", "국제시장", "극한직업", "신과함께-죄와 벌"]'::jsonb,0,'2014년 개봉, 약 1,761만 명','영화 좋아하시는 분들!','boxoffice','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','"애기야, 가자!"라는 명대사가 나온 드라마는?','["풀하우스", "미안하다 사랑한다", "파리의 연인", "내 이름은 김삼순"]'::jsonb,2,'2004년 박신양·김정은','이 대사 따라 해 보신 분?','drama2000','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','"오징어 게임" 시즌 1이 공개된 해는?','["2021년", "2019년", "2020년", "2022년"]'::jsonb,0,'넷플릭스 전 세계 1위','달고나 뽑기 해 보신 분?','squid','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('다수결',2,'survey','100명에게 물었습니다! 점심 메뉴로 가장 무난한 것은?','["김치찌개", "돈가스", "국밥", "샐러드"]'::jsonb,null,'점메추는 이걸로!','남들이 뭘 고를지 맞히세요!','s2','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('다수결',2,'survey','100명에게 물었습니다! 월요일 아침 출근하면 가장 먼저 하는 일은?','["커피 사기", "메일 확인", "한숨 쉬기", "주말 얘기하기"]'::jsonb,null,'다들 비슷하죠?','가장 많은 사람이 고른 답이 정답!','s3','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('다수결',2,'survey','100명에게 물었습니다! 회사에서 가장 듣기 싫은 말은?','["잠깐 얘기 좀 할까?", "이거 급한데…", "내일까지 될까?", "다시 해 볼까?"]'::jsonb,null,'공감 백 배','오늘만큼은 솔직하게!','s4','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('다수결',2,'survey','100명에게 물었습니다! 로또 1등에 당첨되면 회사는?','["바로 퇴사", "조용히 계속 다닌다", "1년 뒤 퇴사", "부서 회식부터 쏜다"]'::jsonb,null,'다들 솔직하게!','정답은 여러분 손에!','s5','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('다수결',2,'survey','100명에게 물었습니다! 치킨 하면?','["후라이드", "양념", "간장", "반반"]'::jsonb,null,'치킨은 진리','국민 투표 갑니다!','s6','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('다수결',2,'survey','100명에게 물었습니다! 탕수육은?','["부먹", "찍먹", "아무거나", "탕수육 안 먹음"]'::jsonb,null,'영원한 논쟁','부먹 찍먹, 오늘 결판!','s7','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('다수결',2,'survey','100명에게 물었습니다! 여름휴가로 가장 가고 싶은 곳은?','["바다", "산", "해외", "집"]'::jsonb,null,'휴가 계획 세우셨어요?','다수결로 맞혀 보세요!','s8','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('소수결',2,'minority','소수가 이긴다! 숫자 하나를 고르세요. 가장 적게 고른 숫자가 정답!','["1", "2", "3", "4"]'::jsonb,null,'남들과 반대로 가야 이깁니다','일본 예능에서 온 심리 게임! 남들이 안 고를 걸 고르세요.','m1','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('소수결',2,'minority','소수가 이긴다! 가장 적게 고른 과일이 정답!','["사과", "바나나", "딸기", "두리안"]'::jsonb,null,'뻔한 선택은 위험해요!','다들 두리안 고를 것 같죠? 그럼 반대로!','m2','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('소수결',2,'minority','소수가 이긴다! 가장 적게 고른 색이 정답!','["빨강", "파랑", "노랑", "초록"]'::jsonb,null,'심리전의 승자는?','눈치 싸움 시작합니다!','m3','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('소수결',2,'minority','소수가 이긴다! 가장 적게 고른 술이 정답!','["소주", "맥주", "막걸리", "와인"]'::jsonb,null,'오늘 소수파는 누구?','술자리에서 하는 눈치 게임!','m4','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('소수결',2,'minority','소수가 이긴다! 가장 적게 고른 요일이 정답!','["월요일", "수요일", "금요일", "일요일"]'::jsonb,null,'남들이 피할 요일을 골랐어야죠!','눈치 싸움 2라운드!','m5','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',2,'mc','2009년 "Gee"를 부른 그룹은?','["2NE1", "소녀시대", "카라", "원더걸스"]'::jsonb,1,'"Gee Gee Gee Gee baby baby"','2000년대 걸그룹 갑니다!','snsd','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',2,'mc','2007년 "Tell Me"로 전국에 춤 열풍을 일으킨 그룹은?','["카라", "티아라", "소녀시대", "원더걸스"]'::jsonb,3,'"텔미 텔미 테테테테테 텔미"','이 춤 추실 수 있는 분?','wondergirls','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',2,'mc','동방신기의 데뷔곡은?','["주문 (MIROTIC)", "풍선", "Rising Sun", "HUG"]'::jsonb,3,'2004년 데뷔','2000년대 아이돌 대표 주자!','tvxq','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',2,'mc','"가시"(2005)를 부른 밴드는?','["부활", "버즈", "YB", "넬"]'::jsonb,1,'노래방 고음 도전곡의 단골','노래방에서 목 나가던 그 노래!','buzz','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('가요',1,'mc','"돌아와요 부산항에"를 부른 가수는?','["송대관", "남진", "나훈아", "조용필"]'::jsonb,3,'가왕 조용필의 대표곡','세대 불문 명곡!','choyongpil','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',2,'mc','"슈퍼스타K2"(2010)의 우승자는?','["존박", "강승윤", "장재인", "허각"]'::jsonb,3,'오디션 열풍의 시작','오디션 프로그램 좋아하셨던 분?','superstark','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',2,'mc','드라마 "대장금"(2003)에서 장금 역을 맡은 배우는?','["고현정", "전도연", "이영애", "김혜수"]'::jsonb,2,'한류 초기의 대표작','"홍시 맛이 나서 홍시라 생각했사온데"','janggeum','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',1,'mc','"나 혼자 산다"를 방송하는 방송사는?','["SBS", "KBS", "tvN", "MBC"]'::jsonb,3,'금요일 밤의 그 프로','쉬운 문제 하나!','nahonja','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','드라마 "꽃보다 남자"(2009)에서 구준표 역을 맡은 배우는?','["김범", "김현중", "김준", "이민호"]'::jsonb,3,'F4 신드롬','F4 기억하세요?','boysoverflowers','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','드라마 "사랑이 뭐길래"(1991)에서 "대발이" 역을 맡은 배우는?','["최수종", "최민수", "차인표", "이덕화"]'::jsonb,1,'시청률 60%를 넘긴 국민 드라마','50대 선배님들의 국민 드라마!','daebal','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('추억',2,'mc','1986년 아시안게임이 열린 도시는?','["서울", "베이징", "부산", "도쿄"]'::jsonb,0,'88 올림픽 2년 전','88 올림픽 직전의 큰 대회!','asiangames','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('다수결',2,'survey','100명에게 물었습니다! 회식 1차 메뉴로 최고는?','["삼겹살", "회", "소고기", "치킨"]'::jsonb,null,'다음 회식 메뉴는 이걸로!','오늘 메뉴 만족하셨나요?','s9','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('다수결',2,'survey','100명에게 물었습니다! 출근길에 가장 많이 하는 것은?','["음악 듣기", "유튜브 보기", "잠", "뉴스 보기"]'::jsonb,null,'출근길 풍경 그대로','다들 비슷하겠죠?','s10','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('다수결',2,'survey','100명에게 물었습니다! 주말에 가장 많이 하는 것은?','["낮잠", "운동", "외출", "집안일·육아"]'::jsonb,null,'주말은 짧다','주말 얘기 나오면 다들 웃죠?','s11','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('다수결',2,'survey','100명에게 물었습니다! 가장 받고 싶은 회사 복지는?','["재택근무", "보너스", "휴가 추가", "점심 지원"]'::jsonb,null,'인사팀 보고 있나요?','인사팀에 전달하겠습니다!','s12','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('소수결',2,'minority','소수가 이긴다! 가장 적게 고른 커피가 정답!','["아메리카노", "라떼", "바닐라라떼", "아이스티"]'::jsonb,null,'카페 주문도 심리전','눈치 싸움 갑니다!','m6','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('소수결',2,'minority','소수가 이긴다! 가장 적게 고른 계절이 정답!','["봄", "여름", "가을", "겨울"]'::jsonb,null,'심리전의 승자는?','남들이 안 고를 계절은?','m7','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('소수결',2,'minority','소수가 이긴다! 가장 적게 고른 동물이 정답!','["강아지", "고양이", "토끼", "햄스터"]'::jsonb,null,'반려동물 심리전','눈치껏 골라 보세요!','m8','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('소수결',2,'minority','소수가 이긴다! 가장 적게 고른 숫자가 정답!','["5", "6", "7", "8"]'::jsonb,null,'숫자 심리전 2탄','이번엔 5부터 8까지!','m9','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('소수결',2,'minority','소수가 이긴다! 가장 적게 고른 편의점이 정답!','["GS25", "CU", "세븐일레븐", "이마트24"]'::jsonb,null,'퇴근길 편의점 심리전','남들이 안 갈 편의점은?','m10','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('베팅',3,'mc','카카오톡이 처음 출시된 해는?','["2010년", "2014년", "2012년", "2008년"]'::jsonb,0,'2010년 3월 출시','마지막 문제! 30대에게 유리한 역전 찬스!','kakao','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('베팅',3,'mc','영화 "기생충"이 아카데미 작품상을 받은 해는?','["2019년", "2020년", "2021년", "2018년"]'::jsonb,1,'비영어 영화 최초','마지막 문제! 점수를 걸고 갑니다.','parasite','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('베팅',3,'mc','인천국제공항이 문을 연 해는?','["2003년", "1998년", "2001년", "2005년"]'::jsonb,2,'2001년 3월 개항','마지막 문제! 걸 만큼 걸어 보세요.','airport','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('베팅',3,'mc','청계천 복원 공사가 끝나 개통된 해는?','["2007년", "2005년", "2002년", "2010년"]'::jsonb,1,'2005년 10월 개통','마지막 문제! 올인하실 분?','cheonggye','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('베팅',3,'mc','2018 평창 동계올림픽이 열린 달은?','["3월", "2월", "12월", "1월"]'::jsonb,1,'2018년 2월 9~25일','마지막 문제! 역전의 기회!','mascot','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('노래',2,'mc','🎵 지금 나오는 노래의 제목은?','["해변의 여인", "바다의 왕자", "운명", "애상"]'::jsonb,0,'쿨 「해변의 여인」(1997)','노래 틀게요! 앞부분만 듣고 맞혀 보세요.','m_cool','https://youtu.be/x28aE-d2chY') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('노래',2,'mc','🎵 지금 나오는 노래의 제목은?','["행복", "전사의 후예", "빛", "캔디"]'::jsonb,3,'H.O.T. 「캔디」(1996)','1세대 아이돌 노래!','idol1','https://youtu.be/BaQDN_Ex9L4') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('노래',2,'mc','🎵 지금 나오는 노래의 제목은?','["길", "어머님께", "촛불하나", "거짓말"]'::jsonb,1,'god 「어머님께」(1999)','짜장면이 싫다고 하셨어~','idol2','https://youtu.be/6H_IilsR6Fo') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('노래',2,'mc','🎵 지금 나오는 노래의 제목은?','["Nobody", "So Hot", "Tell Me", "Irony"]'::jsonb,2,'원더걸스 「Tell Me」(2007)','이 노래 나오면 다들 손 흔드시죠?','wondergirls','https://youtu.be/0wX6er00xrE') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('노래',2,'mc','🎵 지금 나오는 노래의 제목은?','["다시 만난 세계", "Gee", "소원을 말해봐", "Oh!"]'::jsonb,1,'소녀시대 「Gee」(2009)','2000년대 걸그룹 대표곡!','snsd','https://youtu.be/qizghQs4K6E') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('노래',2,'mc','🎵 지금 나오는 노래의 제목은?','["우리는", "굴레를 벗어나", "여름 안에서", "나를 돌아봐"]'::jsonb,2,'듀스 「여름 안에서」(1994)','여름 노래 하나 더!','m_deux','https://youtu.be/_HsRbUaVw5c') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('노래',1,'mc','🎵 지금 나오는 노래의 제목은?','["강남스타일", "챔피언", "젠틀맨", "새"]'::jsonb,0,'싸이 「강남스타일」(2012)','이건 다들 아시죠?','chosung','https://youtu.be/9bZkp7q19f0') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('노래',2,'mc','🎵 지금 나오는 노래의 제목은?','["Dynamite", "DNA", "Fake Love", "Butter"]'::jsonb,0,'BTS 「Dynamite」(2020)','30대 막내들 차례!','bts','https://youtu.be/OiMWFojB9Ok') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('노래',2,'mc','🎵 지금 나오는 노래의 제목은?','["나에게로 떠나는 여행", "겁쟁이", "남자를 몰라", "가시"]'::jsonb,3,'버즈 「가시」(2005)','노래방 고음 도전곡!','buzz','https://youtu.be/KlIzxf3ViLY') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('노래',2,'mc','🎵 지금 나오는 노래의 제목은?','["머피의 법칙", "미녀와 야수", "런 투 유", "DOC와 춤을"]'::jsonb,3,'DJ DOC 「DOC와 춤을」(1997)','젓가락 행진곡 춤 준비!','m_doc','https://youtu.be/tV4PQOGJo3U') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('노래',2,'mc','🎵 지금 나오는 노래의 제목은?','["도시의 법칙", "꿍따리 샤바라", "초련", "난"]'::jsonb,1,'클론 「꿍따리 샤바라」(1996)','다 같이 꿍따리 샤바라!','clon','https://youtu.be/lJqqvP4lUb8') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('이모지',2,'mc','이모지 퀴즈! 🧟 🚆 💨 이 영화는?','["부산행", "반도", "킹덤", "지금 우리 학교는"]'::jsonb,0,'공유 주연, 2016년 천만 영화','이모지만 보고 맞혀 보세요!','e_busan','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('이모지',1,'mc','이모지 퀴즈! 🦑 🎮 💰 이 드라마는?','["머니게임", "더 글로리", "D.P.", "오징어 게임"]'::jsonb,3,'456억을 건 생존 게임','이건 쉽죠?','squid','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('이모지',2,'mc','이모지 퀴즈! 🍗 🚔 🕵️ 이 영화는?','["범죄도시", "베테랑", "투캅스", "극한직업"]'::jsonb,3,'"지금까지 이런 맛은 없었다"','치킨 냄새 나는 영화!','e_chicken','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('이모지',2,'mc','이모지 퀴즈! 🐋 ⚖️ 👩‍💼 이 드라마는?','["슬기로운 의사생활", "빈센조", "이상한 변호사 우영우", "비밀의 숲"]'::jsonb,2,'"우영우, 거꾸로 해도 우영우"','고래 좋아하는 그 변호사!','e_woo','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('이모지',2,'mc','이모지 퀴즈! 🪂 🇰🇵 ❤️ 이 드라마는?','["미스터 션샤인", "태양의 후예", "사랑의 불시착", "도깨비"]'::jsonb,2,'패러글라이딩 사고로 북한에 불시착','현빈·손예진의 그 드라마!','e_crash','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('이모지',2,'mc','이모지 퀴즈! 🗡️ 👰 🍂 이 드라마는?','["킹덤", "도깨비", "호텔 델루나", "구미호뎐"]'::jsonb,1,'"날이 좋아서, 날이 좋지 않아서…"','공유·김고은의 그 드라마!','e_goblin','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('이모지',2,'mc','이모지 퀴즈! 👻 🏨 🌙 이 드라마는?','["호텔 델루나", "도깨비", "오 나의 귀신님", "주군의 태양"]'::jsonb,0,'아이유·여진구, 귀신 전용 호텔','이번엔 귀신 호텔!','e_delluna','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('이모지',2,'mc','이모지 퀴즈! 🏚️ ⬇️ 🪨 💸 이 영화는?','["올드보이", "살인의 추억", "버닝", "기생충"]'::jsonb,3,'반지하, 그리고 수석','아카데미 그 영화!','parasite','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('이모지',3,'mc','이모지 퀴즈! 🍲 👑 👩‍🍳 이 드라마는?','["동이", "대장금", "상도", "허준"]'::jsonb,1,'"홍시 맛이 나서 홍시라 생각한 것이온데"','50대 선배님들 유리!','janggeum','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',2,'mc','초성 퀴즈! "ㄴ ㅎㅈ ㅅㄷ" 금요일 밤 이 예능은?','["놀면 뭐하니?", "남자의 자격", "나 혼자 산다", "냉장고를 부탁해"]'::jsonb,2,'무지개 회원들','초성만 보고 맞혀 보세요!','chosung2','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',2,'mc','초성 퀴즈! "ㅅㄹㅇ ㅂㅅㅊ" 이 드라마는?','["시를 잊은 그대에게", "쌈, 마이웨이", "사랑의 불시착", "사랑의 온도"]'::jsonb,2,'현빈·손예진','드라마 초성 갑니다!','e_crash','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('예능',2,'mc','초성 퀴즈! "ㅇㄷㅎㄹ 1988" 쌍문동 골목 드라마는?','["우리들의 블루스", "응급남녀", "은밀하게 위대하게", "응답하라 1988"]'::jsonb,3,'덕선이, 택이, 정환이','이건 너무 쉬운가요?','reply','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('다수결',2,'survey','100명에게 물었습니다! 짜장면 vs 짬뽕?','["짜장면", "짬뽕", "볶음밥", "짬짜면"]'::jsonb,null,'평생의 고민','중국집 영원한 논쟁!','s13','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('다수결',2,'survey','100명에게 물었습니다! 민트초코, 어떻게 생각하세요?','["최고의 맛", "치약 맛", "가끔은 괜찮다", "먹어 본 적 없다"]'::jsonb,null,'민초단 vs 반민초단','민초단 손 들어 보세요!','s14','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('다수결',2,'survey','100명에게 물었습니다! 술 마신 다음 날 해장 메뉴는?','["국밥", "라면", "콩나물국", "커피 한 잔"]'::jsonb,null,'내일 아침 메뉴는 정해졌네요','내일을 위한 질문!','s15','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('다수결',2,'survey','100명에게 물었습니다! 하나만 고른다면 갖고 싶은 초능력은?','["순간이동", "투명인간", "시간 멈추기", "마음 읽기"]'::jsonb,null,'출퇴근엔 순간이동이죠','상상만 해도 즐거운 질문!','s16','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('다수결',2,'survey','100명에게 물었습니다! 노래방 첫 곡으로 고르는 장르는?','["발라드", "댄스", "트로트", "안 부르고 탬버린"]'::jsonb,null,'탬버린 담당 꼭 있죠','노래방 가면 다들 뭐부터?','s17','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('다수결',2,'survey','100명에게 물었습니다! 무인도에 딱 하나만 가져간다면?','["스마트폰", "라면 한 박스", "맥가이버 칼", "친한 친구"]'::jsonb,null,'배터리는 어쩌시려고요','생존 본능 테스트!','s18','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('소수결',2,'minority','소수가 이긴다! 가장 적게 고른 라면이 정답!','["신라면", "진라면", "너구리", "짜파게티"]'::jsonb,null,'라면 심리전','다들 신라면 고를까요?','m11','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('소수결',2,'minority','소수가 이긴다! 가장 적게 고른 나라가 정답!','["일본", "미국", "프랑스", "몽골"]'::jsonb,null,'여행지 심리전','몽골이 정답일 것 같죠?','m12','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('소수결',2,'minority','소수가 이긴다! 가장 적게 고른 알파벳이 정답!','["A", "B", "C", "D"]'::jsonb,null,'완전 운? 아니면 심리전?','눈치 싸움 끝판왕!','m13','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('소수결',2,'minority','소수가 이긴다! 가장 적게 고른 표정이 정답!','["😀", "😭", "😡", "😴"]'::jsonb,null,'오늘 기분 심리전','지금 내 기분 말고, 남들이 안 고를 표정!','m14','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('노래',2,'mc','🎵 지금 나오는 노래의 제목은?','["현명한 선택", "헤어지는 중입니다", "Tears", "보낼 수밖에 없는 난"]'::jsonb,2,'소찬휘 「Tears」(2000), 전설의 고음','노래방 고음 끝판왕!','m_tears','https://youtu.be/jhy-MexJiuA') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('노래',2,'mc','🎵 지금 나오는 노래의 제목은?','["빙고", "버스 안에서", "도시 탈출", "슬픈 언약식"]'::jsonb,1,'자자 「버스 안에서」(1996)','다 같이 박수!','m_zaza','https://youtu.be/sZ0e2k-AuxA') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('노래',2,'mc','🎵 지금 나오는 노래의 제목은?','["실연", "파란", "비몽", "순정"]'::jsonb,3,'코요태 「순정」(1999)','코요태 하면 이 노래!','m_koyote','https://youtu.be/CHiizjoys1Q') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('노래',2,'mc','🎵 지금 나오는 노래의 제목은?','["자옥아", "황진이", "빈 잔", "무조건"]'::jsonb,3,'박상철 「무조건」(2005)','트로트 한 곡 갑니다!','m_trot','https://youtu.be/G_KNxk_q8PU') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('노래',2,'mc','🎵 지금 나오는 노래의 제목은?','["하루하루", "마지막 인사", "붉은 노을", "거짓말"]'::jsonb,3,'빅뱅 「거짓말」(2007)','2000년대 길거리 BGM!','m_bigbang','https://youtu.be/Y4RmVcKav9Q') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('노래',2,'mc','🎵 지금 나오는 노래의 제목은?','["Hype Boy", "Ditto", "Attention", "OMG"]'::jsonb,0,'뉴진스 「Hype Boy」(2022)','30대 막내들 차례!','m_newjeans','https://youtu.be/ghrlZIMDzbM') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('베팅',3,'mc','1997년 IMF 때 "금 모으기 운동"으로 모인 금은 약 몇 톤?','["약 227톤", "약 120톤", "약 500톤", "약 50톤"]'::jsonb,0,'약 350만 명이 참여했어요','마지막 문제! 지금까지 모은 점수를 걸고 역전을 노려 보세요.','imf','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('베팅',3,'mc','경부고속도로가 개통된 해는?','["1970년", "1973년", "1977년", "1968년"]'::jsonb,0,'1968년 착공, 1970년 7월 개통','마지막 문제! 점수를 걸고 갑니다.','highway','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('베팅',3,'mc','여의도 63빌딩이 완공된 해는?','["1988년", "1992년", "1981년", "1985년"]'::jsonb,3,'당시 국내 최고층(높이 약 249m)','마지막 문제! 올인하실 분?','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('베팅',3,'mc','KTX가 처음 개통한 해는?','["2000년", "2002년", "2007년", "2004년"]'::jsonb,3,'2004년 4월 경부선·호남선 개통','마지막 문제! 걸 만큼 걸어 보세요.','','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_bank (cat,diff,type,q,opts,answer,note,host,topic,media) values ('베팅',3,'mc','한국 프로야구 원년(1982년) 우승팀은?','["MBC 청룡", "삼성 라이온즈", "OB 베어스", "해태 타이거즈"]'::jsonb,2,'한국시리즈에서 삼성을 꺾었어요','마지막 문제! 야구팬의 역전 찬스!','baseball','') on conflict (q, media) do update set cat=excluded.cat, diff=excluded.diff, type=excluded.type, opts=excluded.opts, answer=excluded.answer, note=excluded.note, host=excluded.host, topic=excluded.topic;
insert into hq_config (id, pin_hash) values (1, extensions.crypt('1234', extensions.gen_salt('bf'))) on conflict (id) do nothing;
