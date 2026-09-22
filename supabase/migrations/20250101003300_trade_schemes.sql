-- AKAI CRM Phase 17: Trade Schemes Engine.
-- Additive only. Scheme benefits are independent from loyalty points.
-- All money columns use numeric(12,2); all timestamps are UTC.

DO $$ BEGIN
  CREATE TYPE "SchemeType" AS ENUM ('QUANTITY_FREE', 'SLAB_DISCOUNT', 'BUNDLE', 'CATEGORY_TARGET', 'FLAT_DISCOUNT');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE "SchemeScopeType" AS ENUM ('PRODUCT', 'CATEGORY', 'BRAND', 'COLLECTION', 'ORDER_VALUE');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE "SchemeAudienceType" AS ENUM ('ALL', 'GROUP', 'SPECIFIC_VENDORS');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE "SchemeBenefitType" AS ENUM ('FREE_ITEM', 'DISCOUNT_PERCENT', 'DISCOUNT_AMOUNT');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS public.schemes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name_en text NOT NULL,
  name_ur text NOT NULL,
  description_en text,
  description_ur text,
  scheme_type "SchemeType" NOT NULL,
  scope_type "SchemeScopeType" NOT NULL,
  scope_ids text[] NOT NULL DEFAULT '{}',
  audience_type "SchemeAudienceType" NOT NULL,
  priority integer NOT NULL DEFAULT 100 CHECK (priority >= 0),
  is_stackable boolean NOT NULL DEFAULT false,
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  is_active boolean NOT NULL DEFAULT false,
  budget_pkr numeric(12,2),
  consumed_pkr numeric(12,2) NOT NULL DEFAULT 0 CHECK (consumed_pkr >= 0),
  max_redemptions_per_vendor integer CHECK (max_redemptions_per_vendor IS NULL OR max_redemptions_per_vendor > 0),
  terms_en text NOT NULL,
  terms_ur text NOT NULL,
  banner_image_url text,
  created_by_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT schemes_date_order CHECK (ends_at > starts_at),
  CONSTRAINT schemes_budget_order CHECK (budget_pkr IS NULL OR budget_pkr >= consumed_pkr)
);

CREATE INDEX IF NOT EXISTS schemes_active_schedule_priority_idx ON public.schemes (is_active, starts_at, ends_at, priority);
CREATE INDEX IF NOT EXISTS schemes_audience_active_schedule_idx ON public.schemes (audience_type, is_active, starts_at, ends_at);
CREATE INDEX IF NOT EXISTS schemes_creator_created_idx ON public.schemes (created_by_user_id, created_at);

CREATE TABLE IF NOT EXISTS public.scheme_tiers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scheme_id uuid NOT NULL REFERENCES public.schemes(id) ON DELETE CASCADE,
  min_quantity numeric(12,3),
  min_value_pkr numeric(12,2),
  free_product_id uuid REFERENCES public.products(id) ON DELETE RESTRICT,
  free_quantity numeric(12,3),
  discount_percent numeric(5,2),
  discount_amount_pkr numeric(12,2),
  display_order integer NOT NULL DEFAULT 0,
  CONSTRAINT scheme_tiers_threshold CHECK (min_quantity IS NOT NULL OR min_value_pkr IS NOT NULL),
  CONSTRAINT scheme_tiers_quantity_positive CHECK (min_quantity IS NULL OR min_quantity > 0),
  CONSTRAINT scheme_tiers_value_positive CHECK (min_value_pkr IS NULL OR min_value_pkr > 0),
  CONSTRAINT scheme_tiers_free_pair CHECK ((free_product_id IS NULL AND free_quantity IS NULL) OR (free_product_id IS NOT NULL AND free_quantity IS NOT NULL AND free_quantity > 0)),
  CONSTRAINT scheme_tiers_discount_pair CHECK ((discount_percent IS NULL AND discount_amount_pkr IS NULL) OR (discount_percent IS NOT NULL AND discount_amount_pkr IS NULL) OR (discount_percent IS NULL AND discount_amount_pkr IS NOT NULL)),
  CONSTRAINT scheme_tiers_percent_range CHECK (discount_percent IS NULL OR (discount_percent > 0 AND discount_percent <= 100)),
  CONSTRAINT scheme_tiers_amount_positive CHECK (discount_amount_pkr IS NULL OR discount_amount_pkr > 0)
);

CREATE INDEX IF NOT EXISTS scheme_tiers_scheme_order_idx ON public.scheme_tiers (scheme_id, display_order, min_quantity, min_value_pkr);
CREATE INDEX IF NOT EXISTS scheme_tiers_free_product_idx ON public.scheme_tiers (free_product_id);

