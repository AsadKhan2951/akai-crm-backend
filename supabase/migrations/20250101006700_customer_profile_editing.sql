-- Customer profile editing and enrichment.
-- 0. Bug fix: the phone check constraints were written as '^\\+92...' which (with standard
--    strings) requires a literal backslash, so no phone number could ever be saved on a
--    customer or a lead, and lead import skipped every row. Recreated with '^\+92[0-9]{10}$'.
-- 1. data_complete is derived: phone + address + GPS location. A trigger keeps it right
--    whoever edits the row, and existing rows are recalculated.
-- 2. update_customer_profile(): one checked entry point for Admin edits and Sales Agent
--    enrichment. Each field needs the matching permission, the customer must be in the
--    caller's data scope, and every change writes an audit row with before/after values.

create or replace function public.customers_set_data_complete()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.data_complete := coalesce(btrim(new.primary_phone), '') <> ''
    and coalesce(btrim(new.full_address), '') <> ''
    and new.latitude is not null
    and new.longitude is not null;
  return new;
end;
$$;

drop trigger if exists customers_set_data_complete on public.customers;
create trigger customers_set_data_complete
  before insert or update of primary_phone, full_address, latitude, longitude, data_complete on public.customers
  for each row execute function public.customers_set_data_complete();

update public.customers
set data_complete = (coalesce(btrim(primary_phone), '') <> '' and coalesce(btrim(full_address), '') <> '' and latitude is not null and longitude is not null)
where data_complete is distinct from (coalesce(btrim(primary_phone), '') <> '' and coalesce(btrim(full_address), '') <> '' and latitude is not null and longitude is not null);

-- Pakistani numbers are stored as +92XXXXXXXXXX (customers_*_phone_e164_check).
create or replace function public.normalize_pk_phone(p_value text, p_mobile_only boolean default false)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare digits text;
begin
  if p_value is null or btrim(p_value) = '' then return null; end if;
  digits := regexp_replace(p_value, '[^0-9]', '', 'g');
  if digits like '0092%' then digits := substr(digits, 5);
  elsif digits like '92%' and length(digits) = 12 then digits := substr(digits, 3);
  elsif digits like '0%' then digits := substr(digits, 2);
  end if;
  if length(digits) <> 10 or (p_mobile_only and digits !~ '^3') then
    raise exception 'Enter a valid Pakistani % number, e.g. 0300 1234567', case when p_mobile_only then 'mobile' else 'phone' end using errcode = '22023';
  end if;
  return '+92' || digits;
end;
$$;

