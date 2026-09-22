-- AKAI CRM Phase 22: WhatsApp ordering assistant.
-- Additive only. Applied migrations are never edited.
-- The webhook worker is a system boundary. It may use the service role only here,
-- while all catalogue visibility and money calculations remain database-side.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'WhatsappSessionState') THEN
    CREATE TYPE "WhatsappSessionState" AS ENUM ('IDLE', 'BROWSING', 'BUILDING_CART', 'CONFIRMING', 'AWAITING_HUMAN');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.whatsapp_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone text NOT NULL UNIQUE,
  customer_id uuid REFERENCES public.customers(id) ON DELETE SET NULL,
  state "WhatsappSessionState" NOT NULL DEFAULT 'IDLE',
  cart_json jsonb,
  last_message_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  handed_off_to_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS whatsapp_sessions_customer_state_idx
  ON public.whatsapp_sessions(customer_id, state, last_message_at);
CREATE INDEX IF NOT EXISTS whatsapp_sessions_state_expiry_idx
  ON public.whatsapp_sessions(state, expires_at);

ALTER TABLE public.whatsapp_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS whatsapp_sessions_agent_read ON public.whatsapp_sessions;
CREATE POLICY whatsapp_sessions_agent_read ON public.whatsapp_sessions
  FOR SELECT TO authenticated
  USING (
    public.has_permission(auth.uid(), 'message.send')
    AND (
      public.has_permission(auth.uid(), 'whatsapp.manage_templates')
      OR EXISTS (
        SELECT 1
        FROM public.customers c
        WHERE c.id = whatsapp_sessions.customer_id
          AND c.assigned_agent_id IN (SELECT public.accessible_agent_ids(auth.uid()))
      )
    )
  );

DROP POLICY IF EXISTS whatsapp_sessions_admin_update ON public.whatsapp_sessions;
CREATE POLICY whatsapp_sessions_admin_update ON public.whatsapp_sessions
  FOR UPDATE TO authenticated
  USING (public.has_permission(auth.uid(), 'whatsapp.kill_switch'))
  WITH CHECK (public.has_permission(auth.uid(), 'whatsapp.kill_switch'));

-- The service worker uses the mandatory visible-product resolver. It is allowed to
-- resolve a verified WhatsApp customer's catalogue only as the system boundary.
CREATE OR REPLACE FUNCTION public.resolve_visible_products(p_customer_id uuid)
RETURNS TABLE (
  id uuid, sku text, name_en text, name_ur text, description_en text, description_ur text,
  category_id uuid, brand_id uuid, unit_of_measure text, pack_size numeric,
  price_pkr numeric, compare_at_price_pkr numeric, loyalty_points_per_unit integer,
  stock_quantity numeric, low_stock_threshold numeric, is_active boolean, is_quote_only boolean,
  created_at timestamptz, updated_at timestamptz
)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  WITH customer_context AS (
    SELECT c.id, c.vendor_group_id, vg.show_all_by_default
    FROM public.customers c
    LEFT JOIN public.vendor_groups vg ON vg.id = c.vendor_group_id
    WHERE c.id = p_customer_id
      AND (
        current_user = 'service_role'
        OR EXISTS (SELECT 1 FROM public.customer_users cu WHERE cu.customer_id = c.id AND cu.user_id = auth.uid())
      )
  )
  SELECT p.id, p.sku, p.name_en, p.name_ur, p.description_en, p.description_ur,
    p.category_id, p.brand_id, p.unit_of_measure, p.pack_size, p.price_pkr,
    p.compare_at_price_pkr, p.loyalty_points_per_unit, p.stock_quantity,
    p.low_stock_threshold, p.is_active, p.is_quote_only, p.created_at, p.updated_at
  FROM public.products p
  CROSS JOIN customer_context c
  WHERE (current_user = 'service_role' OR public.has_permission(auth.uid(), 'product.view'))
    AND p.is_active
    AND NOT EXISTS (
      SELECT 1 FROM public.catalog_visibility_rules r
      WHERE r.mode = 'DENY'
        AND ((r.scope_type = 'GROUP' AND r.scope_id = c.vendor_group_id)
          OR (r.scope_type = 'VENDOR' AND r.scope_id = c.id))
        AND ((r.entity_type = 'PRODUCT' AND r.entity_id = p.id)
          OR (r.entity_type = 'CATEGORY' AND r.entity_id = p.category_id)
          OR (r.entity_type = 'BRAND' AND r.entity_id = p.brand_id))
    )
    AND (
      coalesce(c.show_all_by_default, false)
      OR EXISTS (
        SELECT 1 FROM public.catalog_visibility_rules r
        WHERE r.mode = 'ALLOW'
          AND ((r.scope_type = 'GROUP' AND r.scope_id = c.vendor_group_id)
            OR (r.scope_type = 'VENDOR' AND r.scope_id = c.id))
          AND ((r.entity_type = 'PRODUCT' AND r.entity_id = p.id)
            OR (r.entity_type = 'CATEGORY' AND r.entity_id = p.category_id)
            OR (r.entity_type = 'BRAND' AND r.entity_id = p.brand_id))
      )
    );
