-- AKAI CRM Phase 18 corrective migration.
-- Picking completion is the only transition into PICKED for delivery preparation.

CREATE OR REPLACE FUNCTION public.mark_picking_line(p_picking_list_line_id uuid, p_quantity_picked numeric, p_quantity_short numeric DEFAULT 0, p_short_reason text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE required_quantity numeric(12,3); list_id uuid; list_complete boolean;
BEGIN
  IF NOT public.has_permission(auth.uid(),'delivery.create_run') THEN RAISE EXCEPTION 'Updating a picking list is not permitted.'; END IF;
  SELECT quantity_required,picking_list_id INTO required_quantity,list_id FROM public.picking_list_lines WHERE id=p_picking_list_line_id FOR UPDATE;
  IF NOT FOUND OR p_quantity_picked < 0 OR p_quantity_short < 0 OR p_quantity_picked+p_quantity_short > required_quantity THEN RAISE EXCEPTION 'Picked and short quantities exceed the required quantity.'; END IF;
  IF p_quantity_short > 0 AND nullif(trim(p_short_reason),'') IS NULL THEN RAISE EXCEPTION 'A shortage reason is required.'; END IF;
  UPDATE public.picking_list_lines SET quantity_picked=p_quantity_picked,quantity_short=p_quantity_short,short_reason=nullif(trim(p_short_reason),'') WHERE id=p_picking_list_line_id;
  SELECT NOT EXISTS (SELECT 1 FROM public.picking_list_lines l WHERE l.picking_list_id=list_id AND l.quantity_picked+l.quantity_short<l.quantity_required) INTO list_complete;
  UPDATE public.picking_lists SET status=CASE WHEN list_complete THEN 'COMPLETED' ELSE 'OPEN' END,completed_at=CASE WHEN list_complete THEN now() ELSE NULL END WHERE id=list_id;
  IF list_complete THEN
    UPDATE public.orders o SET status='PICKED'
    WHERE o.id IN (SELECT DISTINCT ol.order_id FROM public.picking_list_order_lines pol JOIN public.order_lines ol ON ol.id=pol.order_line_id JOIN public.picking_list_lines pl ON pl.id=pol.picking_list_line_id WHERE pl.picking_list_id=list_id)
      AND o.status='CONFIRMED';
  END IF;
  RETURN p_picking_list_line_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.mark_picking_line(uuid,numeric,numeric,text) TO authenticated;

DROP FUNCTION IF EXISTS public.create_delivery_run(date,uuid,text,text,uuid[],jsonb,text);
CREATE OR REPLACE FUNCTION public.create_delivery_run(p_run_date date, p_driver_user_id uuid, p_driver_name text, p_vehicle_number text, p_order_ids uuid[], p_cod_amounts jsonb DEFAULT '{}'::jsonb, p_notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE run_id uuid := gen_random_uuid(); run_number text; next_sequence integer := 0; order_row record; stop_id uuid; expected_cod numeric(12,2) := 0; cod_amount numeric(12,2);
BEGIN
  IF NOT public.has_permission(auth.uid(),'delivery.create_run') THEN RAISE EXCEPTION 'Creating a delivery run is not permitted.'; END IF;
  IF p_run_date IS NULL OR nullif(trim(p_driver_name),'') IS NULL OR nullif(trim(p_vehicle_number),'') IS NULL OR p_order_ids IS NULL OR cardinality(p_order_ids)=0 THEN RAISE EXCEPTION 'Date, driver, vehicle, and at least one order are required.'; END IF;
  IF EXISTS (SELECT 1 FROM public.orders o WHERE o.id=ANY(p_order_ids) AND o.status <> 'PICKED') THEN RAISE EXCEPTION 'Only picked orders can be added to a delivery run.'; END IF;
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
  UPDATE public.orders SET status='DISPATCHED' WHERE id=ANY(p_order_ids);
  INSERT INTO public.audit_logs(user_id,action,entity_type,entity_id,changes_json) VALUES(auth.uid(),'CREATE_DELIVERY_RUN','DELIVERY_RUN',run_id::text,jsonb_build_object('run_number',run_number,'order_ids',p_order_ids,'cod_amounts',p_cod_amounts));
  RETURN run_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.create_delivery_run(date,uuid,text,text,uuid[],jsonb,text) TO authenticated;
