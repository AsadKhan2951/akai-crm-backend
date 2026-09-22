-- AKAI CRM Phase 18: delivery, dispatch, and proof of delivery.
-- Additive only. Applied migrations are never edited.
-- All timestamps are UTC timestamptz; runDate is a Karachi business date.

DO $$ BEGIN
  CREATE TYPE public."DeliveryRunStatus" AS ENUM ('PLANNED','LOADED','IN_TRANSIT','COMPLETED','CANCELLED');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE public."DeliveryStopStatus" AS ENUM ('PENDING','DELIVERED','PARTIAL','FAILED','RESCHEDULED');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE public."PickingListStatus" AS ENUM ('OPEN','COMPLETED','CANCELLED');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS public.picking_lists (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pick_number text NOT NULL UNIQUE,
  status public."PickingListStatus" NOT NULL DEFAULT 'OPEN',
  created_by_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  completed_at timestamptz(6),
  notes text,
  created_at timestamptz(6) NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS picking_lists_status_created_at_idx ON public.picking_lists(status, created_at DESC);
CREATE INDEX IF NOT EXISTS picking_lists_creator_created_at_idx ON public.picking_lists(created_by_user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.picking_list_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  picking_list_id uuid NOT NULL REFERENCES public.picking_lists(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  quantity_required numeric(12,3) NOT NULL,
  quantity_picked numeric(12,3) NOT NULL DEFAULT 0,
  quantity_short numeric(12,3) NOT NULL DEFAULT 0,
  short_reason text,
  created_at timestamptz(6) NOT NULL DEFAULT now(),
  CONSTRAINT picking_list_lines_quantity_check CHECK (quantity_required > 0 AND quantity_picked >= 0 AND quantity_short >= 0 AND quantity_picked + quantity_short <= quantity_required)
);
CREATE UNIQUE INDEX IF NOT EXISTS picking_list_lines_product_unique_idx ON public.picking_list_lines(picking_list_id, product_id);
CREATE INDEX IF NOT EXISTS picking_list_lines_product_idx ON public.picking_list_lines(product_id);

CREATE TABLE IF NOT EXISTS public.picking_list_order_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  picking_list_line_id uuid NOT NULL REFERENCES public.picking_list_lines(id) ON DELETE CASCADE,
  order_line_id uuid NOT NULL REFERENCES public.order_lines(id) ON DELETE RESTRICT,
  quantity_required numeric(12,3) NOT NULL,
  quantity_short numeric(12,3) NOT NULL DEFAULT 0,
  short_reason text,
  created_at timestamptz(6) NOT NULL DEFAULT now(),
  CONSTRAINT picking_list_order_lines_quantity_check CHECK (quantity_required > 0 AND quantity_short >= 0 AND quantity_short <= quantity_required)
);
CREATE UNIQUE INDEX IF NOT EXISTS picking_list_order_lines_unique_idx ON public.picking_list_order_lines(picking_list_line_id, order_line_id);
CREATE INDEX IF NOT EXISTS picking_list_order_lines_order_line_idx ON public.picking_list_order_lines(order_line_id);

CREATE TABLE IF NOT EXISTS public.delivery_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_number text NOT NULL UNIQUE,
  driver_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  driver_name text NOT NULL,
  vehicle_number text NOT NULL,
  run_date date NOT NULL,
  status public."DeliveryRunStatus" NOT NULL DEFAULT 'PLANNED',
  total_stops integer NOT NULL DEFAULT 0,
  completed_stops integer NOT NULL DEFAULT 0,
  expected_cod_amount_pkr numeric(12,2) NOT NULL DEFAULT 0,
  collected_cod_amount_pkr numeric(12,2) NOT NULL DEFAULT 0,
  started_at timestamptz(6),
  completed_at timestamptz(6),
  notes text,
  created_by_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  created_at timestamptz(6) NOT NULL DEFAULT now(),
  CONSTRAINT delivery_runs_stop_counts_check CHECK (total_stops >= 0 AND completed_stops >= 0 AND completed_stops <= total_stops),
  CONSTRAINT delivery_runs_cod_check CHECK (expected_cod_amount_pkr >= 0 AND collected_cod_amount_pkr >= 0 AND collected_cod_amount_pkr <= expected_cod_amount_pkr)
);
CREATE INDEX IF NOT EXISTS delivery_runs_date_status_idx ON public.delivery_runs(run_date, status);
CREATE INDEX IF NOT EXISTS delivery_runs_driver_date_idx ON public.delivery_runs(driver_user_id, run_date);
CREATE INDEX IF NOT EXISTS delivery_runs_created_by_idx ON public.delivery_runs(created_by_user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.delivery_stops (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id uuid NOT NULL REFERENCES public.delivery_runs(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  customer_id uuid NOT NULL REFERENCES public.customers(id) ON DELETE RESTRICT,
  sequence integer NOT NULL,
  status public."DeliveryStopStatus" NOT NULL DEFAULT 'PENDING',
  delivered_at timestamptz(6),
  received_by_name text,
  signature_url text,
  photo_url text,
  latitude numeric(9,6),
  longitude numeric(9,6),
  cod_amount_pkr numeric(12,2),
  cod_collected boolean NOT NULL DEFAULT false,
  failure_reason text,
  notes text,
  created_at timestamptz(6) NOT NULL DEFAULT now(),
  CONSTRAINT delivery_stops_sequence_check CHECK (sequence > 0),
  CONSTRAINT delivery_stops_cod_check CHECK (cod_amount_pkr IS NULL OR cod_amount_pkr >= 0),
  CONSTRAINT delivery_stops_cod_collected_check CHECK (cod_collected = false OR (cod_amount_pkr IS NOT NULL AND cod_amount_pkr > 0))
);
CREATE UNIQUE INDEX IF NOT EXISTS delivery_stops_run_sequence_idx ON public.delivery_stops(run_id, sequence);
CREATE UNIQUE INDEX IF NOT EXISTS delivery_stops_run_order_unique_idx ON public.delivery_stops(run_id, order_id);
CREATE INDEX IF NOT EXISTS delivery_stops_order_status_idx ON public.delivery_stops(order_id, status);
CREATE INDEX IF NOT EXISTS delivery_stops_customer_status_idx ON public.delivery_stops(customer_id, status);
CREATE INDEX IF NOT EXISTS delivery_stops_run_status_sequence_idx ON public.delivery_stops(run_id, status, sequence);

CREATE TABLE IF NOT EXISTS public.delivery_stop_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  stop_id uuid NOT NULL REFERENCES public.delivery_stops(id) ON DELETE CASCADE,
  order_line_id uuid NOT NULL REFERENCES public.order_lines(id) ON DELETE RESTRICT,
  quantity_delivered numeric(12,3) NOT NULL DEFAULT 0,
  quantity_short numeric(12,3) NOT NULL DEFAULT 0,
  short_reason text,
  created_at timestamptz(6) NOT NULL DEFAULT now(),
  CONSTRAINT delivery_stop_lines_quantity_check CHECK (quantity_delivered >= 0 AND quantity_short >= 0 AND quantity_delivered + quantity_short > 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS delivery_stop_lines_unique_idx ON public.delivery_stop_lines(stop_id, order_line_id);
CREATE INDEX IF NOT EXISTS delivery_stop_lines_order_line_idx ON public.delivery_stop_lines(order_line_id);

CREATE TABLE IF NOT EXISTS public.delivery_run_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id uuid NOT NULL REFERENCES public.delivery_runs(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  valid_on date NOT NULL,
  expires_at timestamptz(6) NOT NULL,
  last_used_at timestamptz(6),
  revoked_at timestamptz(6),
  created_at timestamptz(6) NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS delivery_run_tokens_run_valid_idx ON public.delivery_run_tokens(run_id, valid_on, revoked_at, expires_at);

-- The tokenized driver may be a non-user. Keep the existing collection model useful
-- by allowing a token-authenticated collection to carry no user creator.
ALTER TABLE public.payment_collections ALTER COLUMN created_by_user_id DROP NOT NULL;

ALTER TABLE public.picking_lists ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.picking_list_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.picking_list_order_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_stops ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_stop_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_run_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS picking_lists_select_delivery ON public.picking_lists;
CREATE POLICY picking_lists_select_delivery ON public.picking_lists FOR SELECT TO authenticated
USING (public.has_permission(auth.uid(),'delivery.view') OR public.has_permission(auth.uid(),'delivery.create_run'));
DROP POLICY IF EXISTS picking_lists_manage_delivery ON public.picking_lists;
CREATE POLICY picking_lists_manage_delivery ON public.picking_lists FOR ALL TO authenticated
USING (public.has_permission(auth.uid(),'delivery.create_run'))
WITH CHECK (public.has_permission(auth.uid(),'delivery.create_run') AND created_by_user_id = auth.uid());
DROP POLICY IF EXISTS picking_list_lines_select_delivery ON public.picking_list_lines;
CREATE POLICY picking_list_lines_select_delivery ON public.picking_list_lines FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.picking_lists p WHERE p.id = picking_list_id));
DROP POLICY IF EXISTS picking_list_lines_manage_delivery ON public.picking_list_lines;
CREATE POLICY picking_list_lines_manage_delivery ON public.picking_list_lines FOR ALL TO authenticated
USING (public.has_permission(auth.uid(),'delivery.create_run'))
WITH CHECK (public.has_permission(auth.uid(),'delivery.create_run'));
DROP POLICY IF EXISTS picking_list_order_lines_select_delivery ON public.picking_list_order_lines;
CREATE POLICY picking_list_order_lines_select_delivery ON public.picking_list_order_lines FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.picking_list_lines pl WHERE pl.id = picking_list_line_id));
DROP POLICY IF EXISTS picking_list_order_lines_manage_delivery ON public.picking_list_order_lines;
CREATE POLICY picking_list_order_lines_manage_delivery ON public.picking_list_order_lines FOR ALL TO authenticated
USING (public.has_permission(auth.uid(),'delivery.create_run'))
WITH CHECK (public.has_permission(auth.uid(),'delivery.create_run'));