CREATE TABLE IF NOT EXISTS public.scheme_audiences (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scheme_id uuid NOT NULL REFERENCES public.schemes(id) ON DELETE CASCADE,
  vendor_group_id uuid REFERENCES public.vendor_groups(id) ON DELETE CASCADE,
  customer_id uuid REFERENCES public.customers(id) ON DELETE CASCADE,
  CONSTRAINT scheme_audiences_one_target CHECK ((vendor_group_id IS NULL) <> (customer_id IS NULL))
);

CREATE INDEX IF NOT EXISTS scheme_audiences_scheme_idx ON public.scheme_audiences (scheme_id);
CREATE INDEX IF NOT EXISTS scheme_audiences_group_idx ON public.scheme_audiences (vendor_group_id);
CREATE INDEX IF NOT EXISTS scheme_audiences_customer_idx ON public.scheme_audiences (customer_id);

CREATE TABLE IF NOT EXISTS public.scheme_applications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scheme_id uuid NOT NULL REFERENCES public.schemes(id) ON DELETE RESTRICT,
  scheme_tier_id uuid NOT NULL REFERENCES public.scheme_tiers(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  customer_id uuid NOT NULL REFERENCES public.customers(id) ON DELETE RESTRICT,
  benefit_type "SchemeBenefitType" NOT NULL,
  benefit_value_pkr numeric(12,2) NOT NULL CHECK (benefit_value_pkr >= 0),
  free_product_id uuid REFERENCES public.products(id) ON DELETE RESTRICT,
  free_quantity numeric(12,3),
  applied_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (scheme_id, order_id),
  CONSTRAINT scheme_applications_free_pair CHECK ((free_product_id IS NULL AND free_quantity IS NULL) OR (free_product_id IS NOT NULL AND free_quantity IS NOT NULL AND free_quantity > 0))
);

CREATE INDEX IF NOT EXISTS scheme_applications_customer_applied_idx ON public.scheme_applications (customer_id, applied_at);
CREATE INDEX IF NOT EXISTS scheme_applications_order_idx ON public.scheme_applications (order_id);
CREATE INDEX IF NOT EXISTS scheme_applications_scheme_applied_idx ON public.scheme_applications (scheme_id, applied_at);

ALTER TABLE public.order_lines ADD COLUMN IF NOT EXISTS scheme_application_id uuid REFERENCES public.scheme_applications(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS order_lines_scheme_application_idx ON public.order_lines (scheme_application_id);

-- Keep scheme metadata current without relying on application timestamps.
CREATE OR REPLACE FUNCTION public.touch_scheme_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS schemes_touch_updated_at ON public.schemes;
CREATE TRIGGER schemes_touch_updated_at BEFORE UPDATE ON public.schemes
FOR EACH ROW EXECUTE FUNCTION public.touch_scheme_updated_at();

-- Activation is a sensitive operation. Direct authenticated writes cannot activate a scheme
-- unless the current database user has the explicit permission.
CREATE OR REPLACE FUNCTION public.guard_scheme_activation()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER AS $$
BEGIN
  IF NEW.is_active AND NOT public.has_permission(auth.uid(), 'scheme.activate') THEN
    RAISE EXCEPTION 'scheme.activate permission is required';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS schemes_guard_activation ON public.schemes;
CREATE TRIGGER schemes_guard_activation BEFORE INSERT OR UPDATE ON public.schemes
FOR EACH ROW EXECUTE FUNCTION public.guard_scheme_activation();

ALTER TABLE public.schemes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scheme_tiers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scheme_audiences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scheme_applications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS schemes_select_visible ON public.schemes;
CREATE POLICY schemes_select_visible ON public.schemes FOR SELECT TO authenticated
USING (
  public.has_permission(auth.uid(), 'scheme.view')
  AND (
    public.has_permission(auth.uid(), 'scheme.create')
    OR (
      is_active AND now() >= starts_at AND now() < ends_at
      AND (
        audience_type = 'ALL'
        OR EXISTS (
          SELECT 1
          FROM public.scheme_audiences sa
          JOIN public.customers c ON c.id = sa.customer_id
          JOIN public.customer_users cu ON cu.customer_id = c.id AND cu.user_id = auth.uid()
          WHERE sa.scheme_id = schemes.id
        )
        OR EXISTS (
          SELECT 1
          FROM public.scheme_audiences sa
          JOIN public.customers c ON c.vendor_group_id = sa.vendor_group_id
          JOIN public.customer_users cu ON cu.customer_id = c.id AND cu.user_id = auth.uid()
          WHERE sa.scheme_id = schemes.id
        )
      )
    )
  )
);

DROP POLICY IF EXISTS schemes_admin_insert ON public.schemes;
CREATE POLICY schemes_admin_insert ON public.schemes FOR INSERT TO authenticated
WITH CHECK (public.has_permission(auth.uid(), 'scheme.create') AND created_by_user_id = auth.uid());

DROP POLICY IF EXISTS schemes_admin_update ON public.schemes;
CREATE POLICY schemes_admin_update ON public.schemes FOR UPDATE TO authenticated
USING (public.has_permission(auth.uid(), 'scheme.create'))
WITH CHECK (public.has_permission(auth.uid(), 'scheme.create'));

DROP POLICY IF EXISTS schemes_admin_delete ON public.schemes;
CREATE POLICY schemes_admin_delete ON public.schemes FOR DELETE TO authenticated
USING (public.has_permission(auth.uid(), 'scheme.create') AND NOT EXISTS (SELECT 1 FROM public.scheme_applications sa WHERE sa.scheme_id = schemes.id));

DROP POLICY IF EXISTS scheme_tiers_select_visible ON public.scheme_tiers;
CREATE POLICY scheme_tiers_select_visible ON public.scheme_tiers FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.schemes s WHERE s.id = scheme_tiers.scheme_id));
DROP POLICY IF EXISTS scheme_tiers_admin_write ON public.scheme_tiers;
CREATE POLICY scheme_tiers_admin_write ON public.scheme_tiers FOR ALL TO authenticated
USING (public.has_permission(auth.uid(), 'scheme.create'))
WITH CHECK (public.has_permission(auth.uid(), 'scheme.create'));

