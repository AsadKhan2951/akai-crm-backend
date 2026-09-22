-- AKAI CRM Phase 20: Returns, claims and warranty.
-- Additive only. Applied migrations are never edited.

DO $$ BEGIN
  CREATE TYPE public."ClaimType" AS ENUM ('DAMAGED','SHORT_SUPPLY','WRONG_ITEM','EXPIRED','WARRANTY','QUALITY');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE public."ClaimStatus" AS ENUM ('SUBMITTED','UNDER_REVIEW','APPROVED','REJECTED','RESOLVED');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE public."ClaimResolutionType" AS ENUM ('REPLACEMENT','CREDIT_NOTE','REFUND','REPAIR','NO_ACTION');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS public.claims (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), assigned_agent_id uuid REFERENCES public.sales_agents(id) ON DELETE SET NULL,
  claim_number text, customer_id uuid REFERENCES public.customers(id) ON DELETE RESTRICT, order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  raised_by_user_id uuid REFERENCES public.users(id) ON DELETE RESTRICT, claim_type public."ClaimType", status public."ClaimStatus" NOT NULL DEFAULT 'SUBMITTED',
  description text, reviewed_by_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL, reviewed_at timestamptz, first_reviewed_at timestamptz,
  rejection_reason text, resolution_type public."ClaimResolutionType", resolved_at timestamptz, credit_note_ledger_entry_id uuid REFERENCES public.ledger_entries(id) ON DELETE SET NULL,
  replacement_order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL, source_delivery_stop_line_id uuid REFERENCES public.delivery_stop_lines(id) ON DELETE SET NULL,
  resolution_notes text, created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.products ADD COLUMN IF NOT EXISTS warranty_months integer;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='products_warranty_months_nonnegative_check') THEN
    ALTER TABLE public.products ADD CONSTRAINT products_warranty_months_nonnegative_check CHECK (warranty_months IS NULL OR warranty_months >= 0);
  END IF;
END $$;

ALTER TABLE public.claims ADD COLUMN IF NOT EXISTS claim_number text;
ALTER TABLE public.claims ADD COLUMN IF NOT EXISTS customer_id uuid;
ALTER TABLE public.claims ADD COLUMN IF NOT EXISTS order_id uuid;
ALTER TABLE public.claims ADD COLUMN IF NOT EXISTS raised_by_user_id uuid;
ALTER TABLE public.claims ADD COLUMN IF NOT EXISTS claim_type public."ClaimType";
ALTER TABLE public.claims ADD COLUMN IF NOT EXISTS description text;
ALTER TABLE public.claims ADD COLUMN IF NOT EXISTS reviewed_by_user_id uuid;
ALTER TABLE public.claims ADD COLUMN IF NOT EXISTS reviewed_at timestamptz;
ALTER TABLE public.claims ADD COLUMN IF NOT EXISTS first_reviewed_at timestamptz;
ALTER TABLE public.claims ADD COLUMN IF NOT EXISTS rejection_reason text;
ALTER TABLE public.claims ADD COLUMN IF NOT EXISTS resolution_type public."ClaimResolutionType";
ALTER TABLE public.claims ADD COLUMN IF NOT EXISTS resolved_at timestamptz;
ALTER TABLE public.claims ADD COLUMN IF NOT EXISTS credit_note_ledger_entry_id uuid;
ALTER TABLE public.claims ADD COLUMN IF NOT EXISTS replacement_order_id uuid;
ALTER TABLE public.claims ADD COLUMN IF NOT EXISTS source_delivery_stop_line_id uuid;
ALTER TABLE public.claims ADD COLUMN IF NOT EXISTS resolution_notes text;

