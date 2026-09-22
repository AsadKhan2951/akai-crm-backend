-- AKAI CRM Phase 12: Communications.
-- Additive only. Applied migrations are never edited.

alter type "MessageStatus" add value if not exists 'RECEIVED';

alter table public.message_logs
  add column if not exists provider text,
  add column if not exists subject text,
  add column if not exists sender_address text,
  add column if not exists thread_key text,
  add column if not exists external_event_id text,
  add column if not exists metadata_json jsonb,
  add column if not exists attempt_count integer not null default 0,
  add column if not exists next_attempt_at timestamptz(6),
  add column if not exists last_attempt_at timestamptz(6),
  add column if not exists locked_at timestamptz(6),
  add column if not exists created_at timestamptz(6) not null default now(),
  add column if not exists updated_at timestamptz(6) not null default now();

create unique index if not exists message_logs_external_event_id_uidx
  on public.message_logs (external_event_id)
  where external_event_id is not null;
create index if not exists message_logs_status_next_attempt_at_idx
  on public.message_logs (status, next_attempt_at);
create index if not exists message_logs_status_locked_at_idx
  on public.message_logs (status, locked_at);
create index if not exists message_logs_thread_key_created_at_idx
  on public.message_logs (thread_key, created_at);

create table if not exists public.message_templates (
  id uuid primary key default gen_random_uuid(),
  key text not null,
  channel text not null check (channel in ('EMAIL','WHATSAPP')),
  locale text not null check (locale in ('en','ur')),
  subject text,
  body text not null,
  provider_template_name text,
  approval_status text not null default 'DRAFT' check (approval_status in ('DRAFT','SUBMITTED','APPROVED','REJECTED')),
  is_active boolean not null default true,
  created_by_user_id uuid references public.users(id) on delete set null,
  created_at timestamptz(6) not null default now(),
  updated_at timestamptz(6) not null default now(),
  unique (key, channel, locale)
);
create index if not exists message_templates_channel_active_idx
  on public.message_templates (channel, is_active);

create table if not exists public.messaging_campaigns (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  channel "MessageChannel" not null,
  template_key text not null,
  segment_json jsonb not null default '{}'::jsonb,
  status text not null default 'DRAFT' check (status in ('DRAFT','QUEUED','PROCESSING','SENT','FAILED')),
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  queued_at timestamptz(6),
  created_at timestamptz(6) not null default now(),
  updated_at timestamptz(6) not null default now()
);
create index if not exists messaging_campaigns_creator_created_idx
  on public.messaging_campaigns (created_by_user_id, created_at);
create index if not exists messaging_campaigns_status_queued_idx
  on public.messaging_campaigns (status, queued_at);

create table if not exists public.web_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  endpoint text not null,
  p256dh text not null,
  auth text not null,
  created_at timestamptz(6) not null default now(),
  updated_at timestamptz(6) not null default now(),
  unique (user_id, endpoint)
);
create index if not exists web_push_subscriptions_user_created_idx
  on public.web_push_subscriptions (user_id, created_at);

create table if not exists public.message_webhook_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null,
  external_id text not null,
  payload_json jsonb not null,
  received_at timestamptz(6) not null default now(),
  unique (provider, external_id)
);
create index if not exists message_webhook_events_provider_received_idx
  on public.message_webhook_events (provider, received_at);

-- Notifications are a shared read capability required by all three portals.
insert into public.permissions (id, key, module, label_en, label_ur, description, is_sensitive, display_order)
select 'notification_view', 'notification.view', 'COMMUNICATIONS', 'View notifications', 'اطلاعات دیکھیں', 'Read and manage the current user notification inbox.', false, 500
where not exists (select 1 from public.permissions where key = 'notification.view');
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r cross join public.permissions p
where p.key = 'notification.view'
on conflict do nothing;

alter table public.message_templates enable row level security;
alter table public.messaging_campaigns enable row level security;
alter table public.web_push_subscriptions enable row level security;
alter table public.message_webhook_events enable row level security;

