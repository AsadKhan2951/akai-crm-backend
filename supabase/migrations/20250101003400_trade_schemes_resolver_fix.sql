-- AKAI CRM Phase 17 corrective migration.
-- 0033 created the scheme tables/policies before the helper dependency.
-- This new migration creates the helper first and then the public resolver.

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
  WHERE s.id IN (SELECT base.id FROM public.resolve_visible_schemes_base(p_customer_id) base);
$$;

REVOKE ALL ON FUNCTION public.resolve_visible_schemes_base(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_visible_schemes_base(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.resolve_visible_schemes(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_visible_schemes(uuid) TO authenticated;