WITH numbered AS (
  SELECT id,'AKAI-C-'||to_char(created_at AT TIME ZONE 'Asia/Karachi','YYYYMM')||'-'||lpad(row_number() over (partition by date_trunc('month',created_at AT TIME ZONE 'Asia/Karachi') order by created_at)::text,4,'0') AS number_value
  FROM public.claims WHERE claim_number IS NULL
)
UPDATE public.claims c SET claim_number=n.number_value FROM numbered n WHERE c.id=n.id;
UPDATE public.claims SET status='SUBMITTED' WHERE status IS NULL OR status NOT IN ('SUBMITTED','UNDER_REVIEW','APPROVED','REJECTED','RESOLVED');
UPDATE public.claims SET claim_type='QUALITY' WHERE claim_type IS NULL;
UPDATE public.claims SET description='Legacy claim migrated to Phase 20.' WHERE description IS NULL;
UPDATE public.claims c SET customer_id=coalesce(c.customer_id,(SELECT id FROM public.customers WHERE assigned_agent_id=c.assigned_agent_id ORDER BY created_at LIMIT 1)) WHERE c.customer_id IS NULL;
UPDATE public.claims c SET raised_by_user_id=coalesce(c.raised_by_user_id,(SELECT sa.user_id FROM public.sales_agents sa WHERE sa.id=c.assigned_agent_id)) WHERE c.raised_by_user_id IS NULL;