DROP POLICY IF EXISTS scheme_audiences_select_visible ON public.scheme_audiences;
CREATE POLICY scheme_audiences_select_visible ON public.scheme_audiences FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.schemes s WHERE s.id = scheme_audiences.scheme_id));
DROP POLICY IF EXISTS scheme_audiences_admin_write ON public.scheme_audiences;
CREATE POLICY scheme_audiences_admin_write ON public.scheme_audiences FOR ALL TO authenticated
USING (public.has_permission(auth.uid(), 'scheme.create'))
WITH CHECK (public.has_permission(auth.uid(), 'scheme.create'));

DROP POLICY IF EXISTS scheme_applications_select_visible ON public.scheme_applications;
CREATE POLICY scheme_applications_select_visible ON public.scheme_applications FOR SELECT TO authenticated
USING (
  EXISTS (SELECT 1 FROM public.schemes s WHERE s.id = scheme_applications.scheme_id)
  AND (
    public.has_permission(auth.uid(), 'scheme.create')
    OR EXISTS (SELECT 1 FROM public.customer_users cu WHERE cu.customer_id = scheme_applications.customer_id AND cu.user_id = auth.uid())
    OR public.has_permission(auth.uid(), 'customer.view')
  )
);
DROP POLICY IF EXISTS scheme_applications_no_direct_insert ON public.scheme_applications;
CREATE POLICY scheme_applications_no_direct_insert ON public.scheme_applications FOR INSERT TO authenticated
WITH CHECK (current_setting('app.scheme_apply', true) = 'on' AND public.has_permission(auth.uid(), 'order.create'));
DROP POLICY IF EXISTS scheme_applications_no_direct_update ON public.scheme_applications;
CREATE POLICY scheme_applications_no_direct_update ON public.scheme_applications FOR UPDATE TO authenticated USING (false);
DROP POLICY IF EXISTS scheme_applications_no_direct_delete ON public.scheme_applications;
CREATE POLICY scheme_applications_no_direct_delete ON public.scheme_applications FOR DELETE TO authenticated USING (false);