DROP POLICY IF EXISTS delivery_runs_select_delivery ON public.delivery_runs;
CREATE POLICY delivery_runs_select_delivery ON public.delivery_runs FOR SELECT TO authenticated
USING (public.has_permission(auth.uid(),'delivery.view') OR public.has_permission(auth.uid(),'delivery.create_run') OR driver_user_id = auth.uid());
DROP POLICY IF EXISTS delivery_runs_manage_delivery ON public.delivery_runs;
CREATE POLICY delivery_runs_manage_delivery ON public.delivery_runs FOR ALL TO authenticated
USING (public.has_permission(auth.uid(),'delivery.create_run'))
WITH CHECK (public.has_permission(auth.uid(),'delivery.create_run'));
DROP POLICY IF EXISTS delivery_stops_select_delivery ON public.delivery_stops;
CREATE POLICY delivery_stops_select_delivery ON public.delivery_stops FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.delivery_runs r WHERE r.id = run_id AND (public.has_permission(auth.uid(),'delivery.view') OR public.has_permission(auth.uid(),'delivery.create_run') OR r.driver_user_id = auth.uid())));
DROP POLICY IF EXISTS delivery_stops_manage_delivery ON public.delivery_stops;
CREATE POLICY delivery_stops_manage_delivery ON public.delivery_stops FOR ALL TO authenticated
USING (public.has_permission(auth.uid(),'delivery.create_run') OR public.has_permission(auth.uid(),'delivery.mark_delivered'))
WITH CHECK (public.has_permission(auth.uid(),'delivery.create_run') OR public.has_permission(auth.uid(),'delivery.mark_delivered'));
DROP POLICY IF EXISTS delivery_stop_lines_select_delivery ON public.delivery_stop_lines;
CREATE POLICY delivery_stop_lines_select_delivery ON public.delivery_stop_lines FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.delivery_stops s JOIN public.delivery_runs r ON r.id = s.run_id WHERE s.id = stop_id AND (public.has_permission(auth.uid(),'delivery.view') OR public.has_permission(auth.uid(),'delivery.create_run') OR r.driver_user_id = auth.uid())));
DROP POLICY IF EXISTS delivery_stop_lines_manage_delivery ON public.delivery_stop_lines;
CREATE POLICY delivery_stop_lines_manage_delivery ON public.delivery_stop_lines FOR ALL TO authenticated
USING (public.has_permission(auth.uid(),'delivery.create_run') OR public.has_permission(auth.uid(),'delivery.mark_delivered'))
WITH CHECK (public.has_permission(auth.uid(),'delivery.create_run') OR public.has_permission(auth.uid(),'delivery.mark_delivered'));
DROP POLICY IF EXISTS delivery_run_tokens_select_delivery ON public.delivery_run_tokens;
CREATE POLICY delivery_run_tokens_select_delivery ON public.delivery_run_tokens FOR SELECT TO authenticated
USING (public.has_permission(auth.uid(),'delivery.create_run') OR EXISTS (SELECT 1 FROM public.delivery_runs r WHERE r.id = run_id AND r.driver_user_id = auth.uid()));
DROP POLICY IF EXISTS delivery_run_tokens_manage_delivery ON public.delivery_run_tokens;
CREATE POLICY delivery_run_tokens_manage_delivery ON public.delivery_run_tokens FOR ALL TO authenticated
USING (public.has_permission(auth.uid(),'delivery.create_run'))
WITH CHECK (public.has_permission(auth.uid(),'delivery.create_run'));

