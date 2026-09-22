-- AKAI CRM Phase 17 migration-order dependency.
-- This is a new additive migration. It does not edit the applied 0032 migration.
-- 0033 replaces this harmless stub after creating the scheme tables.

CREATE OR REPLACE FUNCTION public.resolve_visible_schemes_base(p_customer_id uuid)
RETURNS TABLE (id uuid)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = public
AS $$
BEGIN
  RETURN QUERY SELECT NULL::uuid WHERE false;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_visible_schemes_base(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_visible_schemes_base(uuid) TO authenticated;
