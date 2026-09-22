-- AKAI CRM Phase 13A: shared AI engine foundation.
-- Additive only. Applied migrations are never edited.

alter table public.ai_usage
  add column if not exists reserved_tokens integer not null default 0;

create table if not exists public.ai_rate_limit_buckets (
  user_id uuid not null references public.users(id) on delete cascade,
  window_start timestamptz(6) not null,
  request_count integer not null default 0,
  created_at timestamptz(6) not null default now(),
  primary key (user_id, window_start)
);
create index if not exists ai_rate_limit_buckets_created_at_idx
  on public.ai_rate_limit_buckets (created_at);
alter table public.ai_rate_limit_buckets enable row level security;
revoke all on public.ai_rate_limit_buckets from authenticated;

drop policy if exists settings_ai_engine_read on public.settings;
create policy settings_ai_engine_read on public.settings
for select to authenticated
using (
  public.has_permission(auth.uid(), 'ai.chat')
  and key in ('ai_daily_token_budget', 'ai_rate_limit_per_minute')
);

drop policy if exists ai_usage_business_insert on public.ai_usage;
drop policy if exists ai_usage_business_update on public.ai_usage;
create policy ai_usage_business_insert on public.ai_usage
for insert to authenticated
with check (user_id = auth.uid() and public.has_permission(auth.uid(), 'ai.chat'));
create policy ai_usage_business_update on public.ai_usage
for update to authenticated
using (user_id = auth.uid() and public.has_permission(auth.uid(), 'ai.chat'))
with check (user_id = auth.uid() and public.has_permission(auth.uid(), 'ai.chat'));

create or replace function public.ai_reserve_rate_limit()
returns table (allowed boolean, request_count integer, request_limit integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  actor uuid := auth.uid();
  bucket timestamptz := date_trunc('minute', now());
  limit_value integer := 10;
  current_count integer;
begin
  if actor is null or not public.has_permission(actor, 'ai.chat') then
    return query select false, 0, 0;
    return;
  end if;
  select greatest(1, least(coalesce((value_json #>> '{}')::integer, 10), 120))
    into limit_value
  from public.settings
  where key = 'ai_rate_limit_per_minute';
  insert into public.ai_rate_limit_buckets(user_id, window_start, request_count)
  values (actor, bucket, 1)
  on conflict (user_id, window_start) do update
    set request_count = ai_rate_limit_buckets.request_count + 1;
  select request_count into current_count
  from public.ai_rate_limit_buckets
  where user_id = actor and window_start = bucket;
  return query select current_count <= limit_value, current_count, limit_value;
end;
$$;
revoke all on function public.ai_reserve_rate_limit() from public;
grant execute on function public.ai_reserve_rate_limit() to authenticated;

create or replace function public.ai_reserve_token_budget(p_estimated_tokens integer default 2000)
returns table (allowed boolean, used_tokens integer, reserved_tokens integer, daily_limit integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  actor uuid := auth.uid();
  budget_date date := (now() at time zone 'Asia/Karachi')::date;
  limit_value integer := 20000;
  used_value integer;
  reserved_value integer;
  estimate integer := greatest(1, least(coalesce(p_estimated_tokens, 2000), 20000));
begin
  if actor is null or not public.has_permission(actor, 'ai.chat') then
    return query select false, 0, 0, 0;
    return;
  end if;
  select greatest(1000, least(coalesce((value_json #>> '{}')::integer, 20000), 100000))
    into limit_value
  from public.settings
  where key = 'ai_daily_token_budget';
  insert into public.ai_usage(user_id, date, input_tokens, output_tokens, reserved_tokens, request_count)
  values (actor, budget_date, 0, 0, estimate, 1)
  on conflict (user_id, date) do update
    set reserved_tokens = ai_usage.reserved_tokens + estimate,
        request_count = ai_usage.request_count + 1;
  select input_tokens + output_tokens, reserved_tokens
    into used_value, reserved_value
  from public.ai_usage
  where user_id = actor and date = budget_date;
  if used_value + reserved_value > limit_value then
    update public.ai_usage
    set reserved_tokens = greatest(0, reserved_tokens - estimate),
        request_count = greatest(0, request_count - 1)
    where user_id = actor and date = budget_date;
    return query select false, used_value, greatest(0, reserved_value - estimate), limit_value;
    return;
  end if;
  return query select true, used_value, reserved_value, limit_value;
end;
$$;
revoke all on function public.ai_reserve_token_budget(integer) from public;
grant execute on function public.ai_reserve_token_budget(integer) to authenticated;

create or replace function public.ai_record_usage(p_input_tokens integer, p_output_tokens integer, p_reserved_tokens integer default 0)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  actor uuid := auth.uid();
  usage_date date := (now() at time zone 'Asia/Karachi')::date;
begin
  if actor is null or not public.has_permission(actor, 'ai.chat') then return false; end if;
  update public.ai_usage
  set input_tokens = input_tokens + greatest(0, least(coalesce(p_input_tokens, 0), 1000000)),
      output_tokens = output_tokens + greatest(0, least(coalesce(p_output_tokens, 0), 1000000)),
      reserved_tokens = greatest(0, reserved_tokens - greatest(0, least(coalesce(p_reserved_tokens, 0), 1000000)))
  where user_id = actor and date = usage_date;
  return found;
end;
$$;
revoke all on function public.ai_record_usage(integer, integer, integer) from public;
grant execute on function public.ai_record_usage(integer, integer, integer) to authenticated;

create or replace function public.ai_release_token_budget(p_reserved_tokens integer)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  actor uuid := auth.uid();
  usage_date date := (now() at time zone 'Asia/Karachi')::date;
begin
  if actor is null or not public.has_permission(actor, 'ai.chat') then return false; end if;
  update public.ai_usage
  set reserved_tokens = greatest(0, reserved_tokens - greatest(0, least(coalesce(p_reserved_tokens, 0), 1000000)))
  where user_id = actor and date = usage_date;
  return found;
end;
$$;
revoke all on function public.ai_release_token_budget(integer) from public;
grant execute on function public.ai_release_token_budget(integer) to authenticated;

comment on table public.ai_rate_limit_buckets is 'Per-user UTC request windows for the Phase 13A AI endpoint; writes occur only through the permission-checked function.';
comment on column public.ai_usage.reserved_tokens is 'Estimated tokens reserved atomically before an AI request; released or reconciled after completion.';
