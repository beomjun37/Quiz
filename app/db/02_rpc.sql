-- 한잔 퀴즈 — RPC. 전부 create or replace 라 여러 번 실행해도 안전하다.
-- 채점·마감·추첨은 전부 서버에서 한다. 클라이언트는 보여주기만 한다.

-- 점수: 정답이면 500 + 남은시간 비율 × 500 (빨리 맞힐수록 최대 1000)
create or replace function hq_points(p_correct boolean, p_started timestamptz, p_at timestamptz, p_limit int)
returns int language sql immutable set search_path = public as $$
  select case when not p_correct then 0
    else round(500 + 500 * greatest(0, p_limit - extract(epoch from (p_at - p_started))) / p_limit)::int end
$$;

-- 참가 ----------------------------------------------------------------
drop function if exists hq_join(text, int);
-- 개인전: 닉네임만 받는다. 닉네임은 겹치면 안 된다(대소문자·공백 무시).
drop function if exists hq_join(text);
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
      'id', p.id, 'name', p.name, 'score', p.score, 'gain', p.last_gain, 'prev_rank', p.prev_rank,
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
    -- 개인 순위 TOP 10 (스크린·최종 발표용). prev_rank 로 순위 변동 화살표를 그린다.
    'ranking', (select coalesce(jsonb_agg(x order by x.rank, x.created_at), '[]') from (
        select name, score, last_gain as gain, prev_rank, created_at,
               rank() over (order by score desc)::int as rank
        from hq_players where active order by score desc, created_at limit 10) x),
    'winner', (select jsonb_build_object('name', name, 'is_me', id = p_player) from hq_players where id = s.winner_id),
    'drawn_at', s.drawn_at,
    'drawn', (select count(*) from hq_players where won),
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

  elsif p_action = 'draw' then                      -- 추첨은 서버가 뽑는다(조작 시비 방지). 이미 뽑힌 사람은 제외.
    update hq_state set phase = 'draw', drawn_at = now(), updated_at = now(),
      winner_id = (select id from hq_players where not won order by random() limit 1)
    where id = 1;
    update hq_players set won = true where id = (select winner_id from hq_state where id = 1);

  elsif p_action = 'tables' then
    update hq_state set tables = (p_arg->>'n')::int, updated_at = now() where id = 1;

  elsif p_action = 'bots' then                      -- 리허설용 가상 참가자
    n := (p_arg->>'n')::int - (select count(*) from hq_players);
    for i in 1..greatest(n, 0) loop
      insert into hq_players (name, table_no, is_bot)
      values ((array['찍기의 신','검토해보겠습니다','PC방 고인물','도토리 부자','월요병 말기','막차 사수대','오늘 안 취함','일단 킵하시죠','퇴근 5분 전','법카의 수호자','연차 장인','읽씹 장인'])[1 + (i % 12)] || ' ' || (select count(*) + 1 from hq_players),
              0, true);
    end loop;

  elsif p_action = 'questions' then                 -- 문항 통째로 교체
    if s.phase <> 'lobby' then raise exception 'ONLY_IN_LOBBY'; end if;
    delete from hq_questions where true;  -- Supabase 는 WHERE 없는 UPDATE/DELETE 를 막는다(pg-safeupdate)
    insert into hq_questions (idx, round, type, q, opts, answer, note, is_bet, limit_sec)
    select (ord - 1)::int, e->>'round', e->>'type', e->>'q', coalesce(e->'opts', '[]'), (e->>'answer')::int,
           coalesce(e->>'note', ''), coalesce((e->>'is_bet')::boolean, false), coalesce((e->>'limit_sec')::int, 15)
    from jsonb_array_elements(p_arg->'list') with ordinality as t(e, ord);

  elsif p_action = 'restart' then                   -- 게임만 처음부터: 참가자는 그대로 두고 점수·답안·베팅·추첨만 비운다. 가상 참가자는 뺀다.
    delete from hq_answers where true; delete from hq_bets where true; delete from hq_players where is_bot;
    update hq_players set score = 0, active = false, won = false, prev_score = 0, prev_rank = null, last_gain = 0 where true;
    update hq_state set phase = 'lobby', qi = -1, q_started_at = null, winner_id = null, drawn_at = null, updated_at = now() where id = 1;

  elsif p_action = 'reset' then                     -- 리허설 후 / 행사 후 개인정보 삭제
    delete from hq_answers where true; delete from hq_bets where true; delete from hq_players where true;
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
  -- 순위 변동·이번 문제 득점 표시용 스냅샷
  update hq_players p set prev_score = p.score, prev_rank = r.rk
  from (select id, rank() over (order by score desc)::int rk from hq_players) r where r.id = p.id;

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
  update hq_players set last_gain = score - prev_score where true;
  update hq_state set phase = 'answer', updated_at = now() where id = 1;
end $$;

-- 내부 함수는 직접 못 부르게
revoke all on function hq_open_q() from public;
revoke all on function hq_reveal() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on function hq_open_q() from anon, authenticated;
    revoke all on function hq_reveal() from anon, authenticated;
    grant execute on function hq_join(text, uuid), hq_answer(uuid,int), hq_bet(uuid,int), hq_view(uuid), hq_admin(text,text,jsonb) to anon, authenticated;
  end if;
end $$;
