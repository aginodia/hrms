-- =====================================================================
-- Altius HRMS — Pre-onboarding (learn the business, then two quizzes)
--
--  * HR adds a candidate's email. When the candidate signs up with that
--    email (or already has a sign-up waiting) they are linked ("mapped")
--    and the clock starts:
--      - 24 hours to press Start, otherwise it lapses;
--      - 3 days from Start for the reading and both quizzes;
--      - if they fail (below 80% overall) one retake, due 2 days from the
--        moment they fail;
--      - everything ends within 6 days of being linked.
--  * Two sections: 1 = the space & past exits, 2 = current offerings.
--    Materials: PDF decks (private storage bucket "preboarding"), deck
--    links, YouTube videos, webinars and other links, in HR's order.
--    Section 1 → Quiz 1 → Section 2 → Quiz 2 → result. In the first
--    attempt every material of a section has to be opened before its quiz.
--  * Question bank uploaded from Excel. Each quiz draws 20 questions of its
--    section, least-used first (round robin across candidates) and never
--    repeats a question the candidate has already had while there are
--    others. Correct answers never leave the database; grading happens here.
--  * Candidates see only Pre-onboarding until HR gives them access.
-- Re-runnable. Nothing is removed.
-- =====================================================================

create table if not exists public.preboard_candidates (
  id                uuid primary key default gen_random_uuid(),
  email             text not null,
  user_id           uuid references public.profiles (id) on delete set null,
  cycle             integer not null default 1,
  status            text not null default 'waiting' check (status in ('waiting', 'mapped', 'in_progress', 'retake', 'passed', 'failed', 'lapsed')),
  attempt           integer not null default 1,
  mapped_at         timestamptz,
  start_by          timestamptz,
  started_at        timestamptz,
  attempt_deadline  timestamptz,
  final_deadline    timestamptz,
  first_score       numeric(5, 2),
  score_pct         numeric(5, 2),
  result_at         timestamptz,
  added_by          uuid references public.profiles (id) on delete set null,
  added_at          timestamptz not null default now(),
  removed_at        timestamptz
);
create unique index if not exists preboard_candidates_email_uq on public.preboard_candidates (lower(email)) where removed_at is null;
create index if not exists preboard_candidates_user_idx on public.preboard_candidates (user_id);

create table if not exists public.preboard_materials (
  id           uuid primary key default gen_random_uuid(),
  section      smallint not null check (section in (1, 2)),
  kind         text not null check (kind in ('pdf', 'deck', 'video', 'webinar', 'link')),
  title        text not null,
  description  text,
  url          text,
  file_path    text,
  file_name    text,
  sort_order   integer not null default 0,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  removed_at   timestamptz
);

create table if not exists public.preboard_questions (
  id          uuid primary key default gen_random_uuid(),
  section     smallint not null check (section in (1, 2)),
  question    text not null,
  options     jsonb not null,
  answer      smallint not null,
  times_used  integer not null default 0,
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  removed_at  timestamptz
);
create index if not exists preboard_questions_section_idx on public.preboard_questions (section) where removed_at is null;

create table if not exists public.preboard_attempts (
  id            uuid primary key default gen_random_uuid(),
  candidate_id  uuid not null references public.preboard_candidates (id) on delete cascade,
  cycle         integer not null,
  attempt       integer not null,
  section       smallint not null,
  question_ids  uuid[] not null,
  answers       jsonb,
  correct       integer,
  total         integer not null,
  started_at    timestamptz not null default now(),
  submitted_at  timestamptz,
  unique (candidate_id, cycle, attempt, section)
);

create table if not exists public.preboard_views (
  candidate_id  uuid not null references public.preboard_candidates (id) on delete cascade,
  material_id   uuid not null references public.preboard_materials (id) on delete cascade,
  viewed_at     timestamptz not null default now(),
  primary key (candidate_id, material_id)
);

