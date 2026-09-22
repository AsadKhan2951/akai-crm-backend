-- AKAI CRM Phase 12 hardening.
-- Additive only. Applied migrations are never edited.

create index if not exists customers_customer_type_status_idx
  on public.customers (customer_type, status);

create table if not exists public.notification_push_deliveries (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references public.notifications(id) on delete cascade,
  subscription_id uuid not null references public.web_push_subscriptions(id) on delete cascade,
  status text not null default 'QUEUED' check (status in ('QUEUED','SENT','FAILED','GONE')),
  error_message text,
  sent_at timestamptz(6),
  created_at timestamptz(6) not null default now(),
  unique (notification_id, subscription_id)
);
create index if not exists notification_push_deliveries_status_created_idx
  on public.notification_push_deliveries (status, created_at);
create index if not exists notification_push_deliveries_subscription_idx
  on public.notification_push_deliveries (subscription_id, created_at);
alter table public.notification_push_deliveries enable row level security;
revoke all on public.notification_push_deliveries from authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on public.notification_push_deliveries to service_role';
  end if;
end $$;
