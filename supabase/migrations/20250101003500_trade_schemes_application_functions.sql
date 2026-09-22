-- AKAI CRM Phase 17 corrective migration.
-- 0033's table/policy portion applied before its later function dependency failed.
-- This migration installs the transactional application and reporting functions.

CREATE OR REPLACE FUNCTION public.apply_trade_scheme_to_order(p_scheme_id uuid, p_order_id uuid, p_customer_id uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public
AS $$
DECLARE
  scheme_row public.schemes%ROWTYPE;
  order_row public.orders%ROWTYPE;
  tier_row public.scheme_tiers%ROWTYPE;
  matching_quantity numeric := 0;
  matching_value numeric := 0;
  benefit numeric(12,2) := 0;
  free_price numeric(12,2);
  application_id uuid;
  prior_count integer;
BEGIN
  IF NOT public.has_permission(auth.uid(), 'order.create') THEN
    RAISE EXCEPTION 'order.create permission is required';
  END IF;
  SELECT * INTO order_row FROM public.orders WHERE id = p_order_id AND customer_id = p_customer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order does not belong to the selected customer'; END IF;
  SELECT * INTO scheme_row FROM public.schemes WHERE id = p_scheme_id FOR UPDATE;
  IF NOT FOUND OR NOT scheme_row.is_active OR now() < scheme_row.starts_at OR now() >= scheme_row.ends_at THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM public.scheme_applications WHERE scheme_id = p_scheme_id AND order_id = p_order_id) THEN RETURN NULL; END IF;
  IF scheme_row.audience_type <> 'ALL' AND NOT EXISTS (
    SELECT 1 FROM public.scheme_audiences sa
    JOIN public.customers c ON c.id = p_customer_id
    WHERE sa.scheme_id = p_scheme_id AND (sa.customer_id = p_customer_id OR sa.vendor_group_id = c.vendor_group_id)
  ) THEN RETURN NULL; END IF;
  IF scheme_row.max_redemptions_per_vendor IS NOT NULL THEN
    SELECT count(*) INTO prior_count FROM public.scheme_applications WHERE scheme_id = p_scheme_id AND customer_id = p_customer_id;
    IF prior_count >= scheme_row.max_redemptions_per_vendor THEN RETURN NULL; END IF;
  END IF;

  SELECT coalesce(sum(ol.quantity), 0), coalesce(sum(ol.line_total_pkr), 0)
    INTO matching_quantity, matching_value
  FROM public.order_lines ol
  JOIN public.products p ON p.id = ol.product_id
  WHERE ol.order_id = p_order_id AND NOT ol.is_free_item
    AND (
      scheme_row.scope_type = 'ORDER_VALUE'
      OR (scheme_row.scope_type = 'PRODUCT' AND p.id::text = ANY(scheme_row.scope_ids))
      OR (scheme_row.scope_type = 'CATEGORY' AND p.category_id::text = ANY(scheme_row.scope_ids))
      OR (scheme_row.scope_type = 'BRAND' AND p.brand_id::text = ANY(scheme_row.scope_ids))
      OR (scheme_row.scope_type = 'COLLECTION' AND EXISTS (SELECT 1 FROM public.product_collections pc WHERE pc.product_id = p.id AND pc.collection_id::text = ANY(scheme_row.scope_ids)))
    );

  SELECT st.* INTO tier_row
  FROM public.scheme_tiers st
  WHERE st.scheme_id = p_scheme_id
    AND (st.min_quantity IS NULL OR matching_quantity >= st.min_quantity)
    AND (st.min_value_pkr IS NULL OR matching_value >= st.min_value_pkr)
  ORDER BY greatest(coalesce(st.min_quantity, 0), coalesce(st.min_value_pkr, 0)) DESC, st.display_order ASC, st.id
  LIMIT 1;
  IF tier_row.id IS NULL THEN RETURN NULL; END IF;

  IF tier_row.free_product_id IS NOT NULL THEN
    SELECT price_pkr INTO free_price FROM public.products WHERE id = tier_row.free_product_id AND is_active FOR UPDATE;
    IF free_price IS NULL OR NOT EXISTS (SELECT 1 FROM public.resolve_visible_products(p_customer_id) vp WHERE vp.id = tier_row.free_product_id) THEN RETURN NULL; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.products WHERE id = tier_row.free_product_id AND stock_quantity >= tier_row.free_quantity) THEN RETURN NULL; END IF;
    benefit := (free_price * tier_row.free_quantity)::numeric(12,2);
  ELSIF tier_row.discount_percent IS NOT NULL THEN
    benefit := least(matching_value, (matching_value * tier_row.discount_percent / 100)::numeric(12,2));
  ELSIF tier_row.discount_amount_pkr IS NOT NULL THEN
    benefit := least(matching_value, tier_row.discount_amount_pkr)::numeric(12,2);
  ELSE
    RETURN NULL;
  END IF;

  IF scheme_row.budget_pkr IS NOT NULL AND scheme_row.consumed_pkr + benefit > scheme_row.budget_pkr THEN RETURN NULL; END IF;
  PERFORM set_config('app.scheme_apply', 'on', true);
  INSERT INTO public.scheme_applications (scheme_id, scheme_tier_id, order_id, customer_id, benefit_type, benefit_value_pkr, free_product_id, free_quantity)
  VALUES (
    p_scheme_id, tier_row.id, p_order_id, p_customer_id,
    CASE WHEN tier_row.free_product_id IS NOT NULL THEN 'FREE_ITEM'::"SchemeBenefitType"
         WHEN tier_row.discount_percent IS NOT NULL THEN 'DISCOUNT_PERCENT'::"SchemeBenefitType"
         ELSE 'DISCOUNT_AMOUNT'::"SchemeBenefitType" END,
    benefit, tier_row.free_product_id, tier_row.free_quantity
  ) RETURNING id INTO application_id;
  PERFORM set_config('app.scheme_apply', 'off', true);

  UPDATE public.schemes SET consumed_pkr = consumed_pkr + benefit,
    is_active = CASE WHEN budget_pkr IS NOT NULL AND consumed_pkr + benefit >= budget_pkr THEN false ELSE is_active END
  WHERE id = p_scheme_id;

  IF tier_row.free_product_id IS NOT NULL THEN
    UPDATE public.products SET stock_quantity = stock_quantity - tier_row.free_quantity WHERE id = tier_row.free_product_id;
    INSERT INTO public.order_lines (order_id, product_id, quantity, unit_price_pkr, line_total_pkr, is_free_item, scheme_application_id)
    VALUES (p_order_id, tier_row.free_product_id, tier_row.free_quantity, 0, 0, true, application_id);
  ELSE
    UPDATE public.orders SET discount_pkr = discount_pkr + benefit, total_pkr = greatest(total_pkr - benefit, 0) WHERE id = p_order_id;
  END IF;
  RETURN application_id;