create or replace function public.update_customer_profile(p_customer_id uuid, p_changes jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  can_update boolean;
  can_enrich boolean;
  can_credit boolean;
  can_reassign boolean;
  enrich_keys constant text[] := array['business_name_urdu','contact_person_name','primary_phone','whatsapp_phone','email','full_address','area_code','latitude','longitude','customer_type'];
  update_keys constant text[] := array['business_name','status','vendor_group_id'];
  k text;
  v jsonb;
  before_row public.customers;
  after_row public.customers;
  txt text;
  num numeric;
begin
  if uid is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' then raise exception 'Nothing to save' using errcode = '22023'; end if;

  can_update := public.has_permission(uid, 'customer.update');
  can_enrich := can_update or public.has_permission(uid, 'customer.enrich');
  can_credit := public.has_permission(uid, 'creditlimit.manage');
  can_reassign := public.has_permission(uid, 'customer.reassign_agent');

  select * into before_row from public.customers c
  where c.id = p_customer_id
    and ((select public.role_scope(uid)) = 'GLOBAL' or c.assigned_agent_id in (select public.accessible_agent_ids(uid)));
  if not found then raise exception 'Customer not found' using errcode = '42501'; end if;

  -- Permission check per field before anything is written.
  for k in select jsonb_object_keys(p_changes) loop
    if k = any(enrich_keys) then
      if not can_enrich then raise exception 'Missing permission: customer.enrich' using errcode = '42501'; end if;
    elsif k = any(update_keys) then
      if not can_update then raise exception 'Missing permission: customer.update' using errcode = '42501'; end if;
    elsif k = 'credit_limit_pkr' then
      if not can_credit then raise exception 'Missing permission: creditlimit.manage' using errcode = '42501'; end if;
    elsif k = 'assigned_agent_id' then
      if not can_reassign then raise exception 'Missing permission: customer.reassign_agent' using errcode = '42501'; end if;
    else
      raise exception 'Field % cannot be edited', k using errcode = '22023';
    end if;
  end loop;

  after_row := before_row;
  for k, v in select * from jsonb_each(p_changes) loop
    txt := nullif(btrim(case when jsonb_typeof(v) = 'null' then '' else v #>> '{}' end), '');
    case k
      when 'business_name' then
        if txt is null then raise exception 'Business name is required' using errcode = '22023'; end if;
        after_row.business_name := left(txt, 200);
      when 'business_name_urdu' then after_row.business_name_urdu := left(txt, 200);
      when 'contact_person_name' then after_row.contact_person_name := left(txt, 120);
      when 'primary_phone' then
        after_row.primary_phone := public.normalize_pk_phone(txt, false);
      when 'whatsapp_phone' then
        after_row.whatsapp_phone := public.normalize_pk_phone(txt, true);
      when 'email' then
        if txt is not null and txt !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email' using errcode = '22023'; end if;
        after_row.email := lower(txt);
      when 'full_address' then after_row.full_address := left(txt, 500);
      when 'area_code' then
        if txt is not null and length(txt) < 2 then raise exception 'Area code is too short' using errcode = '22023'; end if;
        after_row.area_code := upper(left(txt, 32));
      when 'latitude' then
        num := txt::numeric;
        if num is not null and (num < 23 or num > 38) then raise exception 'Latitude is outside Pakistan' using errcode = '22023'; end if;
        after_row.latitude := num;
      when 'longitude' then
        num := txt::numeric;
        if num is not null and (num < 60 or num > 78) then raise exception 'Longitude is outside Pakistan' using errcode = '22023'; end if;
        after_row.longitude := num;
      when 'customer_type' then after_row.customer_type := coalesce(txt, 'OTHER')::"CustomerType";
      when 'status' then after_row.status := coalesce(txt, 'ACTIVE')::"CustomerStatus";
      when 'vendor_group_id' then after_row.vendor_group_id := txt::uuid;
      when 'credit_limit_pkr' then
        num := coalesce(txt::numeric, 0);
        if num < 0 then raise exception 'Credit limit cannot be negative' using errcode = '22023'; end if;
        after_row.credit_limit_pkr := round(num, 2);
      when 'assigned_agent_id' then
        if txt is not null and not exists (select 1 from public.sales_agents where id = txt::uuid) then raise exception 'Unknown Sales Agent' using errcode = '22023'; end if;
        after_row.assigned_agent_id := txt::uuid;
    end case;
  end loop;

  update public.customers c set
    business_name = after_row.business_name,
    business_name_urdu = after_row.business_name_urdu,
    contact_person_name = after_row.contact_person_name,
    primary_phone = after_row.primary_phone,
    whatsapp_phone = after_row.whatsapp_phone,
    email = after_row.email,
    full_address = after_row.full_address,
    area_code = after_row.area_code,
    latitude = after_row.latitude,
    longitude = after_row.longitude,
    customer_type = after_row.customer_type,
    status = after_row.status,
    vendor_group_id = after_row.vendor_group_id,
    credit_limit_pkr = after_row.credit_limit_pkr,
    assigned_agent_id = after_row.assigned_agent_id,
    updated_at = now()
  where c.id = p_customer_id
  returning * into after_row;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, changes_json)
  values (uid, 'UPDATE_PROFILE', 'CUSTOMER', p_customer_id::text, jsonb_build_object(
    'before', (select jsonb_object_agg(key, value) from jsonb_each(to_jsonb(before_row)) where key in (select jsonb_object_keys(p_changes))),
    'after', (select jsonb_object_agg(key, value) from jsonb_each(to_jsonb(after_row)) where key in (select jsonb_object_keys(p_changes)))
  ));

  return jsonb_build_object('id', after_row.id, 'data_complete', after_row.data_complete);
exception
  when invalid_text_representation then raise exception 'One of the values has the wrong format' using errcode = '22023';
  when numeric_value_out_of_range then raise exception 'One of the numbers is out of range' using errcode = '22023';
end;
$$;
revoke all on function public.update_customer_profile(uuid, jsonb) from public, anon;
grant execute on function public.update_customer_profile(uuid, jsonb) to authenticated, service_role;

-- 0. Phone format fix (see header) --------------------------------------------------------
alter table public.customers drop constraint if exists customers_primary_phone_e164_check;
alter table public.customers add constraint customers_primary_phone_e164_check check (primary_phone is null or primary_phone ~ '^\+92[0-9]{10}$');
alter table public.customers drop constraint if exists customers_whatsapp_phone_e164_check;
alter table public.customers add constraint customers_whatsapp_phone_e164_check check (whatsapp_phone is null or whatsapp_phone ~ '^\+92[0-9]{10}$');
alter table public.leads drop constraint if exists leads_phone_e164_check;
alter table public.leads add constraint leads_phone_e164_check check (phone ~ '^\+92[0-9]{10}$');

create or replace function public.import_sales_leads(
  p_batch_id text,
  p_assigned_agent_id uuid,
  p_source_filename text,
  p_rows jsonb
)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
  inserted_count integer;
begin
  if not public.has_permission(auth.uid(), 'lead.import') then
    raise exception using errcode = '42501', message = 'Lead import is not permitted.';
  end if;
  if p_assigned_agent_id not in (select public.accessible_agent_ids(auth.uid())) then
    raise exception using errcode = '42501', message = 'The selected Sales Agent is outside your data scope.';
  end if;
  if exists (select 1 from public.lead_import_batches where id = p_batch_id) then
    raise exception using errcode = '22023', message = 'This import batch identifier has already been used.';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception using errcode = '22023', message = 'The import does not contain any lead rows.';
  end if;

  insert into public.lead_import_batches (id, created_by_user_id, assigned_agent_id, source_filename, row_count)
  values (p_batch_id, auth.uid(), p_assigned_agent_id, nullif(trim(p_source_filename), ''), jsonb_array_length(p_rows));

  insert into public.leads (
    id, business_name, contact_name, phone, email, area_code, full_address,
    source, stage, assigned_agent_id, normalized_name, estimated_value_pkr,
    import_batch_id
  )
  select
    gen_random_uuid(), r.business_name, coalesce(nullif(r.contact_name, ''), r.business_name), r.phone,
    nullif(r.email, ''), r.area_code, nullif(r.full_address, ''), 'IMPORT', 'NEW',
    p_assigned_agent_id,
    upper(regexp_replace(trim(regexp_replace(r.business_name, '[[:space:]]+', ' ', 'g')), '[^A-Za-z0-9]+', '', 'g')),
    coalesce(nullif(r.estimated_value_pkr, ''), '0')::numeric(12,2), p_batch_id
  from jsonb_to_recordset(p_rows) as r(
    business_name text,
    contact_name text,
    phone text,
    email text,
    area_code text,
    full_address text,
    estimated_value_pkr text
  )
  where nullif(trim(r.business_name), '') is not null
    and r.phone ~ '^\+92[0-9]{10}$'
    and not exists (select 1 from public.leads l where l.phone = r.phone or l.normalized_name = upper(regexp_replace(trim(regexp_replace(r.business_name, '[[:space:]]+', ' ', 'g')), '[^A-Za-z0-9]+', '', 'g')))
    and not exists (select 1 from public.customers c where c.primary_phone = r.phone or c.normalized_name = upper(regexp_replace(trim(regexp_replace(r.business_name, '[[:space:]]+', ' ', 'g')), '[^A-Za-z0-9]+', '', 'g')));
  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;
grant execute on function public.import_sales_leads(text, uuid, text, jsonb) to authenticated;
