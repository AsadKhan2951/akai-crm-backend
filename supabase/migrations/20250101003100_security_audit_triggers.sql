-- AKAI CRM Phase 15 security hardening: audit every protected-domain mutation.
-- Additive only. The trigger uses the database session auth identity and is not callable by users.

create or replace function public.audit_protected_mutation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  before_data jsonb;
  after_data jsonb;
  entity_id text;
begin
  if tg_op in ('UPDATE','DELETE') then before_data := to_jsonb(old); end if;
  if tg_op in ('INSERT','UPDATE') then after_data := to_jsonb(new); end if;
  entity_id := coalesce(after_data->>'id', before_data->>'id');
  if entity_id is null then
    entity_id := coalesce(after_data->>'role_id', before_data->>'role_id', '') || ':' || coalesce(after_data->>'permission_id', before_data->>'permission_id', '');
  end if;
  insert into public.audit_logs(id,user_id,action,entity_type,entity_id,changes_json)
  values (
    gen_random_uuid()::text,
    auth.uid(),
    tg_op,
    upper(tg_table_name),
    entity_id,
    jsonb_build_object('before', coalesce(before_data, 'null'::jsonb), 'after', coalesce(after_data, 'null'::jsonb))
  );
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

revoke all on function public.audit_protected_mutation() from public, anon, authenticated;

create index if not exists audit_logs_entity_created_idx
  on public.audit_logs (entity_type, entity_id, created_at desc);

do $$
declare
  target_table text;
begin
  drop trigger if exists audit_roles on public.roles;
  drop trigger if exists audit_role_permissions on public.role_permissions;
  drop trigger if exists audit_users on public.users;
  foreach target_table in array array[
    'customers','orders','quotes','ledger_entries','payment_collections',
    'loyalty_transactions','products','price_lists','catalog_visibility_rules',
    'roles','role_permissions','users'
  ] loop
    if to_regclass('public.' || target_table) is not null then
      execute format('drop trigger if exists audit_%s_mutation on public.%I', target_table, target_table);
      execute format('create trigger audit_%s_mutation after insert or update or delete on public.%I for each row execute function public.audit_protected_mutation()', target_table, target_table);
    end if;
  end loop;
end $$;
