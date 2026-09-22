-- AKAI CRM Phase 19 corrective migration.
-- 0043 and 0044 are applied and immutable.
-- Percentage rewards need an order total, so they are excluded from a fixed
-- per-point liability estimate rather than being assigned an invented PKR base.

CREATE OR REPLACE FUNCTION public.loyalty_liability_summary()
RETURNS TABLE(customers_with_points bigint,total_points bigint,value_per_point_pkr numeric(12,4),estimated_liability_pkr numeric(12,2)) LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
WITH value_rates AS (
  SELECT greatest(
    coalesce(max(discount_value_pkr / nullif(points_cost,0)) FILTER (WHERE reward_type='DISCOUNT_AMOUNT'),0),
    coalesce(max((p.price_pkr * r.free_product_quantity) / nullif(r.points_cost,0)) FILTER (WHERE reward_type='FREE_PRODUCT'),0)
  )::numeric(12,4) AS rate
  FROM public.rewards r LEFT JOIN public.products p ON p.id=r.free_product_id
  WHERE r.is_active AND (r.starts_at IS NULL OR r.starts_at<=now()) AND (r.ends_at IS NULL OR r.ends_at>=now())
), balances AS (
  SELECT count(*)::bigint customers_with_points,coalesce(sum(loyalty_points_balance),0)::bigint total_points
  FROM public.customers WHERE loyalty_points_balance>0 AND is_internal_account=false
)
SELECT b.customers_with_points,b.total_points,v.rate,(b.total_points*v.rate)::numeric(12,2)
FROM balances b CROSS JOIN value_rates v WHERE public.has_permission(auth.uid(),'dashboard.view');
$$;
GRANT EXECUTE ON FUNCTION public.loyalty_liability_summary() TO authenticated;