END;
$$;
REVOKE ALL ON FUNCTION public.apply_trade_scheme_to_order(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_trade_scheme_to_order(uuid, uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.calculate_order_loyalty_points(p_order_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT coalesce(sum(floor(ol.quantity * p.loyalty_points_per_unit))::integer, 0)
  FROM public.order_lines ol
  JOIN public.products p ON p.id = ol.product_id
  WHERE ol.order_id = p_order_id AND NOT ol.is_free_item;
$$;
GRANT EXECUTE ON FUNCTION public.calculate_order_loyalty_points(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.scheme_performance_summary(p_scheme_id uuid)
RETURNS TABLE (units_moved numeric, revenue_pkr numeric, benefit_cost_pkr numeric, participating_dealers bigint)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  WITH apps AS (
    SELECT sa.id, sa.customer_id, sa.order_id, sa.benefit_value_pkr
    FROM public.scheme_applications sa
    WHERE sa.scheme_id = p_scheme_id
      AND public.has_permission(auth.uid(), 'scheme.analytics')
  ), order_totals AS (
    SELECT a.order_id, max(o.total_pkr) AS total_pkr
    FROM apps a JOIN public.orders o ON o.id = a.order_id
    GROUP BY a.order_id
  ), line_totals AS (
    SELECT a.order_id, coalesce(sum(ol.quantity) FILTER (WHERE NOT ol.is_free_item), 0) AS units
    FROM apps a LEFT JOIN public.order_lines ol ON ol.order_id = a.order_id
    GROUP BY a.order_id
  )
  SELECT coalesce(sum(lt.units), 0), coalesce(sum(ot.total_pkr), 0), coalesce(sum(a.benefit_value_pkr), 0), count(DISTINCT a.customer_id)
  FROM apps a
  JOIN order_totals ot ON ot.order_id = a.order_id
  JOIN line_totals lt ON lt.order_id = a.order_id;
$$;
GRANT EXECUTE ON FUNCTION public.scheme_performance_summary(uuid) TO authenticated;
