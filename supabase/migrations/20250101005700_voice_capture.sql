-- AKAI CRM Phase 23: voice capture in Urdu and Roman Urdu.
-- Additive only. Applied migrations are never edited.

do $$ begin
  create type public."VoiceProcessingStatus" as enum ('PENDING', 'PROCESSING', 'COMPLETE', 'FAILED');
exception when duplicate_object then null;
end $$;

create table if not exists public.voice_notes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete restrict,
  activity_id uuid null references public.activities(id) on delete set null,
  claim_id uuid null references public.claims(id) on delete set null,
  customer_id uuid null references public.customers(id) on delete set null,
  audio_url text not null,
  duration_seconds integer not null check (duration_seconds > 0 and duration_seconds <= 120),
  transcript text null,
  transcript_language text null check (transcript_language is null or transcript_language in ('ur', 'roman-ur', 'en', 'mixed', 'unknown')),
  structured_output_json jsonb null,
  processing_status public."VoiceProcessingStatus" not null default 'PENDING',
  processing_error text null,
  processed_at timestamptz(6) null,
  created_at timestamptz(6) not null default now(),
  updated_at timestamptz(6) not null default now()
);

create index if not exists voice_notes_user_created_idx on public.voice_notes(user_id, created_at desc);
create index if not exists voice_notes_customer_created_idx on public.voice_notes(customer_id, created_at desc);
create index if not exists voice_notes_activity_idx on public.voice_notes(activity_id);
create index if not exists voice_notes_claim_idx on public.voice_notes(claim_id);
create index if not exists voice_notes_processing_idx on public.voice_notes(processing_status, created_at);

alter table public.voice_notes enable row level security;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('voice-notes', 'voice-notes', false, 5242880, array['audio/webm', 'audio/mpeg', 'audio/wav', 'audio/mp4'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists voice_notes_select_scoped on public.voice_notes;
create policy voice_notes_select_scoped on public.voice_notes
  for select to authenticated
  using (
    user_id = auth.uid()
    or (
      public.has_permission(auth.uid(), 'voice.view')
      and (
        exists (
          select 1 from public.customers c
          where c.id = voice_notes.customer_id
            and (
              c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
              or exists (select 1 from public.customer_users cu where cu.customer_id = c.id and cu.user_id = auth.uid())
              or public.role_scope(auth.uid()) = 'GLOBAL'
            )
        )
        or exists (
          select 1 from public.activities a
          where a.id = voice_notes.activity_id
            and a.agent_id in (select public.accessible_agent_ids(auth.uid()))
        )
        or exists (
          select 1 from public.claims cl
          where cl.id = voice_notes.claim_id
            and (
              cl.customer_id in (select c.id from public.customers c where c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())))
              or cl.raised_by_user_id = auth.uid()
              or public.role_scope(auth.uid()) = 'GLOBAL'
            )
        )
      )
    )
  );

drop policy if exists voice_notes_insert_scoped on public.voice_notes;
create policy voice_notes_insert_scoped on public.voice_notes
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and (
      customer_id is null
      or exists (
        select 1 from public.customers c
        where c.id = voice_notes.customer_id
          and (
            c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
            or exists (select 1 from public.customer_users cu where cu.customer_id = c.id and cu.user_id = auth.uid())
            or public.role_scope(auth.uid()) = 'GLOBAL'
          )
      )
    )
  );

revoke update, delete on public.voice_notes from authenticated;

-- Replace the legacy shared upload rule so voice audio has its own exact allowlist.
drop policy if exists "Authenticated users upload validated media" on storage.objects;
create policy "Authenticated users upload validated media"
  on storage.objects for insert to authenticated
  with check (
    bucket_id in ('product-images', 'banner-images', 'category-images', 'brand-logos', 'claim-photos')
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and coalesce(nullif(metadata->>'size', ''), '0')::bigint <= case when bucket_id = 'banner-images' then 2097152 else 5242880 end
    and metadata->>'mimetype' in ('image/jpeg', 'image/png', 'image/webp', 'image/svg+xml')
  );