$$;

CREATE OR REPLACE FUNCTION public.whatsapp_order_ceiling_pkr()
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT NULLIF(value_json->>'order_ceiling_pkr', '')::numeric FROM public.settings WHERE key = 'whatsapp.assistant'),
    100000::numeric
  );
$$;
REVOKE ALL ON FUNCTION public.whatsapp_order_ceiling_pkr() FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.whatsapp_order_ceiling_pkr() TO service_role';
  END IF;
END $$;

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
  WHERE c.id = p_customer_id
    AND c.is_internal_account = false
    AND c.status <> 'BLOCKED'
    AND c.whatsapp_phone = p_phone
  FOR UPDATE;
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
    SELECT * INTO visible_product
    FROM public.resolve_visible_products(p_customer_id) vp
    WHERE vp.id = line.product_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING errcode = '42501', message = 'One product is not visible to this customer.';
    END IF;
    IF visible_product.is_quote_only THEN
      RAISE EXCEPTION USING errcode = '22023', message = 'A quote-only product needs an agent quote.';
    END IF;
    IF visible_product.stock_quantity < line.quantity THEN
      RAISE EXCEPTION USING errcode = '22023', message = 'One product does not have enough available stock.';
    END IF;
    line_total := (visible_product.price_pkr * line.quantity)::numeric(12,2);
    subtotal := (subtotal + line_total)::numeric(12,2);
  END LOOP;
  ceiling := public.whatsapp_order_ceiling_pkr()::numeric(12,2);
  IF subtotal > ceiling THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'ORDER_CEILING_REQUIRES_AGENT';
  END IF;
  new_order_number := 'AK-' || to_char((now() AT TIME ZONE 'Asia/Karachi')::date, 'YYYYMMDD') || '-' || upper(substr(replace(new_order_id::text, '-', ''), 1, 6));
  INSERT INTO public.orders (
    id, order_number, customer_id, placed_by_user_id, placed_via, payment_method,
    status, approval_required, subtotal_pkr, discount_pkr, points_redeemed,
    points_discount_pkr, total_pkr, points_earned, notes, placed_at
  ) VALUES (
    new_order_id, new_order_number, p_customer_id, p_placed_by_user_id, 'WHATSAPP', 'BALANCE',
    'PLACED', false, subtotal, 0, 0, 0, subtotal, 0, nullif(trim(p_notes), ''), now()
  );
  FOR line IN SELECT * FROM jsonb_to_recordset(p_lines) AS r(product_id uuid, quantity numeric) LOOP
    SELECT * INTO visible_product FROM public.resolve_visible_products(p_customer_id) vp WHERE vp.id = line.product_id;
    INSERT INTO public.order_lines (order_id, product_id, quantity, unit_price_pkr, line_total_pkr)
    VALUES (new_order_id, line.product_id, line.quantity, visible_product.price_pkr, (visible_product.price_pkr * line.quantity)::numeric(12,2));
  END LOOP;
  RETURN QUERY SELECT new_order_id, new_order_number, subtotal;
