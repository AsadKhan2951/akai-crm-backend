-- AKAI CRM Phase 20 corrective migration.
-- 0046-0048 are applied and immutable. Additive replacement functions only.

CREATE OR REPLACE FUNCTION public.review_claim(p_claim_id uuid,p_status text,p_resolution_type text DEFAULT NULL,p_rejection_reason text DEFAULT NULL,p_notes text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $$
DECLARE claim_row public.claims;
BEGIN
  IF p_status='APPROVED' THEN
    IF NOT public.has_permission(auth.uid(),'claim.approve') THEN RAISE EXCEPTION 'Claim approval is not permitted.'; END IF;
  ELSIF p_status IN ('UNDER_REVIEW','REJECTED') THEN
    IF NOT public.has_permission(auth.uid(),'claim.review') THEN RAISE EXCEPTION 'Claim review is not permitted.'; END IF;
  ELSE
    RAISE EXCEPTION 'Invalid review status.';
  END IF;
  SELECT * INTO claim_row FROM public.claims WHERE id=p_claim_id FOR UPDATE;
  IF NOT FOUND OR claim_row.status IN ('REJECTED','RESOLVED') THEN RAISE EXCEPTION 'This claim is no longer reviewable.'; END IF;
  IF p_status='REJECTED' AND nullif(trim(p_rejection_reason),'') IS NULL THEN RAISE EXCEPTION 'A rejection reason is required.'; END IF;
  IF p_status='APPROVED' AND p_resolution_type NOT IN ('REPLACEMENT','CREDIT_NOTE','REFUND','REPAIR','NO_ACTION') THEN RAISE EXCEPTION 'An approved claim needs a resolution.'; END IF;
  UPDATE public.claims SET status=p_status::public."ClaimStatus",resolution_type=CASE WHEN p_resolution_type IS NULL THEN resolution_type ELSE p_resolution_type::public."ClaimResolutionType" END,rejection_reason=CASE WHEN p_status='REJECTED' THEN trim(p_rejection_reason) ELSE NULL END,reviewed_by_user_id=auth.uid(),reviewed_at=now(),first_reviewed_at=coalesce(first_reviewed_at,now()),resolution_notes=coalesce(nullif(trim(p_notes),''),resolution_notes) WHERE id=p_claim_id;
  RETURN p_claim_id;
END; $$;

CREATE OR REPLACE FUNCTION public.claim_sla_breach_rows() RETURNS TABLE(claim_id uuid,claim_number text,customer_id uuid,breach_type text) LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
SELECT id,claim_number,customer_id,'FIRST_REVIEW' FROM public.claims WHERE status IN ('SUBMITTED','UNDER_REVIEW') AND (created_at AT TIME ZONE 'Asia/Karachi')::date < public.business_date_before((now() AT TIME ZONE 'Asia/Karachi')::date,2)
UNION ALL
SELECT id,claim_number,customer_id,'RESOLUTION' FROM public.claims WHERE status='APPROVED' AND reviewed_at IS NOT NULL AND (reviewed_at AT TIME ZONE 'Asia/Karachi')::date < public.business_date_before((now() AT TIME ZONE 'Asia/Karachi')::date,3);
$$;

CREATE OR REPLACE FUNCTION public.claim_sla_admin_user_ids() RETURNS TABLE(user_id uuid) LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
SELECT DISTINCT u.id FROM public.users u JOIN public.role_permissions rp ON rp.role_id=u.role_id JOIN public.permissions p ON p.id=rp.permission_id WHERE u.is_active AND p.key IN ('claim.review','claim.approve');
$$;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.claim_sla_breach_rows() TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.claim_sla_admin_user_ids() TO service_role';
  END IF;
END $$;
