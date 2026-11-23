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