END;
$$;
REVOKE ALL ON FUNCTION public.create_whatsapp_order(uuid, text, uuid, jsonb, text) FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.create_whatsapp_order(uuid, text, uuid, jsonb, text) TO service_role';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.create_whatsapp_quote(
  p_customer_id uuid,
  p_phone text,
  p_requested_by_user_id uuid,
  p_lines jsonb,
  p_notes text DEFAULT NULL
)
RETURNS TABLE(quote_id uuid, quote_number text)
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public
AS $$
DECLARE
  new_quote_id uuid := gen_random_uuid();
  new_quote_number text;
  line record;
  visible_product record;
  agent_id uuid;
BEGIN
  IF current_user <> 'service_role' THEN RAISE EXCEPTION USING errcode = '42501', message = 'WhatsApp system boundary is required.'; END IF;
  SELECT c.assigned_agent_id INTO agent_id FROM public.customers c WHERE c.id = p_customer_id AND c.whatsapp_phone = p_phone AND NOT c.is_internal_account AND c.status <> 'BLOCKED';
  IF agent_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.sales_agents sa WHERE sa.id = agent_id AND sa.user_id = p_requested_by_user_id) THEN
    RAISE EXCEPTION USING errcode = '42501', message = 'Verified WhatsApp customer scope is required.';
  END IF;
  IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) < 1 OR jsonb_array_length(p_lines) > 20 THEN RAISE EXCEPTION USING errcode = '22023', message = 'Add between one and twenty products.'; END IF;
  new_quote_number := 'AK-Q-' || to_char((now() AT TIME ZONE 'Asia/Karachi')::date, 'YYYYMMDD') || '-' || upper(substr(replace(new_quote_id::text, '-', ''), 1, 6));
  INSERT INTO public.quotes (id, quote_number, customer_id, requested_by_user_id, assigned_to_user_id, status, customer_notes, created_at)
  VALUES (new_quote_id, new_quote_number, p_customer_id, p_requested_by_user_id, p_requested_by_user_id, 'REQUESTED', nullif(trim(p_notes), ''), now());
  FOR line IN SELECT * FROM jsonb_to_recordset(p_lines) AS r(product_id uuid, quantity numeric) LOOP
    IF line.quantity IS NULL OR line.quantity <= 0 THEN RAISE EXCEPTION USING errcode = '22023', message = 'Every quantity must be greater than zero.'; END IF;
    SELECT * INTO visible_product FROM public.resolve_visible_products(p_customer_id) vp WHERE vp.id = line.product_id;
    IF NOT FOUND THEN RAISE EXCEPTION USING errcode = '42501', message = 'One product is not visible to this customer.'; END IF;
    INSERT INTO public.quote_lines (id, quote_id, product_id, quantity, requested_notes) VALUES (gen_random_uuid(), new_quote_id, line.product_id, line.quantity, null);
  END LOOP;
  RETURN QUERY SELECT new_quote_id, new_quote_number;
END;
$$;
REVOKE ALL ON FUNCTION public.create_whatsapp_quote(uuid, text, uuid, jsonb, text) FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.create_whatsapp_quote(uuid, text, uuid, jsonb, text) TO service_role';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.create_whatsapp_claim(
  p_customer_id uuid,
  p_phone text,
  p_raised_by_user_id uuid,
  p_order_id uuid,
  p_claim_type "ClaimType",
  p_description text,
  p_product_id uuid DEFAULT NULL,
  p_quantity numeric DEFAULT NULL
)
RETURNS TABLE(claim_id uuid, claim_number text)
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public
AS $$
DECLARE
  new_claim_id uuid := gen_random_uuid();
  new_claim_number text;
  agent_id uuid;
