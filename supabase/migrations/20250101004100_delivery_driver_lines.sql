-- AKAI CRM Phase 18 driver line details. Additive only.
CREATE OR REPLACE FUNCTION public.get_delivery_stop_lines_by_token(p_token_hash text, p_stop_id uuid)
RETURNS TABLE(order_line_id uuid,product_id uuid,sku text,name_en text,name_ur text,quantity_ordered numeric(12,3))
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT ol.id,ol.product_id,p.sku,p.name_en,p.name_ur,ol.quantity
  FROM public.delivery_stops s JOIN public.delivery_runs r ON r.id=s.run_id JOIN public.delivery_run_tokens t ON t.run_id=r.id JOIN public.order_lines ol ON ol.order_id=s.order_id JOIN public.products p ON p.id=ol.product_id
  WHERE t.token_hash=p_token_hash AND t.revoked_at IS NULL AND t.valid_on=(now() AT TIME ZONE 'Asia/Karachi')::date AND t.expires_at>now() AND s.id=p_stop_id
  ORDER BY p.sku;
$$;
REVOKE ALL ON FUNCTION public.get_delivery_stop_lines_by_token(text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_delivery_stop_lines_by_token(text,uuid) TO anon, authenticated;