drop policy if exists voice_notes_read_scoped on storage.objects;
create policy voice_notes_read_scoped on storage.objects
  for select to authenticated
  using (
    bucket_id = 'voice-notes'
    and exists (
      select 1 from public.voice_notes v
      where v.audio_url = name
        and (
          v.user_id = auth.uid()
          or (
            public.has_permission(auth.uid(), 'voice.view')
            and (
              (v.customer_id is not null and exists (
                select 1 from public.customers c
                where c.id = v.customer_id
                  and (c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) or public.role_scope(auth.uid()) = 'GLOBAL')
              ))
              or (v.activity_id is not null and exists (
                select 1 from public.activities a
                where a.id = v.activity_id
                  and a.agent_id in (select public.accessible_agent_ids(auth.uid()))
              ))
              or (v.claim_id is not null and exists (
                select 1 from public.claims cl
                where cl.id = v.claim_id
                  and (
                    cl.customer_id in (select c.id from public.customers c where c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())))
                    or cl.raised_by_user_id = auth.uid()
                    or public.role_scope(auth.uid()) = 'GLOBAL'
                  )
              ))
            )
          )
        )
    )
  );

drop policy if exists voice_notes_insert_storage_scoped on storage.objects;
create policy voice_notes_insert_storage_scoped on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'voice-notes'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and coalesce(nullif(metadata->>'size', ''), '0')::bigint <= 5242880
    and metadata->>'mimetype' in ('audio/webm', 'audio/mpeg', 'audio/wav', 'audio/mp4')
  );

drop policy if exists voice_notes_delete_system_only on storage.objects;
create policy voice_notes_delete_system_only on storage.objects
  for delete to authenticated
  using (false);

insert into public.permissions(id, key, module, label_en, label_ur, description, is_sensitive, display_order)
values
  (gen_random_uuid(), 'voice.capture', 'ACTIVITY', 'Capture voice notes', 'Voice note ریکارڈ کریں', 'Allows a user to record and upload a voice note for an in-scope CRM surface.', false, 94),
  (gen_random_uuid(), 'voice.view', 'ACTIVITY', 'Play voice notes', 'Voice notes سنیں', 'Allows playback of voice notes within the user data scope.', false, 95)
on conflict (key) do nothing;

