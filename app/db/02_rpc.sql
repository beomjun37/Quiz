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
                  where a.player_id = p.id and qq.type <> 'poll' and a.choice = qq.answer and a.qi < s.qi + (case when s.phase in ('answer','final','draw','end') then 1 else 0 end)),
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
      update hq_questions set answer = null where idx = s.qi and type in ('survey', 'minority');
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
    update hq_questions set answer = null where type in ('survey', 'minority');  -- 지난 판에 정해진 다수결·소수결 정답 지우기
    delete from hq_reactions where true;

  elsif p_action = 'reset' then                     -- 새 게임 / 행사 후 개인정보 삭제
    delete from hq_answers where true; delete from hq_bets where true; delete from hq_reactions where true; delete from hq_players where true;
    update hq_state set phase = 'lobby', qi = -1, q_started_at = null, winner_ids = '{}', drawn_at = null, updated_at = now() where id = 1;
    update hq_draw set winner_ids = '{}' where id = 1;
    update hq_questions set answer = null where type in ('survey', 'minority');  -- 지난 판에 정해진 다수결·소수결 정답 지우기
    delete from hq_reactions where true;

  elsif p_action = 'current' then                   -- 진행자 전용: 지금 문제와 다음 문제의 정답·해설·멘트 (참가자에겐 공개 전까지 안 내려간다)
    return jsonb_build_object(
      'now', (select jsonb_build_object('idx', idx, 'answer', answer, 'note', note, 'host', host, 'media', media) from hq_questions where idx = s.qi),
      'next', (select jsonb_build_object('idx', idx, 'q', q, 'type', type, 'opts', opts, 'answer', answer, 'host', host, 'is_bet', is_bet,
               'round', round, 'note', note, 'limit_sec', limit_sec, 'media', media,
               'reveal', reveal, 'has_image', exists (select 1 from hq_images i where i.idx = hq_questions.idx))
               from hq_questions where idx = s.qi + 1),
      'correct', (select count(*) from hq_answers a join hq_questions q on q.idx = a.qi where a.qi = s.qi and a.choice = q.answer and a.at <= now()));

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
            where b0.cat = c_cat and b0.diff >= coalesce((p_arg->>'min_diff')::int, 1)
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
        from hq_bank where cat = '베팅' and (topic = '' or topic not in (select topic from _pick where topic is not null))
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
    select choice into q.answer from hq_answers where qi = s.qi group by choice
    order by case when q.type = 'survey' then -count(*) else count(*) end, random() limit 1;
    update hq_questions set answer = q.answer where idx = s.qi;
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
               coalesce(a.choice = q.answer, false) as correct,
               hq_points(a.choice = q.answer, s.q_started_at, a.at, q.limit_sec) as base,
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
