-- User onboarding without a service-role key in the app.
--
-- 1. An Admin records the person in the CRM (admin_user_invites): email, name, role,
--    and for a Vendor the customer account, for a Sales Agent an agent code.
-- 2. The login itself is created in Supabase Authentication (Add user / Invite user).
-- 3. Whichever happens second links them: a trigger on auth.users provisions the CRM
--    user from a pending invite, and provision_invited_user() does the same when the
--    login already existed before the invite.

alter table public.admin_user_invites
  add column if not exists customer_id uuid references public.customers(id) on delete set null,
  add column if not exists agent_code text,
  add column if not exists accepted_user_id uuid references public.users(id) on delete set null,
  add column if not exists accepted_at timestamptz;

create or replace function public.provision_user_from_invite(p_auth_user_id uuid, p_email text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite public.admin_user_invites;
  v_portal "Portal";
  v_code text;
begin
  if exists (select 1 from public.users where id = p_auth_user_id) then
    return 'ALREADY_ACTIVE';
  end if;
  select * into v_invite
  from public.admin_user_invites
  where lower(email) = lower(trim(p_email)) and status in ('PENDING', 'SENT')
  order by created_at desc
  limit 1
  for update;
  if not found then
    return 'NO_INVITE';
  end if;

  insert into public.users (id, email, full_name, phone, role_id, manager_id, is_active, preferred_locale)
  values (p_auth_user_id, lower(trim(p_email)), v_invite.full_name, v_invite.phone, v_invite.role_id, v_invite.manager_id, true, v_invite.preferred_locale);

  select portal_access into v_portal from public.roles where id = v_invite.role_id;
  if v_portal = 'VENDOR' and v_invite.customer_id is not null then
    insert into public.customer_users (user_id, customer_id) values (p_auth_user_id, v_invite.customer_id) on conflict do nothing;
  elsif v_portal = 'SALES' and not exists (select 1 from public.sales_agents where user_id = p_auth_user_id) then
    v_code := upper(coalesce(nullif(trim(v_invite.agent_code), ''), regexp_replace(split_part(v_invite.full_name, ' ', 1), '[^A-Za-z0-9]', '', 'g')));
    if v_code = '' or exists (select 1 from public.sales_agents where agent_code = v_code) then
      v_code := coalesce(nullif(v_code, ''), 'AGENT') || '-' || upper(substr(replace(p_auth_user_id::text, '-', ''), 1, 4));
    end if;
    insert into public.sales_agents (id, user_id, agent_code, territory, monthly_target_pkr, joined_at)
    values (gen_random_uuid(), p_auth_user_id, v_code, 'Karachi', 0, now());
  end if;

  update public.admin_user_invites
     set status = 'ACCEPTED', accepted_user_id = p_auth_user_id, accepted_at = now()
   where id = v_invite.id;
  return 'LINKED';
end;
$$;
revoke all on function public.provision_user_from_invite(uuid, text) from public, anon, authenticated;
grant execute on function public.provision_user_from_invite(uuid, text) to service_role;

-- Login created after the invite: link automatically. Never block the Auth insert.
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public.provision_user_from_invite(new.id, new.email);
  exception when others then
    raise warning 'AKAI CRM could not provision user %: %', new.email, sqlerrm;
  end;
  return new;
end;
$$;
drop trigger if exists akai_on_auth_user_created on auth.users;
create trigger akai_on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- Login created before the invite: an Admin links it from the Users screen.
create or replace function public.provision_invited_user(p_email text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_auth_id uuid;
begin
  if not public.has_permission(auth.uid(), 'user.create') then
    raise exception using errcode = '42501', message = 'Creating users is not permitted.';
  end if;
  select id into v_auth_id from auth.users where lower(email) = lower(trim(p_email)) limit 1;
  if v_auth_id is null then
    return 'WAITING_FOR_LOGIN';
  end if;
  return public.provision_user_from_invite(v_auth_id, p_email);
end;
$$;
revoke all on function public.provision_invited_user(text) from public, anon;
grant execute on function public.provision_invited_user(text) to authenticated;

-- Admins can cancel a pending invite they are allowed to manage.
create index if not exists admin_user_invites_accepted_user_idx on public.admin_user_invites (accepted_user_id);
