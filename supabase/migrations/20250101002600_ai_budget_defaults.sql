-- AKAI CRM Phase 13A corrective migration.
-- Adds the UUID default required by the existing ai_usage contract and makes absent settings use documented defaults.

alter table public.ai_usage
  alter column id set default gen_random_uuid();

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
  select coalesce(max(greatest(1, least(coalesce((s.value_json #>> '{}')::integer, 10), 120))), 10)
    into limit_value
  from public.settings s
  where s.key = 'ai_rate_limit_per_minute';
  insert into public.ai_rate_limit_buckets(user_id, window_start, request_count)
  values (actor, bucket, 1)
  on conflict (user_id, window_start) do update
    set request_count = ai_rate_limit_buckets.request_count + 1;
  select b.request_count into current_count
  from public.ai_rate_limit_buckets b
  where b.user_id = actor and b.window_start = bucket;
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
  select coalesce(max(greatest(1000, least(coalesce((s.value_json #>> '{}')::integer, 20000), 100000))), 20000)
    into limit_value
  from public.settings s
  where s.key = 'ai_daily_token_budget';
  insert into public.ai_usage(user_id, date, input_tokens, output_tokens, reserved_tokens, request_count)
  values (actor, budget_date, 0, 0, estimate, 1)
  on conflict (user_id, date) do update
    set reserved_tokens = ai_usage.reserved_tokens + estimate,
        request_count = ai_usage.request_count + 1;
  select a.input_tokens + a.output_tokens, a.reserved_tokens
    into used_value, reserved_value
  from public.ai_usage a
  where a.user_id = actor and a.date = budget_date;
  if used_value + reserved_value > limit_value then
    update public.ai_usage a
    set reserved_tokens = greatest(0, a.reserved_tokens - estimate),
        request_count = greatest(0, a.request_count - 1)
    where a.user_id = actor and a.date = budget_date;
    return query select false, used_value, greatest(0, reserved_value - estimate), limit_value;
    return;
  end if;
  return query select true, used_value, reserved_value, limit_value;
end;
$$;
revoke all on function public.ai_reserve_token_budget(integer) from public;
grant execute on function public.ai_reserve_token_budget(integer) to authenticated;