insert into public.role_permissions(role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where p.key in ('voice.capture', 'voice.view')
  and r.name in ('Administrator', 'Sales Agent', 'Sales Manager', 'Support Agent')
  and r.is_active = true
on conflict (role_id, permission_id) do nothing;

insert into public.settings(key, value_json, description, updated_by_user_id, updated_at)
select 'voice_retention_months', '{"value":"12"}'::jsonb, 'How many months to retain voice audio and transcripts. Default is 12.', u.id, now()
from public.users u
where exists (select 1 from public.roles r where r.id = u.role_id and r.name = 'Administrator')
order by u.created_at
limit 1
on conflict (key) do nothing;

create or replace function public.attach_voice_note_to_activity(p_voice_note_id uuid, p_activity_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  activity_customer_id uuid;
  note_user_id uuid;
begin
  if not public.has_permission(auth.uid(), 'voice.capture') then
    raise exception using errcode = '42501', message = 'Voice note attachment is not permitted.';
  end if;
  select a.customer_id into activity_customer_id
  from public.activities a
  where a.id = p_activity_id
    and a.agent_id in (select public.accessible_agent_ids(auth.uid()));
  if not found then
    raise exception using errcode = '42501', message = 'This activity is outside your data scope.';
  end if;
  select v.user_id into note_user_id
  from public.voice_notes v
  where v.id = p_voice_note_id
    and v.user_id = auth.uid()
    and v.processing_status = 'COMPLETE'
    and v.activity_id is null
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'This voice note cannot be attached.';
  end if;
  update public.voice_notes
  set activity_id = p_activity_id,
      customer_id = coalesce(customer_id, activity_customer_id),
      updated_at = now()
  where id = p_voice_note_id and user_id = note_user_id;
end;
$$;
grant execute on function public.attach_voice_note_to_activity(uuid, uuid) to authenticated;

create or replace function public.attach_voice_note_to_claim(p_voice_note_id uuid, p_claim_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare claim_customer_id uuid;
begin
  if not public.has_permission(auth.uid(), 'voice.capture') then
    raise exception using errcode = '42501', message = 'Voice note attachment is not permitted.';
  end if;
  select c.customer_id into claim_customer_id
  from public.claims c
  where c.id = p_claim_id and c.raised_by_user_id = auth.uid();
  if not found then raise exception using errcode = '42501', message = 'This claim is outside your scope.'; end if;
  update public.voice_notes
  set claim_id = p_claim_id, customer_id = coalesce(customer_id, claim_customer_id), updated_at = now()
  where id = p_voice_note_id and user_id = auth.uid() and processing_status = 'COMPLETE' and activity_id is null and claim_id is null;
  if not found then raise exception using errcode = '42501', message = 'This voice note cannot be attached.'; end if;
end;
$$;
grant execute on function public.attach_voice_note_to_claim(uuid, uuid) to authenticated;

create or replace function public.claim_voice_notes(p_limit integer default 10)
returns table(id uuid, user_id uuid, customer_id uuid, audio_url text, duration_seconds integer, transcript text, structured_output_json jsonb)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  with picked as (
    select v.id
    from public.voice_notes v
    where v.processing_status = 'PENDING'
    order by v.created_at
    limit greatest(1, least(p_limit, 50))
    for update skip locked
  )
  update public.voice_notes v
  set processing_status = 'PROCESSING', updated_at = now()
  from picked
  where v.id = picked.id
  returning v.id, v.user_id, v.customer_id, v.audio_url, v.duration_seconds, v.transcript, v.structured_output_json;
end;
$$;
revoke all on function public.claim_voice_notes(integer) from public, authenticated;

create or replace function public.mark_voice_note_failed(p_voice_note_id uuid, p_error text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.voice_notes
  set processing_status = 'FAILED', processing_error = left(coalesce(p_error, 'Voice processing failed.'), 1000), updated_at = now()
  where id = p_voice_note_id and processing_status = 'PROCESSING';
end;
$$;
revoke all on function public.mark_voice_note_failed(uuid, text) from public, authenticated;

create or replace function public.delete_expired_voice_notes(p_retention_months integer default 12)
returns table(id uuid, audio_url text)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  delete from public.voice_notes
  where created_at < (now() - make_interval(months => greatest(1, least(p_retention_months, 120))))
  returning voice_notes.id, voice_notes.audio_url;
end;
$$;
revoke all on function public.delete_expired_voice_notes(integer) from public, authenticated;

create or replace function public.list_expired_voice_notes(p_retention_months integer default 12)
returns table(id uuid, audio_url text)
language sql
security definer
set search_path = public
as $$
  select v.id, v.audio_url
  from public.voice_notes v
  where v.created_at < (now() - make_interval(months => greatest(1, least(p_retention_months, 120))))
  order by v.created_at
  limit 500;
$$;
revoke all on function public.list_expired_voice_notes(integer) from public, authenticated;

create or replace function public.purge_expired_voice_notes(p_ids uuid[], p_retention_months integer default 12)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_count integer;
begin
  delete from public.voice_notes v
  where v.id = any(coalesce(p_ids, '{}'::uuid[]))
    and v.created_at < (now() - make_interval(months => greatest(1, least(p_retention_months, 120))));
  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;
revoke all on function public.purge_expired_voice_notes(uuid[], integer) from public, authenticated;

comment on table public.voice_notes is 'Voice notes retain original audio and extraction evidence; processing is asynchronous and save requires explicit confirmation.';
comment on column public.voice_notes.audio_url is 'Private voice-notes Storage object path, never a public URL.';
comment on column public.voice_notes.structured_output_json is 'Draft-only extraction. It is not an order, activity, or follow-up until a human confirms.';
