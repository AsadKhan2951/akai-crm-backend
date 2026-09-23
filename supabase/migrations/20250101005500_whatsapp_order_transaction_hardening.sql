-- AKAI CRM Phase 22 corrective migration.
-- 0053 is immutable. This replacement preserves its verified-customer and visible
-- catalogue checks while decrementing stock and applying eligible Phase 17 schemes
-- in the same transaction.
CREATE OR REPLACE FUNCTION public.create_whatsapp_order(
  p_customer_id uuid,
  p_phone text,
  p_placed_by_user_id uuid,
  p_lines jsonb,
  p_notes text DEFAULT NULL
)
RETURNS TABLE(order_id uuid, order_number text, total_pkr numeric(12,2))
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public
AS $$
DECLARE
  new_order_id uuid := gen_random_uuid();
  new_order_number text;
  customer_row record;
  line record;
  visible_product record;
  scheme_row record;
  applied_non_stackable boolean := false;
  subtotal numeric(12,2) := 0;
  line_total numeric(12,2);
  ceiling numeric(12,2);
BEGIN
  IF current_user <> 'service_role' THEN
    RAISE EXCEPTION USING errcode = '42501', message = 'WhatsApp system boundary is required.';
  END IF;
  SELECT c.id, c.assigned_agent_id, sa.user_id AS agent_user_id
    INTO customer_row
  FROM public.customers c
  LEFT JOIN public.sales_agents sa ON sa.id = c.assigned_agent_id
  WHERE c.id = p_customer_id AND c.is_internal_account = false
    AND c.status <> 'BLOCKED' AND c.whatsapp_phone = p_phone
  FOR UPDATE OF c;
  IF NOT FOUND OR customer_row.assigned_agent_id IS NULL OR customer_row.agent_user_id <> p_placed_by_user_id THEN
    RAISE EXCEPTION USING errcode = '42501', message = 'Verified WhatsApp customer scope is required.';
  END IF;
  IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) < 1 OR jsonb_array_length(p_lines) > 20 THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'Add between one and twenty products.';
  END IF;
  FOR line IN SELECT * FROM jsonb_to_recordset(p_lines) AS r(product_id uuid, quantity numeric) LOOP
    IF line.quantity IS NULL OR line.quantity <= 0 OR line.quantity > 999999 THEN
      RAISE EXCEPTION USING errcode = '22023', message = 'Every quantity must be greater than zero.';
    END IF;
    SELECT * INTO visible_product FROM public.resolve_visible_products(p_customer_id) vp WHERE vp.id = line.product_id;
    IF NOT FOUND THEN RAISE EXCEPTION USING errcode = '42501', message = 'One product is not visible to this customer.'; END IF;
    IF visible_product.is_quote_only THEN RAISE EXCEPTION USING errcode = '22023', message = 'A quote-only product needs an agent quote.'; END IF;
    IF visible_product.stock_quantity < line.quantity THEN RAISE EXCEPTION USING errcode = '22023', message = 'One product does not have enough available stock.'; END IF;
    line_total := (visible_product.price_pkr * line.quantity)::numeric(12,2);
    subtotal := (subtotal + line_total)::numeric(12,2);
  END LOOP;
  ceiling := public.whatsapp_order_ceiling_pkr()::numeric(12,2);
  IF subtotal > ceiling THEN RAISE EXCEPTION USING errcode = '22023', message = 'ORDER_CEILING_REQUIRES_AGENT'; END IF;
  new_order_number := 'AK-' || to_char((now() AT TIME ZONE 'Asia/Karachi')::date, 'YYYYMMDD') || '-' || upper(substr(replace(new_order_id::text, '-', ''), 1, 6));
  INSERT INTO public.orders (id, order_number, customer_id, placed_by_user_id, placed_via, payment_method, status, approval_required, subtotal_pkr, discount_pkr, points_redeemed, points_discount_pkr, total_pkr, points_earned, notes, placed_at)
  VALUES (new_order_id, new_order_number, p_customer_id, p_placed_by_user_id, 'WHATSAPP', 'BALANCE', 'PLACED', false, subtotal, 0, 0, 0, subtotal, 0, nullif(trim(p_notes), ''), now());
  FOR line IN SELECT * FROM jsonb_to_recordset(p_lines) AS r(product_id uuid, quantity numeric) LOOP
    SELECT * INTO visible_product FROM public.resolve_visible_products(p_customer_id) vp WHERE vp.id = line.product_id;
    INSERT INTO public.order_lines (order_id, product_id, quantity, unit_price_pkr, line_total_pkr)
    VALUES (new_order_id, line.product_id, line.quantity, visible_product.price_pkr, (visible_product.price_pkr * line.quantity)::numeric(12,2));
    UPDATE public.products SET stock_quantity = stock_quantity - line.quantity WHERE id = line.product_id;
  END LOOP;
  FOR scheme_row IN
    SELECT s.id, s.is_stackable, s.priority
    FROM public.schemes s
    WHERE s.is_active AND now() >= s.starts_at AND now() < s.ends_at
      AND (s.audience_type = 'ALL' OR EXISTS (
        SELECT 1 FROM public.scheme_audiences sa
        WHERE sa.scheme_id = s.id
          AND (sa.customer_id = p_customer_id OR sa.vendor_group_id = (SELECT vendor_group_id FROM public.customers WHERE id = p_customer_id))
      ))
      AND (s.is_stackable OR NOT applied_non_stackable)
    ORDER BY s.is_stackable DESC, s.priority ASC, s.id
  LOOP
    IF public.apply_trade_scheme_to_order(scheme_row.id, new_order_id, p_customer_id) IS NOT NULL AND NOT scheme_row.is_stackable THEN
      applied_non_stackable := true;
    END IF;
  END LOOP;
  RETURN QUERY SELECT o.id, o.order_number, o.total_pkr FROM public.orders o WHERE o.id = new_order_id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_whatsapp_order(uuid, text, uuid, jsonb, text) FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.create_whatsapp_order(uuid, text, uuid, jsonb, text) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.apply_trade_scheme_to_order(uuid, uuid, uuid) TO service_role';
  END IF;
END $$;
