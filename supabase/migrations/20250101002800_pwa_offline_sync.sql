-- AKAI CRM Phase 14: offline sync idempotency and permission boundary.
-- Additive only. Offline writes use one database transaction per operation.

create table if not exists public.offline_sync_receipts (
  idempotency_key uuid primary key,
  user_id uuid not null,
  operation_kind text not null check (operation_kind in ('activity','collection','salesOrder')),
  result_json jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists offline_sync_receipts_user_created_idx
  on public.offline_sync_receipts (user_id, created_at desc);

alter table public.offline_sync_receipts enable row level security;
revoke all on public.offline_sync_receipts from authenticated;

insert into public.permissions (id, key, module, label_en, label_ur, description, is_sensitive, display_order)
values (gen_random_uuid(), 'pwa.sync', 'PWA', 'Sync offline work', 'Offline کام sync کریں', 'Allows the current user to submit their own locally queued work for processing.', false, 90)
on conflict (key) do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r cross join public.permissions p
where p.key = 'pwa.sync' and r.portal_access in ('SALES','VENDOR') and r.is_active = true
on conflict (role_id, permission_id) do nothing;

create or replace function public.process_offline_operation(
  p_idempotency_key uuid,
  p_operation_kind text,
  p_payload jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  existing_result jsonb;
  result jsonb;
  activity_id uuid;
  order_id uuid;
  collection_result record;
  invoice_numbers text[] := array(select jsonb_array_elements_text(coalesce(p_payload->'againstInvoiceNumbers','[]'::jsonb)));
begin
  if not public.has_permission(auth.uid(), 'pwa.sync') then
    raise exception using errcode = '42501', message = 'Offline sync is not permitted.';
  end if;
  if p_idempotency_key is null or p_operation_kind not in ('activity','collection','salesOrder') or jsonb_typeof(p_payload) <> 'object' then
    raise exception using errcode = '22023', message = 'The offline operation is invalid.';
  end if;

  select r.result_json into existing_result
  from public.offline_sync_receipts r
  where r.idempotency_key = p_idempotency_key and r.user_id = auth.uid();
  if found then return existing_result; end if;

  if p_operation_kind = 'activity' then
    select public.log_sales_activity(
      (p_payload->>'type')::"ActivityType",
      nullif(p_payload->>'customerId','')::uuid,
      nullif(p_payload->>'leadId','')::uuid,
      coalesce(nullif(p_payload->>'disposition','')::"ActivityDisposition", 'CONNECTED'::"ActivityDisposition"),
      coalesce(p_payload->>'notes',''),
      coalesce(nullif(p_payload->>'occurredAt','')::timestamptz, now()),
      nullif(p_payload->>'latitude','')::numeric,
      nullif(p_payload->>'longitude','')::numeric,
      nullif(p_payload->>'accuracyMeters','')::numeric,
      nullif(p_payload->>'followUpDueAt','')::timestamptz,
      nullif(p_payload->>'followUpNote',''),
      coalesce(nullif(p_payload->>'followUpPriority','')::"Priority", 'MEDIUM'::"Priority")
    ) into activity_id;
    result := jsonb_build_object('activityId', activity_id);
  elsif p_operation_kind = 'collection' then
    select x.collection_id, x.receipt_number into collection_result
    from public.record_payment_collection(
      (p_payload->>'customerId')::uuid,
      (p_payload->>'amountPKR')::numeric(12,2),
      (p_payload->>'method')::"CollectionMethod",
      nullif(p_payload->>'chequeNumber',''),
      nullif(p_payload->>'chequeDate','')::date,
      nullif(p_payload->>'bankName',''),
      invoice_numbers,
      nullif(p_payload->>'latitude','')::numeric,
      nullif(p_payload->>'longitude','')::numeric,
      nullif(p_payload->>'photoUrl',''),
      nullif(p_payload->>'notes','')
    ) x;
    result := jsonb_build_object('collectionId', collection_result.collection_id, 'receiptNumber', collection_result.receipt_number);
  elsif p_operation_kind = 'salesOrder' then
    select public.create_sales_order_for_customer(
      (p_payload->>'customerId')::uuid,
      p_payload->'lines',
      nullif(p_payload->>'notes',''),
      coalesce(nullif(p_payload->>'paymentMethod','')::"PaymentMethod", 'BALANCE'::"PaymentMethod")
    ) into order_id;
    result := jsonb_build_object('orderId', order_id);
  end if;

  insert into public.offline_sync_receipts(idempotency_key,user_id,operation_kind,result_json)
  values (p_idempotency_key, auth.uid(), p_operation_kind, result);
  return result;
end;
$$;

grant execute on function public.process_offline_operation(uuid,text,jsonb) to authenticated;
