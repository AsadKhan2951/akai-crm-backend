-- AKAI CRM Phase 13A corrective migration.
-- Fixes the local PostgreSQL ambiguity between the function output column and table column.

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
  select greatest(1, least(coalesce((s.value_json #>> '{}')::integer, 10), 120))
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