BEGIN
  IF current_user <> 'service_role' THEN RAISE EXCEPTION USING errcode = '42501', message = 'WhatsApp system boundary is required.'; END IF;
  SELECT c.assigned_agent_id INTO agent_id FROM public.customers c WHERE c.id = p_customer_id AND c.whatsapp_phone = p_phone AND NOT c.is_internal_account AND c.status <> 'BLOCKED';
  IF agent_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.sales_agents sa WHERE sa.id = agent_id AND sa.user_id = p_raised_by_user_id) THEN RAISE EXCEPTION USING errcode = '42501', message = 'Verified WhatsApp customer scope is required.'; END IF;
  IF p_order_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.orders o WHERE o.id = p_order_id AND o.customer_id = p_customer_id) THEN RAISE EXCEPTION USING errcode = '42501', message = 'The order is outside this customer scope.'; END IF;
  IF length(trim(coalesce(p_description, ''))) < 8 THEN RAISE EXCEPTION USING errcode = '22023', message = 'Please describe the issue in more detail.'; END IF;
  new_claim_number := 'AK-C-' || to_char((now() AT TIME ZONE 'Asia/Karachi')::date, 'YYYYMMDD') || '-' || upper(substr(replace(new_claim_id::text, '-', ''), 1, 6));
  INSERT INTO public.claims (id, claim_number, customer_id, order_id, raised_by_user_id, assigned_agent_id, claim_type, status, description, created_at)
  VALUES (new_claim_id, new_claim_number, p_customer_id, p_order_id, p_raised_by_user_id, agent_id, p_claim_type, 'SUBMITTED', trim(p_description), now());
  IF p_product_id IS NOT NULL THEN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN RAISE EXCEPTION USING errcode = '22023', message = 'Claim quantity must be greater than zero.'; END IF;
    INSERT INTO public.claim_lines (id, claim_id, product_id, quantity, reason_notes, created_at)
    VALUES (gen_random_uuid(), new_claim_id, p_product_id, p_quantity, null, now());
  END IF;
  RETURN QUERY SELECT new_claim_id, new_claim_number;
END;
$$;
REVOKE ALL ON FUNCTION public.create_whatsapp_claim(uuid, text, uuid, uuid, "ClaimType", text, uuid, numeric) FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.create_whatsapp_claim(uuid, text, uuid, uuid, "ClaimType", text, uuid, numeric) TO service_role';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.set_whatsapp_kill_switch(p_enabled boolean)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT public.has_permission(auth.uid(), 'whatsapp.kill_switch') THEN RAISE EXCEPTION USING errcode = '42501', message = 'WhatsApp kill switch permission is required.'; END IF;
  INSERT INTO public.settings (key, value_json, description, updated_by_user_id, updated_at)
  VALUES ('whatsapp.assistant', jsonb_build_object('enabled', p_enabled, 'order_ceiling_pkr', 100000), 'WhatsApp assistant runtime controls', auth.uid(), now())
  ON CONFLICT (key) DO UPDATE SET value_json = public.settings.value_json || jsonb_build_object('enabled', p_enabled), updated_by_user_id = auth.uid(), updated_at = now();
  RETURN p_enabled;
END;
$$;
REVOKE ALL ON FUNCTION public.set_whatsapp_kill_switch(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_whatsapp_kill_switch(boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.reset_whatsapp_session(p_phone text)
RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public
AS $$
BEGIN
  IF NOT public.has_permission(auth.uid(), 'whatsapp.kill_switch') THEN RAISE EXCEPTION USING errcode = '42501', message = 'WhatsApp kill switch permission is required.'; END IF;
  UPDATE public.whatsapp_sessions SET state = 'IDLE', cart_json = NULL, handed_off_to_user_id = NULL, last_message_at = now(), expires_at = now() + interval '30 minutes', updated_at = now() WHERE phone = p_phone;
  RETURN FOUND;
END;
$$;
REVOKE ALL ON FUNCTION public.reset_whatsapp_session(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reset_whatsapp_session(text) TO authenticated;

COMMENT ON TABLE public.whatsapp_sessions IS 'System-managed state for the verified-number WhatsApp ordering assistant. Cart values contain product IDs and quantities only; prices are always resolved in SQL at order time.';
