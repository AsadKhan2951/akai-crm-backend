-- AKAI CRM Phase 13C/13D/13E role-surface indexes.
-- Additive only. Supports the new current-user recommendation and catalogue queries.

create index if not exists follow_ups_is_completed_due_at_customer_id_idx
  on public.follow_ups (is_completed, due_at, customer_id);
create index if not exists quotes_status_created_at_customer_id_idx
  on public.quotes (status, created_at, customer_id);
create index if not exists products_active_name_en_idx
  on public.products (is_active, name_en);

comment on index public.follow_ups_is_completed_due_at_customer_id_idx is 'Sales AI open follow-up recommendations filter and due-date ordering.';
comment on index public.quotes_status_created_at_customer_id_idx is 'Sales AI open quote recommendations filter and recent ordering.';
comment on index public.products_active_name_en_idx is 'RLS-scoped AI catalogue keyword fallback active product ordering.';