drop policy if exists message_templates_read on public.message_templates;
drop policy if exists message_templates_manage on public.message_templates;
drop policy if exists messaging_campaigns_read on public.messaging_campaigns;
drop policy if exists messaging_campaigns_manage on public.messaging_campaigns;
drop policy if exists web_push_subscriptions_owner on public.web_push_subscriptions;
drop policy if exists users_campaign_recipient_read on public.users;

create policy message_templates_read on public.message_templates
for select to authenticated
using (
  public.has_permission(auth.uid(), 'message.send')
  or public.has_permission(auth.uid(), 'message.campaign')
  or public.has_permission(auth.uid(), 'whatsapp.manage_templates')
);
create policy message_templates_manage on public.message_templates
for all to authenticated
using (public.has_permission(auth.uid(), 'whatsapp.manage_templates'))
with check (public.has_permission(auth.uid(), 'whatsapp.manage_templates'));

create policy messaging_campaigns_read on public.messaging_campaigns
for select to authenticated
using (
  created_by_user_id = auth.uid()
  or public.has_permission(auth.uid(), 'message.campaign')
);
create policy messaging_campaigns_manage on public.messaging_campaigns
for all to authenticated
using (public.has_permission(auth.uid(), 'message.campaign'))
with check (public.has_permission(auth.uid(), 'message.campaign') and created_by_user_id = auth.uid());

create policy web_push_subscriptions_owner on public.web_push_subscriptions
for all to authenticated
using (user_id = auth.uid() and public.has_permission(auth.uid(), 'notification.view'))
with check (user_id = auth.uid() and public.has_permission(auth.uid(), 'notification.view'));

create policy users_campaign_recipient_read on public.users
for select to authenticated
using (public.has_permission(auth.uid(), 'message.campaign'));

-- Webhook events are written by system jobs only. No authenticated policy is intentional.
revoke all on public.message_webhook_events from authenticated;

comment on table public.messaging_campaigns is 'Phase 12 communications campaign queue; outbound delivery is asynchronous.';
comment on table public.message_webhook_events is 'Phase 12 at-least-once webhook deduplication ledger.';
comment on column public.message_logs.attempt_count is 'Provider attempts, capped at three by the system worker.';
comment on column public.message_logs.next_attempt_at is 'UTC retry schedule; exponential backoff is applied by the system worker.';

create or replace function public.claim_communications_messages(p_limit integer default 25)
returns setof public.message_logs
language sql
security definer
set search_path = public
as $$
  update public.message_logs m
  set locked_at = now(),
      last_attempt_at = now(),
      attempt_count = m.attempt_count + 1,
      updated_at = now()
  where m.id in (
    select id
    from public.message_logs
    where direction = 'OUTBOUND'
      and status = 'QUEUED'
      and (next_attempt_at is null or next_attempt_at <= now())
      and (locked_at is null or locked_at < now() - interval '10 minutes')
    order by created_at
    for update skip locked
    limit greatest(1, least(p_limit, 100))
  )
  returning m.*;
$$;
revoke all on function public.claim_communications_messages(integer) from public, authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.claim_communications_messages(integer) to service_role';
  end if;
end $$;

create table if not exists public.message_unsubscribes (
  customer_id uuid not null references public.customers(id) on delete cascade,
  channel "MessageChannel" not null,
  created_at timestamptz(6) not null default now(),
  primary key (customer_id, channel)
);
create index if not exists message_unsubscribes_channel_idx on public.message_unsubscribes(channel);
alter table public.message_unsubscribes enable row level security;
drop policy if exists message_unsubscribes_read on public.message_unsubscribes;
create policy message_unsubscribes_read on public.message_unsubscribes
for select to authenticated
using (
  public.has_permission(auth.uid(), 'message.campaign')
  or exists (select 1 from public.customer_users cu where cu.customer_id = message_unsubscribes.customer_id and cu.user_id = auth.uid())
);
revoke insert, update, delete on public.message_unsubscribes from authenticated;
