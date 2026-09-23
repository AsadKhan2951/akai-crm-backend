-- AKAI CRM Phase 17 Vendor checkout integration.
-- This wrapper is intentionally after the restored Vendor workflow migration in a clean chain.
-- It preserves the existing order creation function, then applies eligible schemes in the
-- same database transaction. Free items are zero-price OrderLines and never earn points.

CREATE OR REPLACE FUNCTION public.create_vendor_order_from_cart_with_schemes(
  p_cart_id uuid,
  p_notes text DEFAULT NULL,
  p_points_to_redeem integer DEFAULT 0,
  p_payment_method "PaymentMethod" DEFAULT 'BALANCE'
)
RETURNS uuid
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public
AS $$
DECLARE
  order_id uuid;
  v_customer_id uuid;
  scheme_row record;
  applied_non_stackable boolean := false;
BEGIN
  IF NOT public.has_permission(auth.uid(), 'order.create') THEN
    RAISE EXCEPTION 'order.create permission is required';
  END IF;
  SELECT c.customer_id INTO v_customer_id FROM public.carts c WHERE c.id = p_cart_id AND c.status = 'ACTIVE' FOR UPDATE;
  IF v_customer_id IS NULL THEN RAISE EXCEPTION 'The active cart could not be found'; END IF;

  -- Existing vendor workflow creates the order and snapshots all paid cart prices.
  order_id := public.create_vendor_order_from_cart(p_cart_id, p_notes, p_points_to_redeem, p_payment_method);

  -- Stackable schemes apply in deterministic priority order. For non-stackable schemes,
  -- the first eligible scheme wins; ineligible schemes do not block the next one.
  FOR scheme_row IN
    SELECT s.id, s.is_stackable, s.priority
    FROM public.schemes s
    WHERE s.is_active AND now() >= s.starts_at AND now() < s.ends_at
      AND (s.audience_type = 'ALL'
        OR EXISTS (SELECT 1 FROM public.scheme_audiences sa WHERE sa.scheme_id = s.id AND (sa.customer_id = v_customer_id OR sa.vendor_group_id = (SELECT vendor_group_id FROM public.customers WHERE id = v_customer_id))))
      AND (s.is_stackable OR NOT applied_non_stackable)
    ORDER BY s.is_stackable DESC, s.priority ASC, s.id
  LOOP
    IF scheme_row.is_stackable OR NOT applied_non_stackable THEN
      IF public.apply_trade_scheme_to_order(scheme_row.id, order_id, v_customer_id) IS NOT NULL AND NOT scheme_row.is_stackable THEN
        applied_non_stackable := true;
      END IF;
    END IF;
  END LOOP;
  RETURN order_id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_vendor_order_from_cart_with_schemes(uuid, text, integer, "PaymentMethod") FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_vendor_order_from_cart_with_schemes(uuid, text, integer, "PaymentMethod") TO authenticated;
