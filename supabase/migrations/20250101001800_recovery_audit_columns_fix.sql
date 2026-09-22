-- Corrective Phase 11 migration. Do not edit 0014, 0015, 0016, or 0017.
create or replace function public.recovery_audit(p_action text, p_entity_type text, p_entity_id text, p_after jsonb)
returns void language plpgsql security definer set search_path=public as $$
begin
  insert into public.audit_logs(id,user_id,entity_type,entity_id,action,changes_json)
  values(gen_random_uuid()::text,auth.uid(),p_entity_type,p_entity_id,p_action,p_after);
end; $$;
revoke all on function public.recovery_audit(text,text,text,jsonb) from public,authenticated;
