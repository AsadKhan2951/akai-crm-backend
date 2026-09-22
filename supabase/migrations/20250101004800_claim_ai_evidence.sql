-- AKAI CRM Phase 20 AI evidence helpers. Additive only.

CREATE OR REPLACE FUNCTION public.claim_photo_duplicate_candidates(p_claim_id uuid) RETURNS TABLE(photo_url text,matched_claim_id uuid,matched_claim_number text) LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$
SELECT cp.url,c2.id,c2.claim_number FROM public.claim_photos cp JOIN public.claim_photos other ON other.url=cp.url AND other.claim_id<>cp.claim_id JOIN public.claims c2 ON c2.id=other.claim_id WHERE cp.claim_id=p_claim_id AND public.has_permission(auth.uid(),'claim.view') AND public.claim_customer_in_scope(c2.customer_id);
$$;
GRANT EXECUTE ON FUNCTION public.claim_photo_duplicate_candidates(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.claim_pattern_summary(p_claim_id uuid) RETURNS TABLE(customer_claim_count bigint,customer_last_90_day_count bigint,customer_resolved_count bigint) LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$
SELECT count(*),count(*) FILTER (WHERE c.created_at >= now()-interval '90 days'),count(*) FILTER (WHERE c.status='RESOLVED') FROM public.claims target JOIN public.claims c ON c.customer_id=target.customer_id WHERE target.id=p_claim_id AND public.has_permission(auth.uid(),'claim.view') AND public.claim_customer_in_scope(target.customer_id);
$$;
GRANT EXECUTE ON FUNCTION public.claim_pattern_summary(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.claim_root_cause_groups(p_claim_id uuid) RETURNS TABLE(product_name text,batch_or_serial text,claim_count bigint) LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$
SELECT p.name_en,cl.batch_or_serial,count(DISTINCT c.id) FROM public.claims target JOIN public.claims c ON c.customer_id=target.customer_id JOIN public.claim_lines cl ON cl.claim_id=c.id JOIN public.products p ON p.id=cl.product_id WHERE target.id=p_claim_id AND public.has_permission(auth.uid(),'claim.view') AND public.claim_customer_in_scope(target.customer_id) AND nullif(trim(cl.batch_or_serial),'') IS NOT NULL GROUP BY p.name_en,cl.batch_or_serial ORDER BY 3 DESC;
$$;
GRANT EXECUTE ON FUNCTION public.claim_root_cause_groups(uuid) TO authenticated;
