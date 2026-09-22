-- AKAI CRM Phase 15 security hardening: database-backed rate limits.
-- Additive only; user and IP bucket keys are hashed before they reach this table.

create table if not exists public.rate_limit_buckets (
  bucket_key text primary key,
  window_started_at timestamptz not null,
  request_count integer not null check (request_count >= 0),
  updated_at timestamptz not null default now()
);

create index if not exists rate_limit_buckets_updated_at_idx
  on public.rate_limit_buckets (updated_at);

alter table public.rate_limit_buckets enable row level security;
revoke all on public.rate_limit_buckets from anon, authenticated;

create or replace function public.consume_rate_limit(
  p_bucket_key text,
  p_window_seconds integer,
  p_limit integer
)
returns table(allowed boolean, remaining integer, retry_after_seconds integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  bucket public.rate_limit_buckets%rowtype;
  now_utc timestamptz := now();
  elapsed_seconds integer;
begin
  if p_bucket_key is null or length(p_bucket_key) < 16 or length(p_bucket_key) > 128
     or p_window_seconds < 1 or p_window_seconds > 86400 or p_limit < 1 or p_limit > 10000 then
    raise exception using errcode = '22023', message = 'Invalid rate-limit parameters.';
  end if;

  select * into bucket from public.rate_limit_buckets where bucket_key = p_bucket_key for update;
  if not found then
    insert into public.rate_limit_buckets(bucket_key, window_started_at, request_count, updated_at)
    values (p_bucket_key, now_utc, 1, now_utc);
    return query select true, greatest(p_limit - 1, 0), 0;
    return;
  end if;

  elapsed_seconds := floor(extract(epoch from (now_utc - bucket.window_started_at)))::integer;
  if elapsed_seconds >= p_window_seconds then
    update public.rate_limit_buckets
      set window_started_at = now_utc, request_count = 1, updated_at = now_utc
      where bucket_key = p_bucket_key;
    return query select true, greatest(p_limit - 1, 0), 0;
    return;
  end if;

  if bucket.request_count >= p_limit then
    update public.rate_limit_buckets set updated_at = now_utc where bucket_key = p_bucket_key;
    return query select false, 0, greatest(p_window_seconds - elapsed_seconds, 1);
    return;
  end if;

  update public.rate_limit_buckets
    set request_count = request_count + 1, updated_at = now_utc
    where bucket_key = p_bucket_key;
  return query select true, greatest(p_limit - bucket.request_count - 1, 0), 0;
end;
$$;

revoke all on function public.consume_rate_limit(text, integer, integer) from public;
grant execute on function public.consume_rate_limit(text, integer, integer) to anon, authenticated;
