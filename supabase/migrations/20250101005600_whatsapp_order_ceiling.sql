-- AKAI CRM Phase 22 corrective migration.
-- The order ceiling is stored as PostgreSQL numeric and changed only by the
-- permission-protected Admin settings function.
CREATE OR REPLACE FUNCTION public.set_whatsapp_order_ceiling(p_ceiling numeric)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  current_value jsonb;
BEGIN
  IF NOT public.has_permission(auth.uid(), 'whatsapp.kill_switch') THEN
    RAISE EXCEPTION USING errcode = '42501', message = 'WhatsApp kill switch permission is required.';
  END IF;
  IF p_ceiling IS NULL OR p_ceiling <= 0 OR p_ceiling > 999999999999.99 THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'WhatsApp order ceiling must be a positive PKR amount.';
  END IF;
  SELECT value_json INTO current_value FROM public.settings WHERE key = 'whatsapp.assistant';
  INSERT INTO public.settings(key, value_json, updated_at)
  VALUES ('whatsapp.assistant', jsonb_build_object('enabled', COALESCE((current_value->>'enabled')::boolean, true), 'order_ceiling_pkr', p_ceiling::text), now())
  ON CONFLICT (key) DO UPDATE SET value_json = public.settings.value_json || jsonb_build_object('order_ceiling_pkr', p_ceiling::text), updated_at = now();
  RETURN p_ceiling;
END;
$$;
REVOKE ALL ON FUNCTION public.set_whatsapp_order_ceiling(numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_whatsapp_order_ceiling(numeric) TO authenticated;
