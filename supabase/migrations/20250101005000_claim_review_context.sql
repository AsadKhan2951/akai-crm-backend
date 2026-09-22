-- AKAI CRM Phase 20 review context. Additive only.
CREATE OR REPLACE FUNCTION public.claim_review_context() RETURNS TABLE(claim_id uuid,customer_claim_count bigint,customer_last_90_day_count bigint,customer_order_count bigint,last_order_at timestamptz) LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$
SELECT target.id,count(DISTINCT c.id),count(DISTINCT c.id) FILTER (WHERE c.created_at>=now()-interval '90 days'),count(DISTINCT o.id),max(o.placed_at) FROM public.claims target JOIN public.customers cu ON cu.id=target.customer_id LEFT JOIN public.claims c ON c.customer_id=target.customer_id LEFT JOIN public.orders o ON o.customer_id=target.customer_id AND o.status<>'CANCELLED' WHERE public.has_permission(auth.uid(),'claim.view') AND public.claim_customer_in_scope(target.customer_id) GROUP BY target.id;
$$;
GRANT EXECUTE ON FUNCTION public.claim_review_context() TO authenticated;
