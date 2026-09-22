-- AKAI CRM Phase 14 corrective migration.
-- 0028 is already applied locally; add the missing invoker-table RLS policies separately.

create policy offline_sync_receipts_select_own on public.offline_sync_receipts
  for select to authenticated
  using (user_id = auth.uid());

create policy offline_sync_receipts_insert_own on public.offline_sync_receipts
  for insert to authenticated
  with check (user_id = auth.uid());
