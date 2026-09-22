-- AKAI CRM Phase 22 corrective migration.
-- Read-only settings RPC lets kill-switch operators see current state without granting
-- broad settings.manage access to the communications screen.
CREATE OR REPLACE FUNCTION public.get_whatsapp_assistant_settings()
RETURNS TABLE(enabled boolean, order_ceiling_pkr numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  setting_row jsonb;
BEGIN
  IF NOT public.has_permission(auth.uid(), 'whatsapp.kill_switch') THEN
    RAISE EXCEPTION USING errcode = '42501', message = 'WhatsApp kill switch permission is required.';
  END IF;
  SELECT value_json INTO setting_row FROM public.settings WHERE key = 'whatsapp.assistant';
  RETURN QUERY SELECT COALESCE((setting_row->>'enabled')::boolean, true), COALESCE((setting_row->>'order_ceiling_pkr')::numeric, 100000::numeric);
END;
$$;
REVOKE ALL ON FUNCTION public.get_whatsapp_assistant_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_whatsapp_assistant_settings() TO authenticated;
