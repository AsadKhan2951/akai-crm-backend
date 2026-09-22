-- AKAI CRM Phase 18 corrective migration.
-- 0039 is already applied and is not edited. COD is explicit input because
-- PaymentMethod BALANCE/CREDIT is not a COD indicator.

DROP FUNCTION IF EXISTS public.create_delivery_run(date,uuid,text,text,uuid[],text);
CREATE OR REPLACE FUNCTION public.create_delivery_run(p_run_date date, p_driver_user_id uuid, p_driver_name text, p_vehicle_number text, p_order_ids uuid[], p_cod_amounts jsonb DEFAULT '{}'::jsonb, p_notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE run_id uuid := gen_random_uuid(); run_number text; next_sequence integer := 0; order_row record; stop_id uuid; expected_cod numeric(12,2) := 0; cod_amount numeric(12,2);
BEGIN
  IF NOT public.has_permission(auth.uid(),'delivery.create_run') THEN RAISE EXCEPTION 'Creating a delivery run is not permitted.'; END IF;
  IF p_run_date IS NULL OR nullif(trim(p_driver_name),'') IS NULL OR nullif(trim(p_vehicle_number),'') IS NULL OR p_order_ids IS NULL OR cardinality(p_order_ids)=0 THEN RAISE EXCEPTION 'Date, driver, vehicle, and at least one order are required.'; END IF;
  IF EXISTS (SELECT 1 FROM public.orders o WHERE o.id=ANY(p_order_ids) AND o.status NOT IN ('CONFIRMED','PICKED')) THEN RAISE EXCEPTION 'Only confirmed or picked orders can be added to a delivery run.'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_each_text(coalesce(p_cod_amounts,'{}'::jsonb)) x WHERE x.key::uuid <> ALL(p_order_ids)) THEN RAISE EXCEPTION 'COD amounts may only be supplied for selected orders.'; END IF;
  run_number := public.delivery_next_number(p_run_date);
  SELECT coalesce(sum(coalesce((p_cod_amounts ->> o.id::text)::numeric,0)),0)::numeric(12,2) INTO expected_cod FROM public.orders o WHERE o.id=ANY(p_order_ids);
  INSERT INTO public.delivery_runs(id,run_number,driver_user_id,driver_name,vehicle_number,run_date,total_stops,expected_cod_amount_pkr,created_by_user_id,notes) VALUES(run_id,run_number,p_driver_user_id,trim(p_driver_name),upper(trim(p_vehicle_number)),p_run_date,cardinality(p_order_ids),expected_cod,auth.uid(),nullif(trim(p_notes),''));
  FOR order_row IN SELECT o.id,o.customer_id,o.total_pkr,c.latitude,c.longitude,c.business_name FROM public.orders o JOIN public.customers c ON c.id=o.customer_id WHERE o.id=ANY(p_order_ids) ORDER BY c.latitude NULLS LAST,c.longitude NULLS LAST,c.business_name LOOP
    next_sequence := next_sequence + 1;
    cod_amount := nullif((p_cod_amounts ->> order_row.id::text),'')::numeric(12,2);
    INSERT INTO public.delivery_stops(run_id,order_id,customer_id,sequence,cod_amount_pkr) VALUES(run_id,order_row.id,order_row.customer_id,next_sequence,cod_amount) RETURNING id INTO stop_id;
    INSERT INTO public.delivery_stop_lines(stop_id,order_line_id,quantity_delivered,quantity_short) SELECT stop_id,ol.id,0,0 FROM public.order_lines ol WHERE ol.order_id=order_row.id;
  END LOOP;
  UPDATE public.orders SET status='DISPATCHED' WHERE id=ANY(p_order_ids) AND status IN ('CONFIRMED','PICKED');
  INSERT INTO public.audit_logs(user_id,action,entity_type,entity_id,changes_json) VALUES(auth.uid(),'CREATE_DELIVERY_RUN','DELIVERY_RUN',run_id::text,jsonb_build_object('run_number',run_number,'order_ids',p_order_ids,'cod_amounts',p_cod_amounts));
  RETURN run_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.create_delivery_run(date,uuid,text,text,uuid[],jsonb,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_delivery_stops_by_token(p_token_hash text)
RETURNS TABLE(stop_id uuid,sequence integer,customer_id uuid,business_name text,full_address text,primary_phone text,order_id uuid,order_number text,order_total_pkr numeric(12,2),status text,cod_amount_pkr numeric(12,2),cod_collected boolean,received_by_name text,delivered_at timestamptz,latitude numeric,longitude numeric,failure_reason text,notes text)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT s.id,s.sequence,c.id,c.business_name,c.full_address,c.primary_phone,o.id,o.order_number,o.total_pkr,s.status::text,s.cod_amount_pkr,s.cod_collected,s.received_by_name,s.delivered_at,s.latitude,s.longitude,s.failure_reason,s.notes
  FROM public.delivery_stops s JOIN public.delivery_runs r ON r.id=s.run_id JOIN public.delivery_run_tokens t ON t.run_id=r.id JOIN public.customers c ON c.id=s.customer_id JOIN public.orders o ON o.id=s.order_id
  WHERE t.token_hash=p_token_hash AND t.revoked_at IS NULL AND t.valid_on=(now() AT TIME ZONE 'Asia/Karachi')::date AND t.expires_at>now() AND r.status <> 'CANCELLED'
  ORDER BY s.sequence;
$$;
REVOKE ALL ON FUNCTION public.get_delivery_stops_by_token(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_delivery_stops_by_token(text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.record_delivery_cod_collection(p_stop_id uuid, p_token_hash text, p_amount_pkr numeric)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE stop_row record; collection_id uuid; month_key date; next_number integer; receipt text;
BEGIN
  SELECT s.*,o.order_number INTO stop_row
  FROM public.delivery_stops s JOIN public.delivery_runs r ON r.id=s.run_id JOIN public.delivery_run_tokens t ON t.run_id=r.id JOIN public.orders o ON o.id=s.order_id
  WHERE s.id=p_stop_id AND t.token_hash=p_token_hash AND t.revoked_at IS NULL AND t.valid_on=(now() AT TIME ZONE 'Asia/Karachi')::date AND t.expires_at>now() FOR UPDATE;
  IF NOT FOUND OR p_amount_pkr <= 0 OR stop_row.cod_amount_pkr IS NULL OR p_amount_pkr <> stop_row.cod_amount_pkr THEN RAISE EXCEPTION 'COD amount must match the delivery stop.'; END IF;
  IF stop_row.cod_collected THEN SELECT pc.id INTO collection_id FROM public.payment_collections pc WHERE pc.customer_id=stop_row.customer_id AND pc.notes like '%delivery stop '||p_stop_id::text||'%' LIMIT 1; RETURN collection_id; END IF;
  month_key := (now() AT TIME ZONE 'Asia/Karachi')::date - ((extract(day FROM (now() AT TIME ZONE 'Asia/Karachi'))::integer - 1) * interval '1 day');
  INSERT INTO public.collection_receipt_counters(month,last_number) VALUES(month_key,1) ON CONFLICT(month) DO UPDATE SET last_number=public.collection_receipt_counters.last_number+1 RETURNING last_number INTO next_number;
  receipt := 'AKAI-R-' || to_char(month_key,'YYYYMM') || '-' || lpad(next_number::text,4,'0');
  INSERT INTO public.payment_collections(id,customer_id,agent_id,amount_pkr,method,receipt_number,against_invoice_numbers,status,notes,created_by_user_id) VALUES(gen_random_uuid(),stop_row.customer_id,(SELECT assigned_agent_id FROM public.customers WHERE id=stop_row.customer_id),p_amount_pkr,'CASH',receipt,ARRAY[stop_row.order_number],'COLLECTED','COD for delivery stop '||p_stop_id::text,NULL) RETURNING id INTO collection_id;
  UPDATE public.delivery_stops SET cod_collected=true WHERE id=p_stop_id;
  UPDATE public.delivery_runs r SET collected_cod_amount_pkr=(SELECT coalesce(sum(s.cod_amount_pkr) FILTER (WHERE s.cod_collected),0) FROM public.delivery_stops s WHERE s.run_id=r.id) WHERE r.id=stop_row.run_id;
  INSERT INTO public.audit_logs(user_id,action,entity_type,entity_id,changes_json) VALUES(NULL,'RECORD_DELIVERY_COD','DELIVERY_STOP',p_stop_id::text,jsonb_build_object('amount_pkr',p_amount_pkr,'receipt_number',receipt));
  RETURN collection_id;
END; $$;
REVOKE ALL ON FUNCTION public.record_delivery_cod_collection(uuid,text,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_delivery_cod_collection(uuid,text,numeric) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.mark_picking_line(p_picking_list_line_id uuid, p_quantity_picked numeric, p_quantity_short numeric DEFAULT 0, p_short_reason text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE required_quantity numeric(12,3);
BEGIN
  IF NOT public.has_permission(auth.uid(),'delivery.create_run') THEN RAISE EXCEPTION 'Updating a picking list is not permitted.'; END IF;
  SELECT quantity_required INTO required_quantity FROM public.picking_list_lines WHERE id=p_picking_list_line_id FOR UPDATE;
  IF NOT FOUND OR p_quantity_picked < 0 OR p_quantity_short < 0 OR p_quantity_picked+p_quantity_short > required_quantity THEN RAISE EXCEPTION 'Picked and short quantities exceed the required quantity.'; END IF;
  IF p_quantity_short > 0 AND nullif(trim(p_short_reason),'') IS NULL THEN RAISE EXCEPTION 'A shortage reason is required.'; END IF;
  UPDATE public.picking_list_lines SET quantity_picked=p_quantity_picked,quantity_short=p_quantity_short,short_reason=nullif(trim(p_short_reason),'') WHERE id=p_picking_list_line_id;
  UPDATE public.picking_lists p SET status=CASE WHEN NOT EXISTS (SELECT 1 FROM public.picking_list_lines l WHERE l.picking_list_id=p.id AND l.quantity_picked+l.quantity_short<l.quantity_required) THEN 'COMPLETED' ELSE 'OPEN' END,completed_at=CASE WHEN NOT EXISTS (SELECT 1 FROM public.picking_list_lines l WHERE l.picking_list_id=p.id AND l.quantity_picked+l.quantity_short<l.quantity_required) THEN now() ELSE NULL END WHERE p.id=(SELECT picking_list_id FROM public.picking_list_lines WHERE id=p_picking_list_line_id);
  RETURN p_picking_list_line_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.mark_picking_line(uuid,numeric,numeric,text) TO authenticated;