alter table public.preboard_candidates enable row level security;
alter table public.preboard_materials enable row level security;
alter table public.preboard_questions enable row level security;
alter table public.preboard_attempts enable row level security;
alter table public.preboard_views enable row level security;
do $$
declare t text;
begin
  foreach t in array array['preboard_candidates', 'preboard_materials', 'preboard_questions', 'preboard_attempts', 'preboard_views'] loop
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = t || '_admin_select') then
      execute format('create policy %I on public.%I for select to authenticated using ((select public.is_admin()))', t || '_admin_select', t);
    end if;
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

-- Settings (defaults; app_settings "preboarding" can override, e.g. section titles)
create or replace function public._pb_cfg()
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object('pass_pct', 80, 'per_section', 20, 'start_hours', 24, 'first_days', 3, 'retake_days', 2, 'max_days', 6,
           'sections', jsonb_build_object('1', 'The space & past exits', '2', 'Current offerings'))
         || coalesce((select value from public.app_settings where key = 'preboarding'), '{}'::jsonb);
$$;

-- The signed-in user is a linked candidate who has not been given access yet
create or replace function public._pb_is_candidate()
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.preboard_candidates c join public.profiles p on p.id = c.user_id
                  where c.user_id = auth.uid() and c.removed_at is null and p.status = 'pending');
$$;

-- Link a sign-up to the candidate added with that email; starts the clock
create or replace function public._pb_map(p_user uuid, p_email text)
returns boolean language plpgsql security definer set search_path = public
as $$
declare cfg jsonb := public._pb_cfg(); v_id uuid;
begin
  update public.preboard_candidates
     set user_id = p_user, status = 'mapped', mapped_at = now(),
         start_by = now() + make_interval(hours => (cfg ->> 'start_hours')::int),
         final_deadline = now() + make_interval(days => (cfg ->> 'max_days')::int)
   where lower(email) = lower(p_email) and removed_at is null and user_id is null and status = 'waiting'
  returning id into v_id;
  if v_id is null then return false; end if;
  update auth.users set email_confirmed_at = now() where id = p_user and email_confirmed_at is null;
  return true;
end;
$$;

create or replace function public._pb_on_profile()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.status = 'pending' then perform public._pb_map(new.id, new.email); end if;
  return new;
end;
$$;
create or replace trigger profiles_preboard_map after insert on public.profiles
  for each row execute function public._pb_on_profile();

-- Score of an attempt in % (sections not taken count as wrong)
create or replace function public._pb_score(p_cand uuid, p_cycle int, p_attempt int)
returns numeric language sql stable security definer set search_path = public
as $$
  select round(100.0 * coalesce(sum(case when a.submitted_at is not null then a.correct else 0 end), 0)
               / greatest(coalesce(sum(a.total), 0) + (2 - count(a.id)) * (public._pb_cfg() ->> 'per_section')::int, 1), 2)
    from public.preboard_attempts a
   where a.candidate_id = p_cand and a.cycle = p_cycle and a.attempt = p_attempt;
$$;

-- Apply the time rules (lapse, attempt expiry, retake window, 6-day cap)
create or replace function public._pb_refresh(p_id uuid)
returns public.preboard_candidates language plpgsql security definer set search_path = public
as $$
declare c public.preboard_candidates; cfg jsonb := public._pb_cfg(); i int;
begin
  select * into c from public.preboard_candidates where id = p_id for update;
  if c.id is null then return c; end if;
  for i in 1..3 loop
    if c.status = 'mapped' and now() > c.start_by then
      update public.preboard_candidates set status = 'lapsed', result_at = c.start_by where id = c.id returning * into c;
    elsif c.status in ('in_progress', 'retake') and now() > c.attempt_deadline then
      if c.attempt = 1 and c.attempt_deadline < c.final_deadline then
        update public.preboard_candidates
           set status = 'retake', attempt = 2, first_score = public._pb_score(c.id, c.cycle, 1),
               attempt_deadline = least(c.attempt_deadline + make_interval(days => (cfg ->> 'retake_days')::int), c.final_deadline)
         where id = c.id returning * into c;
      else
        update public.preboard_candidates
           set status = 'failed', score_pct = public._pb_score(c.id, c.cycle, c.attempt), result_at = c.attempt_deadline
         where id = c.id returning * into c;
      end if;
    else
      exit;
    end if;
  end loop;
  return c;