CREATE OR REPLACE FUNCTION public.delivery_next_number(p_run_date date)
RETURNS text LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT 'AKAI-D-' || to_char(p_run_date, 'YYYYMMDD') || '-' || lpad((count(*) + 1)::text, 3, '0')
  FROM public.delivery_runs WHERE run_date = p_run_date;
$$;

CREATE OR REPLACE FUNCTION public.picking_next_number()
RETURNS text LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT 'AKAI-P-' || to_char((now() AT TIME ZONE 'Asia/Karachi')::date, 'YYYYMM') || '-' || lpad((count(*) + 1)::text, 4, '0')
  FROM public.picking_lists WHERE created_at >= date_trunc('month', now() AT TIME ZONE 'Asia/Karachi') AT TIME ZONE 'Asia/Karachi';
$$;

CREATE OR REPLACE FUNCTION public.create_picking_list(p_order_ids uuid[], p_notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE
  list_id uuid := gen_random_uuid();
  list_number text;
  item record;
  line_id uuid;
BEGIN
  IF NOT public.has_permission(auth.uid(),'delivery.create_run') THEN RAISE EXCEPTION 'Creating a picking list is not permitted.'; END IF;
  IF p_order_ids IS NULL OR cardinality(p_order_ids) = 0 THEN RAISE EXCEPTION 'Select at least one confirmed order.'; END IF;
  IF EXISTS (SELECT 1 FROM public.orders o WHERE o.id = ANY(p_order_ids) AND o.status <> 'CONFIRMED') THEN RAISE EXCEPTION 'Only confirmed orders can be picked.'; END IF;
  list_number := public.picking_next_number();
  INSERT INTO public.picking_lists(id,pick_number,created_by_user_id,notes) VALUES(list_id,list_number,auth.uid(),nullif(trim(p_notes),''));
  FOR item IN SELECT ol.product_id, sum(ol.quantity)::numeric(12,3) quantity_required FROM public.order_lines ol JOIN public.orders o ON o.id=ol.order_id WHERE ol.order_id=ANY(p_order_ids) GROUP BY ol.product_id LOOP
    INSERT INTO public.picking_list_lines(picking_list_id,product_id,quantity_required) VALUES(list_id,item.product_id,item.quantity_required) RETURNING id INTO line_id;
    INSERT INTO public.picking_list_order_lines(picking_list_line_id,order_line_id,quantity_required)
      SELECT line_id,ol.id,ol.quantity FROM public.order_lines ol WHERE ol.order_id=ANY(p_order_ids) AND ol.product_id=item.product_id;
  END LOOP;
  INSERT INTO public.audit_logs(user_id,action,entity_type,entity_id,changes_json) VALUES(auth.uid(),'CREATE_PICKING_LIST','PICKING_LIST',list_id::text,jsonb_build_object('pick_number',list_number,'order_ids',p_order_ids));
  RETURN list_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.create_picking_list(uuid[],text) TO authenticated;

CREATE OR REPLACE FUNCTION public.flag_picking_shortage(p_order_line_id uuid, p_quantity_short numeric, p_reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE allocation record; order_id uuid; customer_id uuid;
BEGIN
  IF NOT public.has_permission(auth.uid(),'delivery.create_run') THEN RAISE EXCEPTION 'Flagging a picking shortage is not permitted.'; END IF;
  IF p_quantity_short <= 0 OR nullif(trim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'Enter a positive shortage quantity and reason.'; END IF;
  SELECT plol.*, pl.product_id, pl.picking_list_id INTO allocation FROM public.picking_list_order_lines plol JOIN public.picking_list_lines pl ON pl.id=plol.picking_list_line_id WHERE plol.order_line_id=p_order_line_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'This order line is not in an open picking list.'; END IF;
  IF p_quantity_short > allocation.quantity_required THEN RAISE EXCEPTION 'Shortage cannot exceed the ordered quantity.'; END IF;
  UPDATE public.picking_list_order_lines SET quantity_short=p_quantity_short,short_reason=trim(p_reason) WHERE id=allocation.id;
  UPDATE public.picking_list_lines SET quantity_short=(SELECT coalesce(sum(quantity_short),0) FROM public.picking_list_order_lines WHERE picking_list_line_id=allocation.picking_list_line_id), short_reason=trim(p_reason) WHERE id=allocation.picking_list_line_id;
  SELECT ol.order_id,o.customer_id INTO order_id,customer_id FROM public.order_lines ol JOIN public.orders o ON o.id=ol.order_id WHERE ol.id=p_order_line_id;
  INSERT INTO public.notifications(user_id,type,title_en,title_ur,body,link_url)
    SELECT sa.user_id,'PICKING_SHORTAGE','Picking shortage','Picking shortage','A shortage was flagged for order '||o.order_number,'/en/sales/orders/new'
    FROM public.orders o JOIN public.customers c ON c.id=o.customer_id JOIN public.sales_agents sa ON sa.id=c.assigned_agent_id WHERE o.id=order_id;
  INSERT INTO public.audit_logs(user_id,action,entity_type,entity_id,changes_json) VALUES(auth.uid(),'FLAG_PICKING_SHORTAGE','ORDER_LINE',p_order_line_id::text,jsonb_build_object('quantity_short',p_quantity_short,'reason',trim(p_reason)));
  RETURN p_order_line_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.flag_picking_shortage(uuid,numeric,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.create_delivery_run(p_run_date date, p_driver_user_id uuid, p_driver_name text, p_vehicle_number text, p_order_ids uuid[], p_notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE run_id uuid := gen_random_uuid(); run_number text; next_sequence integer := 0; order_row record; stop_id uuid; expected_cod numeric(12,2) := 0;
BEGIN
  IF NOT public.has_permission(auth.uid(),'delivery.create_run') THEN RAISE EXCEPTION 'Creating a delivery run is not permitted.'; END IF;
  IF p_run_date IS NULL OR nullif(trim(p_driver_name),'') IS NULL OR nullif(trim(p_vehicle_number),'') IS NULL OR p_order_ids IS NULL OR cardinality(p_order_ids)=0 THEN RAISE EXCEPTION 'Date, driver, vehicle, and at least one confirmed order are required.'; END IF;
  IF EXISTS (SELECT 1 FROM public.orders o WHERE o.id=ANY(p_order_ids) AND o.status NOT IN ('CONFIRMED','PICKED')) THEN RAISE EXCEPTION 'Only confirmed or picked orders can be added to a delivery run.'; END IF;
  run_number := public.delivery_next_number(p_run_date);
  INSERT INTO public.delivery_runs(id,run_number,driver_user_id,driver_name,vehicle_number,run_date,total_stops,expected_cod_amount_pkr,created_by_user_id,notes) SELECT run_id,run_number,p_driver_user_id,trim(p_driver_name),upper(trim(p_vehicle_number)),p_run_date,cardinality(p_order_ids),coalesce(sum(CASE WHEN o.payment_method='CREDIT' THEN 0 ELSE o.total_pkr END),0),auth.uid(),nullif(trim(p_notes),'') FROM public.orders o WHERE o.id=ANY(p_order_ids);
  FOR order_row IN SELECT o.id,o.customer_id,o.total_pkr,o.payment_method,c.latitude,c.longitude FROM public.orders o JOIN public.customers c ON c.id=o.customer_id WHERE o.id=ANY(p_order_ids) ORDER BY c.latitude NULLS LAST,c.longitude NULLS LAST,c.business_name LOOP
    next_sequence := next_sequence + 1;
    INSERT INTO public.delivery_stops(run_id,order_id,customer_id,sequence,cod_amount_pkr) VALUES(run_id,order_row.id,order_row.customer_id,next_sequence,CASE WHEN order_row.payment_method='CREDIT' THEN NULL ELSE order_row.total_pkr END) RETURNING id INTO stop_id;
    INSERT INTO public.delivery_stop_lines(stop_id,order_line_id,quantity_delivered,quantity_short) SELECT stop_id,ol.id,0,0 FROM public.order_lines ol WHERE ol.order_id=order_row.id;
  END LOOP;
  UPDATE public.orders SET status='DISPATCHED' WHERE id=ANY(p_order_ids) AND status IN ('CONFIRMED','PICKED');
  INSERT INTO public.audit_logs(user_id,action,entity_type,entity_id,changes_json) VALUES(auth.uid(),'CREATE_DELIVERY_RUN','DELIVERY_RUN',run_id::text,jsonb_build_object('run_number',run_number,'order_ids',p_order_ids));
  RETURN run_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.create_delivery_run(date,uuid,text,text,uuid[],text) TO authenticated;

CREATE OR REPLACE FUNCTION public.issue_delivery_run_token(p_run_id uuid, p_token_hash text, p_expires_at timestamptz)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE token_id uuid := gen_random_uuid();
BEGIN
  IF NOT public.has_permission(auth.uid(),'delivery.create_run') THEN RAISE EXCEPTION 'Issuing a driver link is not permitted.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.delivery_runs WHERE id=p_run_id AND run_date=(now() AT TIME ZONE 'Asia/Karachi')::date AND status <> 'CANCELLED') THEN RAISE EXCEPTION 'This delivery run is not valid for a driver link.'; END IF;
  INSERT INTO public.delivery_run_tokens(id,run_id,token_hash,valid_on,expires_at) VALUES(token_id,p_run_id,p_token_hash,(now() AT TIME ZONE 'Asia/Karachi')::date,p_expires_at);
  RETURN token_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.issue_delivery_run_token(uuid,text,timestamptz) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_delivery_run_by_token(p_token_hash text)
RETURNS TABLE(run_id uuid,run_number text,driver_name text,vehicle_number text,run_date date,status text,total_stops integer,completed_stops integer,expected_cod_amount_pkr numeric(12,2),collected_cod_amount_pkr numeric(12,2)) LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT r.id,r.run_number,r.driver_name,r.vehicle_number,r.run_date,r.status::text,r.total_stops,r.completed_stops,r.expected_cod_amount_pkr,r.collected_cod_amount_pkr
  FROM public.delivery_runs r JOIN public.delivery_run_tokens t ON t.run_id=r.id
  WHERE t.token_hash=p_token_hash AND t.revoked_at IS NULL AND t.valid_on=(now() AT TIME ZONE 'Asia/Karachi')::date AND t.expires_at>now() AND r.status <> 'CANCELLED';
$$;
REVOKE ALL ON FUNCTION public.get_delivery_run_by_token(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_delivery_run_by_token(text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.record_delivery_cod_collection(p_stop_id uuid, p_token_hash text, p_amount_pkr numeric)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE stop_row record; token_ok boolean; collection_id uuid; month_key date; next_number integer; receipt text; agent_id uuid;
BEGIN
  SELECT EXISTS (SELECT 1 FROM public.delivery_run_tokens t WHERE t.token_hash=p_token_hash AND t.revoked_at IS NULL AND t.valid_on=(now() AT TIME ZONE 'Asia/Karachi')::date AND t.expires_at>now()) INTO token_ok;
  IF NOT token_ok THEN RAISE EXCEPTION 'This driver link is expired or invalid.'; END IF;
  SELECT s.*,o.order_number,c.assigned_agent_id INTO stop_row FROM public.delivery_stops s JOIN public.orders o ON o.id=s.order_id JOIN public.customers c ON c.id=s.customer_id WHERE s.id=p_stop_id FOR UPDATE;
  IF NOT FOUND OR p_amount_pkr <= 0 OR stop_row.cod_amount_pkr IS NULL OR p_amount_pkr <> stop_row.cod_amount_pkr THEN RAISE EXCEPTION 'COD amount must match the delivery stop.'; END IF;
  IF stop_row.cod_collected THEN SELECT pc.id INTO collection_id FROM public.payment_collections pc WHERE pc.customer_id=stop_row.customer_id AND pc.notes like '%delivery stop '||p_stop_id::text||'%' LIMIT 1; RETURN collection_id; END IF;
  month_key := (now() AT TIME ZONE 'Asia/Karachi')::date - ((extract(day FROM (now() AT TIME ZONE 'Asia/Karachi'))::integer - 1) * interval '1 day');
  INSERT INTO public.collection_receipt_counters(month,last_number) VALUES(month_key,1) ON CONFLICT(month) DO UPDATE SET last_number=public.collection_receipt_counters.last_number+1 RETURNING last_number INTO next_number;
  receipt := 'AKAI-R-' || to_char(month_key,'YYYYMM') || '-' || lpad(next_number::text,4,'0');
  INSERT INTO public.payment_collections(id,customer_id,agent_id,amount_pkr,method,receipt_number,against_invoice_numbers,status,notes,created_by_user_id) VALUES(gen_random_uuid(),stop_row.customer_id,stop_row.assigned_agent_id,p_amount_pkr,'CASH',receipt,ARRAY[stop_row.order_number],'COLLECTED','COD for delivery stop '||p_stop_id::text,NULL) RETURNING id INTO collection_id;
  UPDATE public.delivery_stops SET cod_collected=true WHERE id=p_stop_id;
  UPDATE public.delivery_runs r SET collected_cod_amount_pkr=(SELECT coalesce(sum(s.cod_amount_pkr) FILTER (WHERE s.cod_collected),0) FROM public.delivery_stops s WHERE s.run_id=r.id) WHERE r.id=stop_row.run_id;
  INSERT INTO public.audit_logs(user_id,action,entity_type,entity_id,changes_json) VALUES(NULL,'RECORD_DELIVERY_COD','DELIVERY_STOP',p_stop_id::text,jsonb_build_object('amount_pkr',p_amount_pkr,'receipt_number',receipt));
  RETURN collection_id;
END; $$;
REVOKE ALL ON FUNCTION public.record_delivery_cod_collection(uuid,text,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_delivery_cod_collection(uuid,text,numeric) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.complete_delivery_stop_by_token(p_stop_id uuid,p_token_hash text,p_status public."DeliveryStopStatus",p_received_by_name text DEFAULT NULL,p_signature_url text DEFAULT NULL,p_photo_url text DEFAULT NULL,p_latitude numeric DEFAULT NULL,p_longitude numeric DEFAULT NULL,p_cod_collected boolean DEFAULT false,p_failure_reason text DEFAULT NULL,p_notes text DEFAULT NULL,p_lines jsonb DEFAULT '[]'::jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE stop_row record; token_ok boolean; line_row record; cod_collection uuid; completed_count integer;
BEGIN
  SELECT EXISTS (SELECT 1 FROM public.delivery_run_tokens t JOIN public.delivery_stops s ON s.run_id=t.run_id WHERE t.token_hash=p_token_hash AND t.revoked_at IS NULL AND t.valid_on=(now() AT TIME ZONE 'Asia/Karachi')::date AND t.expires_at>now() AND s.id=p_stop_id) INTO token_ok;
  IF NOT token_ok THEN RAISE EXCEPTION 'This driver link is expired or invalid.'; END IF;
  IF p_status='DELIVERED' AND nullif(trim(p_received_by_name),'') IS NULL THEN RAISE EXCEPTION 'Receiver name is required for a delivered stop.'; END IF;
  IF p_status='FAILED' AND nullif(trim(p_failure_reason),'') IS NULL THEN RAISE EXCEPTION 'Choose a failure reason before saving.'; END IF;
  SELECT s.*,r.id run_id,r.status run_status,o.id order_id INTO stop_row FROM public.delivery_stops s JOIN public.delivery_runs r ON r.id=s.run_id JOIN public.orders o ON o.id=s.order_id WHERE s.id=p_stop_id FOR UPDATE;
  IF stop_row.status IN ('DELIVERED','PARTIAL') THEN RETURN p_stop_id; END IF;
  IF p_cod_collected THEN cod_collection := public.record_delivery_cod_collection(p_stop_id,p_token_hash,stop_row.cod_amount_pkr); END IF;
  FOR line_row IN SELECT * FROM jsonb_to_recordset(coalesce(p_lines,'[]'::jsonb)) AS x(order_line_id uuid,quantity_delivered numeric,quantity_short numeric,short_reason text) LOOP
    IF NOT EXISTS (SELECT 1 FROM public.order_lines ol WHERE ol.id=line_row.order_line_id AND ol.order_id=stop_row.order_id) THEN RAISE EXCEPTION 'A delivery line does not belong to this order.'; END IF;
    INSERT INTO public.delivery_stop_lines(stop_id,order_line_id,quantity_delivered,quantity_short,short_reason) VALUES(p_stop_id,line_row.order_line_id,greatest(0,line_row.quantity_delivered),greatest(0,line_row.quantity_short),nullif(trim(line_row.short_reason),'')) ON CONFLICT(stop_id,order_line_id) DO UPDATE SET quantity_delivered=EXCLUDED.quantity_delivered,quantity_short=EXCLUDED.quantity_short,short_reason=EXCLUDED.short_reason;
  END LOOP;
  UPDATE public.delivery_stops SET status=p_status,delivered_at=CASE WHEN p_status IN ('DELIVERED','PARTIAL') THEN now() ELSE delivered_at END,received_by_name=nullif(trim(p_received_by_name),''),signature_url=nullif(trim(p_signature_url),''),photo_url=nullif(trim(p_photo_url),''),latitude=p_latitude,longitude=p_longitude,failure_reason=nullif(trim(p_failure_reason),''),notes=nullif(trim(p_notes),'') WHERE id=p_stop_id;
  IF p_status IN ('DELIVERED','PARTIAL') THEN UPDATE public.orders SET status='DELIVERED',delivered_at=now() WHERE id=stop_row.order_id AND status <> 'CANCELLED'; END IF;
  SELECT count(*) FILTER (WHERE status IN ('DELIVERED','PARTIAL','FAILED')) INTO completed_count FROM public.delivery_stops WHERE run_id=stop_row.run_id;
  UPDATE public.delivery_runs SET completed_stops=completed_count,status=CASE WHEN completed_count=total_stops THEN 'COMPLETED' ELSE status END,completed_at=CASE WHEN completed_count=total_stops THEN now() ELSE completed_at END WHERE id=stop_row.run_id;
  IF p_status='PARTIAL' THEN INSERT INTO public.notifications(user_id,type,title_en,title_ur,body,link_url) SELECT sa.user_id,'SHORT_SUPPLY_CLAIM_REQUIRED','Short supply recorded','Short supply recorded','A partial delivery needs a short-supply claim review.','/en/admin/claims' FROM public.customers c JOIN public.sales_agents sa ON sa.id=c.assigned_agent_id WHERE c.id=stop_row.customer_id; END IF;
  INSERT INTO public.audit_logs(user_id,action,entity_type,entity_id,changes_json) VALUES(NULL,'COMPLETE_DELIVERY_STOP','DELIVERY_STOP',p_stop_id::text,jsonb_build_object('status',p_status,'cod_collection_id',cod_collection));
  RETURN p_stop_id;
END; $$;
REVOKE ALL ON FUNCTION public.complete_delivery_stop_by_token(uuid,text,public."DeliveryStopStatus",text,text,text,numeric,numeric,boolean,text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.complete_delivery_stop_by_token(uuid,text,public."DeliveryStopStatus",text,text,text,numeric,numeric,boolean,text,text,jsonb) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.delivery_run_summary(p_run_id uuid)
RETURNS TABLE(run_id uuid,run_number text,driver_name text,vehicle_number text,run_date date,status text,total_stops integer,completed_stops integer,expected_cod_amount_pkr numeric(12,2),collected_cod_amount_pkr numeric(12,2),remaining_cod_amount_pkr numeric(12,2)) LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT r.id,r.run_number,r.driver_name,r.vehicle_number,r.run_date,r.status::text,r.total_stops,r.completed_stops,r.expected_cod_amount_pkr,r.collected_cod_amount_pkr,(r.expected_cod_amount_pkr-r.collected_cod_amount_pkr)::numeric(12,2) FROM public.delivery_runs r WHERE r.id=p_run_id AND public.has_permission(auth.uid(),'delivery.view');
$$;
GRANT EXECUTE ON FUNCTION public.delivery_run_summary(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.delivery_failure_patterns(p_customer_id uuid DEFAULT NULL)
RETURNS TABLE(failure_reason text,failed_count bigint,first_failed_at timestamptz,last_failed_at timestamptz) LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT s.failure_reason,count(*)::bigint,min(s.delivered_at),max(s.delivered_at) FROM public.delivery_stops s WHERE public.has_permission(auth.uid(),'delivery.view') AND s.status='FAILED' AND (p_customer_id IS NULL OR s.customer_id=p_customer_id) GROUP BY s.failure_reason ORDER BY count(*) DESC;
$$;
GRANT EXECUTE ON FUNCTION public.delivery_failure_patterns(uuid) TO authenticated;
