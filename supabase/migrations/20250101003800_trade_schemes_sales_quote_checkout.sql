-- AKAI CRM Phase 17 Sales/quote checkout integration.
-- Existing historical workflow functions remain the source of price/stock snapshots;
-- these wrappers add scheme benefits inside the same transaction.

CREATE OR REPLACE FUNCTION public.create_sales_order_for_customer_with_schemes(
  p_customer_id uuid,
  p_lines jsonb,
  p_notes text DEFAULT NULL,
  p_payment_method text DEFAULT 'BALANCE'
)
RETURNS uuid
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public
AS $$
DECLARE
  order_id uuid;
  scheme_row record;
  applied_non_stackable boolean := false;
BEGIN
  IF NOT public.has_permission(auth.uid(), 'order.create') THEN RAISE EXCEPTION 'order.create permission is required'; END IF;
  order_id := public.create_sales_order_for_customer(p_customer_id, p_lines, p_notes, p_payment_method::"PaymentMethod");
  FOR scheme_row IN
    SELECT s.id, s.is_stackable, s.priority
    FROM public.schemes s
    WHERE s.is_active AND now() >= s.starts_at AND now() < s.ends_at
      AND (s.audience_type = 'ALL' OR EXISTS (SELECT 1 FROM public.scheme_audiences sa WHERE sa.scheme_id = s.id AND (sa.customer_id = p_customer_id OR sa.vendor_group_id = (SELECT vendor_group_id FROM public.customers WHERE id = p_customer_id))))
      AND (s.is_stackable OR NOT applied_non_stackable)
    ORDER BY s.is_stackable DESC, s.priority ASC, s.id
  LOOP
    IF public.apply_trade_scheme_to_order(scheme_row.id, order_id, p_customer_id) IS NOT NULL AND NOT scheme_row.is_stackable THEN applied_non_stackable := true; END IF;
  END LOOP;
  RETURN order_id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_sales_order_for_customer_with_schemes(uuid, jsonb, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_sales_order_for_customer_with_schemes(uuid, jsonb, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.accept_vendor_quote_with_schemes(p_quote_id uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public
AS $$
DECLARE
  order_id uuid;
  v_customer_id uuid;
  scheme_row record;
  applied_non_stackable boolean := false;
BEGIN
  IF NOT public.has_permission(auth.uid(), 'order.create') THEN RAISE EXCEPTION 'order.create permission is required'; END IF;
  order_id := public.accept_vendor_quote(p_quote_id);
  SELECT o.customer_id INTO v_customer_id FROM public.orders o WHERE o.id = order_id;
  IF v_customer_id IS NULL THEN RAISE EXCEPTION 'The accepted quote did not create a valid customer order'; END IF;
  FOR scheme_row IN
    SELECT s.id, s.is_stackable, s.priority
    FROM public.schemes s
    WHERE s.is_active AND now() >= s.starts_at AND now() < s.ends_at
      AND (s.audience_type = 'ALL' OR EXISTS (SELECT 1 FROM public.scheme_audiences sa WHERE sa.scheme_id = s.id AND (sa.customer_id = v_customer_id OR sa.vendor_group_id = (SELECT vendor_group_id FROM public.customers WHERE id = v_customer_id))))
      AND (s.is_stackable OR NOT applied_non_stackable)
    ORDER BY s.is_stackable DESC, s.priority ASC, s.id
  LOOP
    IF public.apply_trade_scheme_to_order(scheme_row.id, order_id, v_customer_id) IS NOT NULL AND NOT scheme_row.is_stackable THEN applied_non_stackable := true; END IF;
  END LOOP;
  RETURN order_id;
END;
$$;
REVOKE ALL ON FUNCTION public.accept_vendor_quote_with_schemes(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.accept_vendor_quote_with_schemes(uuid) TO authenticated;