end;
$$;

-- ---------------------------------------------------------------------
-- Candidate side
-- ---------------------------------------------------------------------
create or replace function public._pb_me()
returns public.preboard_candidates language plpgsql security definer set search_path = public
as $$
declare c public.preboard_candidates; p public.profiles;
begin
  select * into p from public.profiles where id = auth.uid();
  if p.id is null or p.status <> 'pending' then return null; end if;
  select * into c from public.preboard_candidates where user_id = p.id and removed_at is null;
  if c.id is null and public._pb_map(p.id, p.email) then
    select * into c from public.preboard_candidates where user_id = p.id and removed_at is null;
  end if;
  if c.id is null then return null; end if;
  return public._pb_refresh(c.id);
end;
$$;

create or replace function public.my_preboarding()
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  c public.preboard_candidates := public._pb_me();
  cfg jsonb := public._pb_cfg();
  q1 public.preboard_attempts; q2 public.preboard_attempts;
  v_open boolean; v_s2 boolean;
begin
  if c.id is null then return null; end if;
  select * into q1 from public.preboard_attempts where candidate_id = c.id and cycle = c.cycle and attempt = c.attempt and section = 1;
  select * into q2 from public.preboard_attempts where candidate_id = c.id and cycle = c.cycle and attempt = c.attempt and section = 2;
  v_open := c.status in ('in_progress', 'retake');
  v_s2 := v_open and (c.attempt = 2 or q1.submitted_at is not null);
  return jsonb_build_object(
    'status', c.status, 'attempt', c.attempt, 'mapped_at', c.mapped_at, 'start_by', c.start_by, 'started_at', c.started_at,
    'attempt_deadline', c.attempt_deadline, 'final_deadline', c.final_deadline, 'first_score', c.first_score,
    'score_pct', c.score_pct, 'result_at', c.result_at, 'now', now(),
    'pass_pct', cfg -> 'pass_pct', 'per_section', cfg -> 'per_section', 'first_days', cfg -> 'first_days',
    'retake_days', cfg -> 'retake_days', 'start_hours', cfg -> 'start_hours', 'max_days', cfg -> 'max_days', 'sections', cfg -> 'sections',
    'quiz', jsonb_build_object(
      '1', jsonb_build_object('started', q1.id is not null, 'submitted', q1.submitted_at is not null),
      '2', jsonb_build_object('started', q2.id is not null, 'submitted', q2.submitted_at is not null)),
    'materials', case when not v_open then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object('id', m.id, 'section', m.section, 'kind', m.kind, 'title', m.title, 'description', m.description,
               'url', m.url, 'file_path', m.file_path, 'file_name', m.file_name,
               'viewed', exists (select 1 from public.preboard_views v where v.candidate_id = c.id and v.material_id = m.id))
             order by m.section, m.sort_order, m.created_at)
        from public.preboard_materials m
       where m.removed_at is null and (m.section = 1 or v_s2)), '[]'::jsonb) end);
end;
$$;

create or replace function public.my_preboard_start()
returns void language plpgsql security definer set search_path = public
as $$
declare c public.preboard_candidates := public._pb_me(); cfg jsonb := public._pb_cfg();
begin
  if c.id is null then raise exception 'Pre-onboarding is not set up for you — contact HR'; end if;
  if c.status = 'lapsed' then raise exception 'The time to start has passed — contact HR'; end if;
  if c.status <> 'mapped' then raise exception 'You have already started'; end if;
  update public.preboard_candidates
     set status = 'in_progress', started_at = now(), attempt = 1,
         attempt_deadline = least(now() + make_interval(days => (cfg ->> 'first_days')::int), final_deadline)
   where id = c.id;
end;
$$;