-- Vendor-facing resolver: all reads are current-user/RLS scoped and include only live schemes.
CREATE OR REPLACE FUNCTION public.resolve_visible_schemes(p_customer_id uuid)
RETURNS TABLE (
  id uuid,
  name_en text,
  name_ur text,
  description_en text,
  description_ur text,
  scheme_type "SchemeType",
  scope_type "SchemeScopeType",
  scope_ids text[],
  priority integer,
  is_stackable boolean,
  starts_at timestamptz,
  ends_at timestamptz,
  budget_pkr numeric,
  consumed_pkr numeric,
  max_redemptions_per_vendor integer,
  terms_en text,
  terms_ur text,
  tiers jsonb
)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT s.id, s.name_en, s.name_ur, s.description_en, s.description_ur,
    s.scheme_type, s.scope_type, s.scope_ids, s.priority, s.is_stackable,
    s.starts_at, s.ends_at, s.budget_pkr, s.consumed_pkr,
    s.max_redemptions_per_vendor, s.terms_en, s.terms_ur,
    COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id', st.id, 'minQuantity', st.min_quantity, 'minValuePKR', st.min_value_pkr,
      'freeProductId', st.free_product_id, 'freeQuantity', st.free_quantity,
      'discountPercent', st.discount_percent, 'discountAmountPKR', st.discount_amount_pkr,
      'displayOrder', st.display_order
    ) ORDER BY st.display_order, st.id) FROM public.scheme_tiers st WHERE st.scheme_id = s.id), '[]'::jsonb) AS tiers
  FROM public.schemes s
  WHERE s.id IN (SELECT id FROM public.resolve_visible_schemes_base(p_customer_id));
$$;

-- Internal base resolver avoids duplicating the audience rule in the JSON projection function.
CREATE OR REPLACE FUNCTION public.resolve_visible_schemes_base(p_customer_id uuid)
RETURNS TABLE (id uuid)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT s.id
  FROM public.schemes s
  JOIN public.customers c ON c.id = p_customer_id
  WHERE public.has_permission(auth.uid(), 'scheme.view')
    AND now() >= s.starts_at AND now() < s.ends_at AND s.is_active
    AND (
      public.has_permission(auth.uid(), 'scheme.create')
      OR EXISTS (SELECT 1 FROM public.customer_users cu WHERE cu.customer_id = c.id AND cu.user_id = auth.uid())
    )
    AND (
      s.audience_type = 'ALL'
      OR EXISTS (SELECT 1 FROM public.scheme_audiences sa WHERE sa.scheme_id = s.id AND sa.customer_id = c.id)
      OR EXISTS (SELECT 1 FROM public.scheme_audiences sa WHERE sa.scheme_id = s.id AND sa.vendor_group_id = c.vendor_group_id)
    );
$$;
REVOKE ALL ON FUNCTION public.resolve_visible_schemes_base(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_visible_schemes_base(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_visible_schemes(uuid) TO authenticated;

-- Apply one eligible scheme atomically. It chooses the highest eligible tier,
-- enforces budget/cap rules, inserts the benefit audit row, and adds free stock
-- as an explicit zero-price OrderLine. It returns NULL when the scheme is not eligible.
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
  scope_match text;
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

  FOR tier_row IN
    SELECT * FROM public.scheme_tiers st
    WHERE st.scheme_id = p_scheme_id
      AND (st.min_quantity IS NULL OR matching_quantity >= st.min_quantity)
      AND (st.min_value_pkr IS NULL OR matching_value >= st.min_value_pkr)
    ORDER BY greatest(coalesce(st.min_quantity, 0), coalesce(st.min_value_pkr, 0)) DESC, st.display_order ASC, st.id
  LOOP
    EXIT;
  END LOOP;
  IF tier_row.id IS NULL THEN RETURN NULL; END IF;

  IF tier_row.free_product_id IS NOT NULL THEN
    SELECT price_pkr INTO free_price FROM public.products WHERE id = tier_row.free_product_id AND is_active FOR UPDATE;
    IF free_price IS NULL OR NOT EXISTS (SELECT 1 FROM public.resolve_visible_products(p_customer_id) vp WHERE vp.id = tier_row.free_product_id) THEN RETURN NULL; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.products WHERE id = tier_row.free_product_id AND stock_quantity >= tier_row.free_quantity FOR UPDATE) THEN RETURN NULL; END IF;
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

-- Loyalty calculations must ignore every free scheme line.
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
  SELECT coalesce(sum(ol.quantity) FILTER (WHERE NOT ol.is_free_item), 0),
    coalesce(sum(o.total_pkr), 0), coalesce(sum(sa.benefit_value_pkr), 0), count(DISTINCT sa.customer_id)
  FROM public.scheme_applications sa
  JOIN public.orders o ON o.id = sa.order_id
  LEFT JOIN public.order_lines ol ON ol.order_id = o.id
  WHERE sa.scheme_id = p_scheme_id AND public.has_permission(auth.uid(), 'scheme.analytics');
$$;
GRANT EXECUTE ON FUNCTION public.scheme_performance_summary(uuid) TO authenticated;