ALTER TABLE public.claims ALTER COLUMN claim_number SET NOT NULL;
ALTER TABLE public.claims ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE public.claims ALTER COLUMN raised_by_user_id SET NOT NULL;
ALTER TABLE public.claims ALTER COLUMN claim_type SET NOT NULL;
ALTER TABLE public.claims ALTER COLUMN description SET NOT NULL;
ALTER TABLE public.claims ALTER COLUMN status TYPE public."ClaimStatus" USING status::public."ClaimStatus";
ALTER TABLE public.claims ALTER COLUMN status SET DEFAULT 'SUBMITTED';
ALTER TABLE public.claims ALTER COLUMN status SET NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='claims_claim_number_key') THEN ALTER TABLE public.claims ADD CONSTRAINT claims_claim_number_key UNIQUE (claim_number); END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='claims_customer_id_fkey') THEN ALTER TABLE public.claims ADD CONSTRAINT claims_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE RESTRICT; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='claims_order_id_fkey') THEN ALTER TABLE public.claims ADD CONSTRAINT claims_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE SET NULL; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='claims_raised_by_user_id_fkey') THEN ALTER TABLE public.claims ADD CONSTRAINT claims_raised_by_user_id_fkey FOREIGN KEY (raised_by_user_id) REFERENCES public.users(id) ON DELETE RESTRICT; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='claims_reviewed_by_user_id_fkey') THEN ALTER TABLE public.claims ADD CONSTRAINT claims_reviewed_by_user_id_fkey FOREIGN KEY (reviewed_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='claims_credit_note_ledger_entry_id_fkey') THEN ALTER TABLE public.claims ADD CONSTRAINT claims_credit_note_ledger_entry_id_fkey FOREIGN KEY (credit_note_ledger_entry_id) REFERENCES public.ledger_entries(id) ON DELETE SET NULL; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='claims_replacement_order_id_fkey') THEN ALTER TABLE public.claims ADD CONSTRAINT claims_replacement_order_id_fkey FOREIGN KEY (replacement_order_id) REFERENCES public.orders(id) ON DELETE SET NULL; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='claims_source_delivery_stop_line_id_fkey') THEN ALTER TABLE public.claims ADD CONSTRAINT claims_source_delivery_stop_line_id_fkey FOREIGN KEY (source_delivery_stop_line_id) REFERENCES public.delivery_stop_lines(id) ON DELETE SET NULL; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='claims_rejection_reason_check') THEN ALTER TABLE public.claims ADD CONSTRAINT claims_rejection_reason_check CHECK (status <> 'REJECTED' OR nullif(trim(rejection_reason),'') IS NOT NULL); END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.claim_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), claim_id uuid NOT NULL REFERENCES public.claims(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT, quantity numeric(12,3) NOT NULL,
  batch_or_serial text, reason_notes text, created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT claim_lines_quantity_positive_check CHECK (quantity > 0)
);
CREATE TABLE IF NOT EXISTS public.claim_photos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), claim_id uuid NOT NULL REFERENCES public.claims(id) ON DELETE CASCADE,
  url text NOT NULL, caption text, uploaded_at timestamptz NOT NULL DEFAULT now(), uploaded_by_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL
);
CREATE TABLE IF NOT EXISTS public.warranty_registrations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  serial_number text NOT NULL UNIQUE, customer_id uuid NOT NULL REFERENCES public.customers(id) ON DELETE RESTRICT,
  end_customer_name text, end_customer_phone text, sold_at timestamptz NOT NULL, warranty_months integer NOT NULL,
  expires_at timestamptz NOT NULL, registered_by_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  consent_for_consumer_contact boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT warranty_months_positive_check CHECK (warranty_months > 0)
);
CREATE INDEX IF NOT EXISTS claims_customer_status_created_idx ON public.claims(customer_id,status,created_at DESC);
CREATE INDEX IF NOT EXISTS claims_order_idx ON public.claims(order_id) WHERE order_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS claims_type_status_created_idx ON public.claims(claim_type,status,created_at DESC);
CREATE INDEX IF NOT EXISTS claims_assigned_status_idx ON public.claims(assigned_agent_id,status,created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS claims_source_delivery_stop_line_unique_idx ON public.claims(source_delivery_stop_line_id) WHERE source_delivery_stop_line_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS claim_lines_product_idx ON public.claim_lines(product_id,claim_id);
CREATE INDEX IF NOT EXISTS claim_photos_claim_idx ON public.claim_photos(claim_id,uploaded_at);
CREATE INDEX IF NOT EXISTS warranty_customer_expiry_idx ON public.warranty_registrations(customer_id,expires_at);
CREATE INDEX IF NOT EXISTS warranty_product_serial_idx ON public.warranty_registrations(product_id,serial_number);
CREATE INDEX IF NOT EXISTS warranty_expiry_idx ON public.warranty_registrations(expires_at);

CREATE TABLE IF NOT EXISTS public.claim_number_counters (month date PRIMARY KEY, last_number integer NOT NULL DEFAULT 0 CHECK(last_number >= 0));

CREATE OR REPLACE FUNCTION public.next_claim_number(p_created_at timestamptz DEFAULT now()) RETURNS text LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $$
DECLARE month_key date := ((p_created_at AT TIME ZONE 'Asia/Karachi')::date - extract(day from (p_created_at AT TIME ZONE 'Asia/Karachi')::date)::integer + 1); next_number integer;
BEGIN
  INSERT INTO public.claim_number_counters(month,last_number) VALUES(month_key,1) ON CONFLICT(month) DO UPDATE SET last_number=claim_number_counters.last_number+1 RETURNING last_number INTO next_number;
  RETURN 'AKAI-C-'||to_char(month_key,'YYYYMM')||'-'||lpad(next_number::text,4,'0');
END; $$;

CREATE OR REPLACE FUNCTION public.claim_customer_in_scope(p_customer_id uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$
SELECT EXISTS (SELECT 1 FROM public.customers c WHERE c.id=p_customer_id AND (public.role_scope(auth.uid())='GLOBAL' OR c.assigned_agent_id IN (SELECT public.accessible_agent_ids(auth.uid())) OR EXISTS (SELECT 1 FROM public.customer_users cu WHERE cu.customer_id=c.id AND cu.user_id=auth.uid()) OR EXISTS (SELECT 1 FROM public.vendor_accounts va WHERE va.customer_id=c.id AND va.user_id=auth.uid())));
$$;

CREATE OR REPLACE FUNCTION public.create_claim(p_customer_id uuid,p_order_id uuid,p_claim_type text,p_description text,p_lines jsonb,p_photo_urls jsonb DEFAULT '[]'::jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $$
DECLARE claim_id uuid:=gen_random_uuid(); claim_record record; line_record jsonb; photo_record jsonb; photo_required boolean; order_customer uuid;
BEGIN
  IF NOT public.has_permission(auth.uid(),'claim.create') THEN RAISE EXCEPTION 'Claim creation is not permitted.'; END IF;
  IF NOT public.claim_customer_in_scope(p_customer_id) THEN RAISE EXCEPTION 'This customer is outside your scope.'; END IF;
  IF p_claim_type NOT IN ('DAMAGED','SHORT_SUPPLY','WRONG_ITEM','EXPIRED','WARRANTY','QUALITY') THEN RAISE EXCEPTION 'Invalid claim type.'; END IF;
  IF nullif(trim(p_description),'') IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines)=0 THEN RAISE EXCEPTION 'Description and at least one claim line are required.'; END IF;
  IF jsonb_array_length(p_photo_urls) > 5 THEN RAISE EXCEPTION 'A claim may contain at most five photos.'; END IF;
  SELECT coalesce((value_json->>p_claim_type)::boolean,(p_claim_type='DAMAGED')) INTO photo_required FROM public.settings WHERE key='claim_photo_required';
  IF photo_required AND p_claim_type='DAMAGED' AND jsonb_array_length(p_photo_urls)=0 THEN RAISE EXCEPTION 'Damage claims require at least one photo.'; END IF;
  IF p_order_id IS NOT NULL THEN SELECT customer_id INTO order_customer FROM public.orders WHERE id=p_order_id; IF order_customer IS DISTINCT FROM p_customer_id THEN RAISE EXCEPTION 'The order does not belong to this customer.'; END IF; END IF;
  INSERT INTO public.claims(id,claim_number,customer_id,order_id,raised_by_user_id,assigned_agent_id,claim_type,status,description) SELECT claim_id,public.next_claim_number(),p_customer_id,p_order_id,auth.uid(),c.assigned_agent_id,p_claim_type::public."ClaimType",'SUBMITTED',trim(p_description) FROM public.customers c WHERE c.id=p_customer_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Customer not found.'; END IF;
  FOR line_record IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    IF coalesce((line_record->>'quantity')::numeric,0)<=0 OR nullif(line_record->>'productId','') IS NULL THEN RAISE EXCEPTION 'Each claim line needs a product and positive quantity.'; END IF;
    IF p_order_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.order_lines ol WHERE ol.order_id=p_order_id AND ol.product_id=(line_record->>'productId')::uuid) THEN RAISE EXCEPTION 'Every claim product must belong to the selected order.'; END IF;
    INSERT INTO public.claim_lines(claim_id,product_id,quantity,batch_or_serial,reason_notes) VALUES(claim_id,(line_record->>'productId')::uuid,(line_record->>'quantity')::numeric,nullif(line_record->>'batchOrSerial',''),nullif(line_record->>'reasonNotes',''));
  END LOOP;
  FOR photo_record IN SELECT * FROM jsonb_array_elements(p_photo_urls) LOOP INSERT INTO public.claim_photos(claim_id,url,caption,uploaded_by_user_id) VALUES(claim_id,photo_record->>'url',nullif(photo_record->>'caption',''),auth.uid()); END LOOP;
  RETURN claim_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.create_claim(uuid,uuid,text,text,jsonb,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.review_claim(p_claim_id uuid,p_status text,p_resolution_type text DEFAULT NULL,p_rejection_reason text DEFAULT NULL,p_notes text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $$
DECLARE claim_row public.claims;
BEGIN
  IF NOT (public.has_permission(auth.uid(),'claim.review') OR public.has_permission(auth.uid(),'claim.approve')) THEN RAISE EXCEPTION 'Claim review is not permitted.'; END IF;
  SELECT * INTO claim_row FROM public.claims WHERE id=p_claim_id FOR UPDATE;
  IF NOT FOUND OR claim_row.status IN ('REJECTED','RESOLVED') THEN RAISE EXCEPTION 'This claim is no longer reviewable.'; END IF;
  IF p_status NOT IN ('UNDER_REVIEW','APPROVED','REJECTED') THEN RAISE EXCEPTION 'Invalid review status.'; END IF;
  IF p_status='REJECTED' AND nullif(trim(p_rejection_reason),'') IS NULL THEN RAISE EXCEPTION 'A rejection reason is required.'; END IF;
  IF p_status='APPROVED' AND p_resolution_type NOT IN ('REPLACEMENT','CREDIT_NOTE','REFUND','REPAIR','NO_ACTION') THEN RAISE EXCEPTION 'An approved claim needs a resolution.'; END IF;
  UPDATE public.claims SET status=p_status::public."ClaimStatus",resolution_type=CASE WHEN p_resolution_type IS NULL THEN resolution_type ELSE p_resolution_type::public."ClaimResolutionType" END,rejection_reason=CASE WHEN p_status='REJECTED' THEN trim(p_rejection_reason) ELSE NULL END,reviewed_by_user_id=auth.uid(),reviewed_at=now(),first_reviewed_at=coalesce(first_reviewed_at,now()),resolution_notes=coalesce(nullif(trim(p_notes),''),resolution_notes) WHERE id=p_claim_id;
  RETURN p_claim_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.review_claim(uuid,text,text,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.resolve_claim(p_claim_id uuid,p_credit_amount numeric DEFAULT NULL,p_resolution_notes text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $$
DECLARE claim_row public.claims; line_row record; replacement_id uuid:=gen_random_uuid(); replacement_number text; ledger_id uuid; total_amount numeric(12,2):=0; stock_available numeric; order_line_count integer:=0;
BEGIN
  IF NOT public.has_permission(auth.uid(),'claim.approve') THEN RAISE EXCEPTION 'Claim approval is not permitted.'; END IF;
  SELECT * INTO claim_row FROM public.claims WHERE id=p_claim_id AND status='APPROVED' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Only an approved claim can be resolved.'; END IF;
  IF claim_row.resolution_type='CREDIT_NOTE' THEN
    IF coalesce(p_credit_amount,0)<=0 THEN RAISE EXCEPTION 'A positive credit amount is required.'; END IF;
    ledger_id:=public.apply_customer_ledger_delta(claim_row.customer_id,-abs(p_credit_amount),'CN-'||claim_row.claim_number,'Credit note for claim '||claim_row.claim_number,'CREDIT_NOTE');
  ELSIF claim_row.resolution_type='REPLACEMENT' THEN
    replacement_number:='AKAI-REP-'||replace(claim_row.claim_number,'AKAI-C-','');
    INSERT INTO public.orders(id,order_number,customer_id,placed_by_user_id,placed_via,payment_method,status,approval_required,subtotal_pkr,discount_pkr,points_redeemed,points_discount_pkr,total_pkr,points_earned,placed_at,confirmed_at)
    VALUES(replacement_id,replacement_number,claim_row.customer_id,auth.uid(),'ADMIN','BALANCE','CONFIRMED',false,0,0,0,0,0,0,now(),now());
    FOR line_row IN SELECT cl.*,p.stock_quantity FROM public.claim_lines cl JOIN public.products p ON p.id=cl.product_id WHERE cl.claim_id=p_claim_id FOR UPDATE OF p LOOP
      IF line_row.stock_quantity < line_row.quantity THEN RAISE EXCEPTION 'Replacement stock is not available for product %.',line_row.product_id; END IF;
      UPDATE public.products SET stock_quantity=stock_quantity-line_row.quantity WHERE id=line_row.product_id;
      INSERT INTO public.order_lines(order_id,product_id,quantity,unit_price_pkr,line_total_pkr,is_free_item) VALUES(replacement_id,line_row.product_id,line_row.quantity,0,0,true);
      order_line_count:=order_line_count+1;
    END LOOP;
    IF order_line_count=0 THEN RAISE EXCEPTION 'A replacement needs at least one claim line.'; END IF;
  END IF;
  UPDATE public.claims SET status='RESOLVED',resolved_at=now(),credit_note_ledger_entry_id=ledger_id,replacement_order_id=CASE WHEN claim_row.resolution_type='REPLACEMENT' THEN replacement_id ELSE replacement_order_id END,resolution_notes=coalesce(nullif(trim(p_resolution_notes),''),resolution_notes) WHERE id=p_claim_id;
  RETURN p_claim_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.resolve_claim(uuid,numeric,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.register_warranty(p_product_id uuid,p_serial_number text,p_customer_id uuid,p_end_customer_name text,p_end_customer_phone text,p_sold_at timestamptz,p_consent boolean DEFAULT false) RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $$
DECLARE warranty_id uuid:=gen_random_uuid(); months integer;
BEGIN
  IF NOT public.has_permission(auth.uid(),'warranty.manage') THEN RAISE EXCEPTION 'Warranty management is not permitted.'; END IF;
  IF NOT public.claim_customer_in_scope(p_customer_id) THEN RAISE EXCEPTION 'This customer is outside your scope.'; END IF;
  SELECT warranty_months INTO months FROM public.products WHERE id=p_product_id AND is_active;
  IF coalesce(months,0)<=0 THEN RAISE EXCEPTION 'This product has no configured warranty period.'; END IF;
  IF nullif(trim(p_serial_number),'') IS NULL THEN RAISE EXCEPTION 'Serial number is required.'; END IF;
  INSERT INTO public.warranty_registrations(id,product_id,serial_number,customer_id,end_customer_name,end_customer_phone,sold_at,warranty_months,expires_at,registered_by_user_id,consent_for_consumer_contact) VALUES(warranty_id,p_product_id,trim(p_serial_number),p_customer_id,nullif(trim(p_end_customer_name),''),nullif(trim(p_end_customer_phone),''),p_sold_at,months,p_sold_at + make_interval(months=>months),auth.uid(),p_consent);
  RETURN warranty_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.register_warranty(uuid,text,uuid,text,text,timestamptz,boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.business_date_before(p_date date,p_business_days integer) RETURNS date LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE cursor_date date:=p_date; counted integer:=0;
BEGIN
  WHILE counted < greatest(p_business_days,0) LOOP
    cursor_date:=cursor_date-1;
    IF extract(isodow FROM cursor_date) < 6 THEN counted:=counted+1; END IF;
  END LOOP;
  RETURN cursor_date;
END; $$;

CREATE OR REPLACE FUNCTION public.claim_sla_summary() RETURNS TABLE(submitted_count bigint,under_review_count bigint,first_review_breaches bigint,resolution_breaches bigint) LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$
SELECT count(*) FILTER (WHERE status='SUBMITTED'),count(*) FILTER (WHERE status='UNDER_REVIEW'),count(*) FILTER (WHERE status IN ('SUBMITTED','UNDER_REVIEW') AND (created_at AT TIME ZONE 'Asia/Karachi')::date < public.business_date_before((now() AT TIME ZONE 'Asia/Karachi')::date,2)),count(*) FILTER (WHERE status='APPROVED' AND reviewed_at IS NOT NULL AND (reviewed_at AT TIME ZONE 'Asia/Karachi')::date < public.business_date_before((now() AT TIME ZONE 'Asia/Karachi')::date,3)) FROM public.claims WHERE public.has_permission(auth.uid(),'claim.view');
$$;
GRANT EXECUTE ON FUNCTION public.claim_sla_summary() TO authenticated;

DROP POLICY IF EXISTS claims_select ON public.claims;
DROP POLICY IF EXISTS claims_select_phase20 ON public.claims;
DROP POLICY IF EXISTS claims_insert_phase20 ON public.claims;
DROP POLICY IF EXISTS claims_update_phase20 ON public.claims;
CREATE POLICY claims_select_phase20 ON public.claims FOR SELECT TO authenticated USING (public.has_permission(auth.uid(),'claim.view') AND public.claim_customer_in_scope(customer_id));
CREATE POLICY claims_insert_phase20 ON public.claims FOR INSERT TO authenticated WITH CHECK (public.has_permission(auth.uid(),'claim.create') AND raised_by_user_id=auth.uid() AND public.claim_customer_in_scope(customer_id));
CREATE POLICY claims_update_phase20 ON public.claims FOR UPDATE TO authenticated USING ((public.has_permission(auth.uid(),'claim.review') OR public.has_permission(auth.uid(),'claim.approve')) AND public.claim_customer_in_scope(customer_id)) WITH CHECK (public.has_permission(auth.uid(),'claim.approve') OR public.has_permission(auth.uid(),'claim.review'));
ALTER TABLE public.claims ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.claim_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.claim_photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.warranty_registrations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS claim_lines_select_phase20 ON public.claim_lines;
DROP POLICY IF EXISTS claim_lines_insert_phase20 ON public.claim_lines;
DROP POLICY IF EXISTS claim_photos_select_phase20 ON public.claim_photos;
DROP POLICY IF EXISTS claim_photos_insert_phase20 ON public.claim_photos;
DROP POLICY IF EXISTS warranty_select_phase20 ON public.warranty_registrations;
DROP POLICY IF EXISTS warranty_insert_phase20 ON public.warranty_registrations;
CREATE POLICY claim_lines_select_phase20 ON public.claim_lines FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.claims c WHERE c.id=claim_id AND public.claim_customer_in_scope(c.customer_id)));
CREATE POLICY claim_lines_insert_phase20 ON public.claim_lines FOR INSERT TO authenticated WITH CHECK (public.has_permission(auth.uid(),'claim.create') AND EXISTS (SELECT 1 FROM public.claims c WHERE c.id=claim_id AND c.raised_by_user_id=auth.uid()));
CREATE POLICY claim_photos_select_phase20 ON public.claim_photos FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.claims c WHERE c.id=claim_id AND public.claim_customer_in_scope(c.customer_id)));
CREATE POLICY claim_photos_insert_phase20 ON public.claim_photos FOR INSERT TO authenticated WITH CHECK (public.has_permission(auth.uid(),'claim.create') AND uploaded_by_user_id=auth.uid() AND EXISTS (SELECT 1 FROM public.claims c WHERE c.id=claim_id AND c.raised_by_user_id=auth.uid()));
CREATE POLICY warranty_select_phase20 ON public.warranty_registrations FOR SELECT TO authenticated USING (public.has_permission(auth.uid(),'warranty.manage') AND (public.claim_customer_in_scope(customer_id) OR public.role_scope(auth.uid())='GLOBAL'));
CREATE POLICY warranty_insert_phase20 ON public.warranty_registrations FOR INSERT TO authenticated WITH CHECK (public.has_permission(auth.uid(),'warranty.manage') AND registered_by_user_id=auth.uid() AND public.claim_customer_in_scope(customer_id));

CREATE OR REPLACE FUNCTION public.raise_short_supply_claim_from_delivery() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE order_row record; claim_id uuid;
BEGIN
  IF NEW.quantity_short<=0 THEN RETURN NEW; END IF;
  SELECT o.id,o.customer_id,o.placed_by_user_id,c.assigned_agent_id INTO order_row FROM public.delivery_stops ds JOIN public.orders o ON o.id=ds.order_id JOIN public.customers c ON c.id=o.customer_id WHERE ds.id=NEW.stop_id;
  IF order_row.id IS NULL THEN RETURN NEW; END IF;
  INSERT INTO public.claims(id,claim_number,customer_id,order_id,raised_by_user_id,assigned_agent_id,claim_type,status,description,source_delivery_stop_line_id) VALUES(gen_random_uuid(),public.next_claim_number(),order_row.customer_id,order_row.id,order_row.placed_by_user_id,order_row.assigned_agent_id,'SHORT_SUPPLY','SUBMITTED','Short supply created from partial delivery.',NEW.id) RETURNING id INTO claim_id;
  INSERT INTO public.claim_lines(claim_id,product_id,quantity,reason_notes) SELECT claim_id,ol.product_id,NEW.quantity_short,'Automatically raised from partial delivery.' FROM public.order_lines ol WHERE ol.id=NEW.order_line_id;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS delivery_short_supply_claim_trigger ON public.delivery_stop_lines;
CREATE TRIGGER delivery_short_supply_claim_trigger AFTER INSERT OR UPDATE OF quantity_short ON public.delivery_stop_lines FOR EACH ROW EXECUTE FUNCTION public.raise_short_supply_claim_from_delivery();

CREATE OR REPLACE FUNCTION public.warranty_expiry_summary(p_days integer DEFAULT 30) RETURNS TABLE(id uuid,customer_id uuid,serial_number text,expires_at timestamptz) LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$ SELECT id,customer_id,serial_number,expires_at FROM public.warranty_registrations WHERE public.has_permission(auth.uid(),'warranty.manage') AND expires_at >= now() AND expires_at < now()+make_interval(days=>greatest(p_days,1)); $$;
GRANT EXECUTE ON FUNCTION public.warranty_expiry_summary(integer) TO authenticated;