create or replace function public.my_preboard_view(p_material uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare c public.preboard_candidates := public._pb_me();
begin
  if c.id is null or c.status not in ('in_progress', 'retake') then return; end if;
  if not exists (select 1 from public.preboard_materials where id = p_material and removed_at is null) then return; end if;
  insert into public.preboard_views (candidate_id, material_id) values (c.id, p_material) on conflict do nothing;
end;
$$;

-- Start (or resume) a quiz: the questions without their answers
create or replace function public.my_preboard_quiz(p_section int)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  c public.preboard_candidates := public._pb_me();
  cfg jsonb := public._pb_cfg();
  a public.preboard_attempts; v_ids uuid[]; v_seen uuid[];
begin
  if c.id is null then raise exception 'Pre-onboarding is not set up for you — contact HR'; end if;
  if c.status not in ('in_progress', 'retake') then raise exception 'The quiz is not open'; end if;
  if p_section not in (1, 2) then raise exception 'Unknown quiz'; end if;
  select * into a from public.preboard_attempts where candidate_id = c.id and cycle = c.cycle and attempt = c.attempt and section = p_section;
  if a.submitted_at is not null then raise exception 'You have already submitted this quiz'; end if;
  if a.id is null then
    if p_section = 2 and not exists (select 1 from public.preboard_attempts where candidate_id = c.id and cycle = c.cycle and attempt = c.attempt and section = 1 and submitted_at is not null) then
      raise exception 'Finish Quiz 1 first';
    end if;
    if c.attempt = 1 and exists (select 1 from public.preboard_materials m where m.section = p_section and m.removed_at is null
                                  and not exists (select 1 from public.preboard_views v where v.candidate_id = c.id and v.material_id = m.id)) then
      raise exception 'Go through every item of this section first';
    end if;
    select coalesce(array_agg(x), '{}') into v_seen from public.preboard_attempts t, unnest(t.question_ids) x where t.candidate_id = c.id;
    select coalesce(array_agg(id), '{}') into v_ids from (
      select q.id from public.preboard_questions q
       where q.section = p_section and q.removed_at is null
       order by (q.id = any (v_seen)), q.times_used, random()
       limit (cfg ->> 'per_section')::int) s;
    if cardinality(v_ids) = 0 then raise exception 'This quiz is not ready yet — contact HR'; end if;
    update public.preboard_questions set times_used = times_used + 1 where id = any (v_ids);
    insert into public.preboard_attempts (candidate_id, cycle, attempt, section, question_ids, total)
    values (c.id, c.cycle, c.attempt, p_section, v_ids, cardinality(v_ids)) returning * into a;
  end if;
  return jsonb_build_object('attempt_id', a.id, 'section', p_section, 'deadline', c.attempt_deadline,
    'questions', (select jsonb_agg(jsonb_build_object('id', q.id, 'question', q.question, 'options', q.options) order by k)
                    from unnest(a.question_ids) with ordinality u(qid, k) join public.preboard_questions q on q.id = u.qid));
end;
$$;

-- Submit a quiz (answers: {question_id: option index}); after Quiz 2 the result is worked out
create or replace function public.my_preboard_submit(p_section int, p_answers jsonb)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  c public.preboard_candidates := public._pb_me();
  cfg jsonb := public._pb_cfg();
  a public.preboard_attempts; v_correct int; v_pct numeric;
begin
  if c.id is null then raise exception 'Pre-onboarding is not set up for you — contact HR'; end if;
  if c.status not in ('in_progress', 'retake') then raise exception 'The time for this quiz is over'; end if;
  select * into a from public.preboard_attempts where candidate_id = c.id and cycle = c.cycle and attempt = c.attempt and section = p_section for update;
  if a.id is null then raise exception 'Start the quiz first'; end if;
  if a.submitted_at is not null then raise exception 'You have already submitted this quiz'; end if;
  select count(*) into v_correct from public.preboard_questions q
   where q.id = any (a.question_ids) and (p_answers ->> q.id::text) ~ '^\d+$' and (p_answers ->> q.id::text)::int = q.answer;
  update public.preboard_attempts set answers = coalesce(p_answers, '{}'::jsonb), correct = v_correct, submitted_at = now() where id = a.id;
  if p_section = 1 then return jsonb_build_object('done', false); end if;

  v_pct := public._pb_score(c.id, c.cycle, c.attempt);
  if v_pct >= (cfg ->> 'pass_pct')::numeric then
    update public.preboard_candidates set status = 'passed', score_pct = v_pct, result_at = now() where id = c.id;
    return jsonb_build_object('done', true, 'passed', true, 'score_pct', v_pct);
  elsif c.attempt = 1 and now() < c.final_deadline then
    update public.preboard_candidates
       set status = 'retake', attempt = 2, first_score = v_pct,
           attempt_deadline = least(now() + make_interval(days => (cfg ->> 'retake_days')::int), final_deadline)
     where id = c.id;
    return jsonb_build_object('done', true, 'passed', false, 'retake', true, 'score_pct', v_pct);
  else
    update public.preboard_candidates set status = 'failed', score_pct = v_pct, result_at = now() where id = c.id;
    return jsonb_build_object('done', true, 'passed', false, 'retake', false, 'score_pct', v_pct);
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- HR side
-- ---------------------------------------------------------------------
create or replace function public.admin_add_preboard_candidates(p_emails text[])
returns jsonb language plpgsql security definer set search_path = public
as $$
declare e text; p public.profiles; v_id uuid; added int := 0; mapped int := 0; skipped jsonb := '[]'::jsonb;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  foreach e in array coalesce(p_emails, '{}') loop
    e := lower(trim(e));
    continue when e = '';
    if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then skipped := skipped || jsonb_build_object('email', e, 'why', 'not a valid email'); continue; end if;
    if exists (select 1 from public.preboard_candidates where lower(email) = e and removed_at is null) then
      skipped := skipped || jsonb_build_object('email', e, 'why', 'already added'); continue;
    end if;
    select * into p from public.profiles where lower(email) = e;
    if p.id is not null and p.status <> 'pending' then
      skipped := skipped || jsonb_build_object('email', e, 'why', 'already has access to the HRMS'); continue;
    end if;
    insert into public.preboard_candidates (email, added_by) values (e, auth.uid()) returning id into v_id;
    added := added + 1;
    if p.id is not null and public._pb_map(p.id, e) then mapped := mapped + 1; end if;
  end loop;
  return jsonb_build_object('added', added, 'mapped', mapped, 'skipped', skipped);
end;
$$;

create or replace function public.admin_remove_preboard_candidate(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.preboard_candidates set removed_at = now() where id = p_id and removed_at is null;
end;
$$;

-- A fresh start: new 24 hours to start, 6 days in all (earlier attempts stay in the record)
create or replace function public.admin_reset_preboard_candidate(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare c public.preboard_candidates; cfg jsonb := public._pb_cfg();
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  select * into c from public.preboard_candidates where id = p_id and removed_at is null for update;
  if c.id is null then raise exception 'Candidate not found'; end if;
  if c.user_id is null then raise exception 'They have not signed up yet — the clock starts when they do'; end if;
  update public.preboard_candidates
     set cycle = c.cycle + 1, status = 'mapped', attempt = 1, mapped_at = now(),
         start_by = now() + make_interval(hours => (cfg ->> 'start_hours')::int),
         final_deadline = now() + make_interval(days => (cfg ->> 'max_days')::int),
         started_at = null, attempt_deadline = null, first_score = null, score_pct = null, result_at = null
   where id = p_id;
end;
$$;

create or replace function public.admin_preboard_refresh()
returns void language plpgsql security definer set search_path = public
as $$
declare r record;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  for r in select id from public.preboard_candidates where removed_at is null and status in ('mapped', 'in_progress', 'retake') loop
    perform public._pb_refresh(r.id);
  end loop;
end;
$$;

create or replace function public.admin_save_preboard_material(p_id uuid, p_section int, p_kind text, p_title text, p_description text,
                                                               p_url text, p_file_path text, p_file_name text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_section not in (1, 2) then raise exception 'Pick the section'; end if;
  if p_kind not in ('pdf', 'deck', 'video', 'webinar', 'link') then raise exception 'Pick the type'; end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'Give it a title'; end if;
  if p_kind = 'pdf' and coalesce(p_file_path, '') = '' and p_id is null then raise exception 'Upload the PDF'; end if;
  if p_kind <> 'pdf' and coalesce(trim(p_url), '') !~* '^https?://' then raise exception 'Paste the link (starting with https://)'; end if;
  if p_id is null then
    insert into public.preboard_materials (section, kind, title, description, url, file_path, file_name, sort_order, created_by)
    values (p_section, p_kind, trim(p_title), nullif(trim(p_description), ''), case when p_kind = 'pdf' then null else trim(p_url) end,
            case when p_kind = 'pdf' then p_file_path end, case when p_kind = 'pdf' then p_file_name end,
            coalesce((select max(sort_order) + 1 from public.preboard_materials where section = p_section and removed_at is null), 1), auth.uid())
    returning id into v_id;
  else
    update public.preboard_materials
       set section = p_section, kind = p_kind, title = trim(p_title), description = nullif(trim(p_description), ''),
           url = case when p_kind = 'pdf' then null else trim(p_url) end,
           file_path = case when p_kind = 'pdf' then coalesce(nullif(p_file_path, ''), file_path) end,
           file_name = case when p_kind = 'pdf' then coalesce(nullif(p_file_name, ''), file_name) end,
           updated_at = now()
     where id = p_id and removed_at is null returning id into v_id;
    if v_id is null then raise exception 'This item was removed'; end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.admin_remove_preboard_material(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.preboard_materials set removed_at = now() where id = p_id and removed_at is null;
end;
$$;

create or replace function public.admin_reorder_preboard_materials(p_ids uuid[])
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.preboard_materials m set sort_order = u.k, updated_at = now()
    from unnest(p_ids) with ordinality u(id, k) where m.id = u.id;
end;
$$;

-- Question bank from Excel: rows {section, question, options[], answer (0-based)}.
-- The same question (same section and text) is updated, not added twice.
-- With p_replace, questions of the uploaded sections that are not in the file are taken out.
create or replace function public.admin_import_preboard_questions(p_rows jsonb, p_replace boolean default false)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare x jsonb; v_sec int; v_q text; v_opts jsonb; v_ans int; v_id uuid; added int := 0; updated int := 0; removed int := 0; v_keep uuid[] := '{}';
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'No questions in the file'; end if;
  for x in select * from jsonb_array_elements(p_rows) loop
    v_sec := (x ->> 'section')::int; v_q := trim(x ->> 'question'); v_opts := x -> 'options'; v_ans := (x ->> 'answer')::int;
    if v_sec not in (1, 2) then raise exception 'Section must be 1 or 2 (“%”)', left(v_q, 60); end if;
    if coalesce(v_q, '') = '' then raise exception 'A question is empty'; end if;
    if jsonb_typeof(v_opts) <> 'array' or jsonb_array_length(v_opts) < 2 then raise exception 'Give at least two options for “%”', left(v_q, 60); end if;
    if v_ans is null or v_ans < 0 or v_ans >= jsonb_array_length(v_opts) then raise exception 'The correct answer for “%” is not one of its options', left(v_q, 60); end if;
    select id into v_id from public.preboard_questions where section = v_sec and lower(question) = lower(v_q) and removed_at is null limit 1;
    if v_id is null then
      insert into public.preboard_questions (section, question, options, answer, created_by) values (v_sec, v_q, v_opts, v_ans, auth.uid()) returning id into v_id;
      added := added + 1;
    else
      update public.preboard_questions set options = v_opts, answer = v_ans where id = v_id;
      updated := updated + 1;
    end if;
    v_keep := v_keep || v_id;
  end loop;
  if p_replace then
    update public.preboard_questions set removed_at = now()
     where removed_at is null and not (id = any (v_keep))
       and section in (select distinct (r ->> 'section')::int from jsonb_array_elements(p_rows) r);
    get diagnostics removed = row_count;
  end if;
  return jsonb_build_object('added', added, 'updated', updated, 'removed', removed);
end;
$$;

create or replace function public.admin_remove_preboard_question(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.preboard_questions set removed_at = now() where id = p_id and removed_at is null;
end;
$$;

create or replace function public.admin_save_preboard_sections(p_s1 text, p_s2 text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if coalesce(trim(p_s1), '') = '' or coalesce(trim(p_s2), '') = '' then raise exception 'Give both sections a name'; end if;
  insert into public.app_settings (key, value) values ('preboarding', jsonb_build_object('sections', jsonb_build_object('1', trim(p_s1), '2', trim(p_s2))))
  on conflict (key) do update set value = public.app_settings.value || excluded.value;
end;
$$;

-- ---------------------------------------------------------------------
-- PDF decks: private storage bucket, readable by admins and linked candidates
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('preboarding', 'preboarding', false, 52428800, array['application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'preboarding_select') then
    create policy preboarding_select on storage.objects for select to authenticated
      using (bucket_id = 'preboarding' and (public.is_admin() or public._pb_is_candidate()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'preboarding_insert') then
    create policy preboarding_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'preboarding' and public.is_admin());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'preboarding_admin_delete') then
    create policy preboarding_admin_delete on storage.objects for delete to authenticated
      using (bucket_id = 'preboarding' and public.is_admin());
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
revoke execute on function public._pb_cfg() from public, anon, authenticated;
revoke execute on function public._pb_map(uuid, text) from public, anon, authenticated;
revoke execute on function public._pb_on_profile() from public, anon, authenticated;
revoke execute on function public._pb_score(uuid, int, int) from public, anon, authenticated;
revoke execute on function public._pb_refresh(uuid) from public, anon, authenticated;
revoke execute on function public._pb_me() from public, anon, authenticated;
revoke execute on function public._pb_is_candidate() from public, anon;
grant execute on function public._pb_is_candidate() to authenticated;
revoke execute on function public.my_preboarding() from public, anon;
revoke execute on function public.my_preboard_start() from public, anon;
revoke execute on function public.my_preboard_view(uuid) from public, anon;
revoke execute on function public.my_preboard_quiz(int) from public, anon;
revoke execute on function public.my_preboard_submit(int, jsonb) from public, anon;
revoke execute on function public.admin_add_preboard_candidates(text[]) from public, anon;
revoke execute on function public.admin_remove_preboard_candidate(uuid) from public, anon;
revoke execute on function public.admin_reset_preboard_candidate(uuid) from public, anon;
revoke execute on function public.admin_preboard_refresh() from public, anon;
revoke execute on function public.admin_save_preboard_material(uuid, int, text, text, text, text, text, text) from public, anon;
revoke execute on function public.admin_remove_preboard_material(uuid) from public, anon;
revoke execute on function public.admin_reorder_preboard_materials(uuid[]) from public, anon;
revoke execute on function public.admin_import_preboard_questions(jsonb, boolean) from public, anon;
revoke execute on function public.admin_remove_preboard_question(uuid) from public, anon;
revoke execute on function public.admin_save_preboard_sections(text, text) from public, anon;
grant execute on function public.my_preboarding() to authenticated;
grant execute on function public.my_preboard_start() to authenticated;
grant execute on function public.my_preboard_view(uuid) to authenticated;
grant execute on function public.my_preboard_quiz(int) to authenticated;
grant execute on function public.my_preboard_submit(int, jsonb) to authenticated;
grant execute on function public.admin_add_preboard_candidates(text[]) to authenticated;
grant execute on function public.admin_remove_preboard_candidate(uuid) to authenticated;
grant execute on function public.admin_reset_preboard_candidate(uuid) to authenticated;
grant execute on function public.admin_preboard_refresh() to authenticated;
grant execute on function public.admin_save_preboard_material(uuid, int, text, text, text, text, text, text) to authenticated;
grant execute on function public.admin_remove_preboard_material(uuid) to authenticated;
grant execute on function public.admin_reorder_preboard_materials(uuid[]) to authenticated;
grant execute on function public.admin_import_preboard_questions(jsonb, boolean) to authenticated;
grant execute on function public.admin_remove_preboard_question(uuid) to authenticated;
grant execute on function public.admin_save_preboard_sections(text, text) to authenticated;
