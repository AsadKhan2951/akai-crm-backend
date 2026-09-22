-- AKAI CRM Phase 20 corrective/reporting migration.
-- 0046 is applied and immutable. Additive only.

CREATE OR REPLACE FUNCTION public.raise_short_supply_claim_from_delivery() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE order_row record; claim_id uuid;
BEGIN
  IF NEW.quantity_short<=0 OR EXISTS (SELECT 1 FROM public.claims WHERE source_delivery_stop_line_id=NEW.id) THEN RETURN NEW; END IF;
  SELECT o.id,o.customer_id,o.placed_by_user_id,c.assigned_agent_id INTO order_row FROM public.delivery_stops ds JOIN public.orders o ON o.id=ds.order_id JOIN public.customers c ON c.id=o.customer_id WHERE ds.id=NEW.stop_id;
  IF order_row.id IS NULL THEN RETURN NEW; END IF;
  INSERT INTO public.claims(id,claim_number,customer_id,order_id,raised_by_user_id,assigned_agent_id,claim_type,status,description,source_delivery_stop_line_id) VALUES(gen_random_uuid(),public.next_claim_number(),order_row.customer_id,order_row.id,order_row.placed_by_user_id,order_row.assigned_agent_id,'SHORT_SUPPLY','SUBMITTED','Short supply created from partial delivery.',NEW.id) RETURNING id INTO claim_id;
  INSERT INTO public.claim_lines(claim_id,product_id,quantity,reason_notes) SELECT claim_id,ol.product_id,NEW.quantity_short,'Automatically raised from partial delivery.' FROM public.order_lines ol WHERE ol.id=NEW.order_line_id;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.notify_claim_status_change() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE vendor_user record;
BEGIN
  IF TG_OP <> 'UPDATE' OR OLD.status IS NOT DISTINCT FROM NEW.status THEN RETURN NEW; END IF;
  FOR vendor_user IN SELECT cu.user_id FROM public.customer_users cu WHERE cu.customer_id=NEW.customer_id LOOP
    INSERT INTO public.notifications(user_id,type,title_en,title_ur,body,link_url) VALUES(vendor_user.user_id,'CLAIM_STATUS','Claim status updated','دعویٰ کی حیثیت تبدیل ہو گئی','Claim '||NEW.claim_number||' is now '||replace(NEW.status::text,'_',' ')||'.','/vendor/claims/'||NEW.id::text);
  END LOOP;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS claim_status_notification_trigger ON public.claims;
CREATE TRIGGER claim_status_notification_trigger AFTER UPDATE OF status ON public.claims FOR EACH ROW EXECUTE FUNCTION public.notify_claim_status_change();

CREATE OR REPLACE FUNCTION public.claim_rate_by_product() RETURNS TABLE(product_id uuid,sku text,product_name text,claim_count bigint,units_claimed numeric,units_sold numeric,claim_rate_percent numeric) LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$
SELECT p.id,p.sku,p.name_en,count(DISTINCT c.id),coalesce(sum(cl.quantity),0),coalesce((SELECT sum(ol.quantity) FROM public.order_lines ol JOIN public.orders o ON o.id=ol.order_id WHERE ol.product_id=p.id AND o.status<>'CANCELLED'),0),CASE WHEN coalesce((SELECT sum(ol.quantity) FROM public.order_lines ol JOIN public.orders o ON o.id=ol.order_id WHERE ol.product_id=p.id AND o.status<>'CANCELLED'),0)=0 THEN 0 ELSE round((sum(cl.quantity)/(SELECT sum(ol.quantity) FROM public.order_lines ol JOIN public.orders o ON o.id=ol.order_id WHERE ol.product_id=p.id AND o.status<>'CANCELLED'))*100,2) END FROM public.claim_lines cl JOIN public.claims c ON c.id=cl.claim_id JOIN public.products p ON p.id=cl.product_id WHERE public.has_permission(auth.uid(),'claim.view') GROUP BY p.id,p.sku,p.name_en ORDER BY 7 DESC;
$$;
GRANT EXECUTE ON FUNCTION public.claim_rate_by_product() TO authenticated;

CREATE OR REPLACE FUNCTION public.claim_rate_by_brand() RETURNS TABLE(brand_id uuid,brand_name text,claim_count bigint,units_claimed numeric,units_sold numeric,claim_rate_percent numeric) LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$
SELECT b.id,b.name_en,count(DISTINCT c.id),coalesce(sum(cl.quantity),0),coalesce((SELECT sum(ol.quantity) FROM public.order_lines ol JOIN public.orders o ON o.id=ol.order_id JOIN public.products pp ON pp.id=ol.product_id WHERE pp.brand_id=b.id AND o.status<>'CANCELLED'),0),CASE WHEN coalesce((SELECT sum(ol.quantity) FROM public.order_lines ol JOIN public.orders o ON o.id=ol.order_id JOIN public.products pp ON pp.id=ol.product_id WHERE pp.brand_id=b.id AND o.status<>'CANCELLED'),0)=0 THEN 0 ELSE round((sum(cl.quantity)/(SELECT sum(ol.quantity) FROM public.order_lines ol JOIN public.orders o ON o.id=ol.order_id JOIN public.products pp ON pp.id=ol.product_id WHERE pp.brand_id=b.id AND o.status<>'CANCELLED'))*100,2) END FROM public.claim_lines cl JOIN public.claims c ON c.id=cl.claim_id JOIN public.products p ON p.id=cl.product_id JOIN public.brands b ON b.id=p.brand_id WHERE public.has_permission(auth.uid(),'claim.view') GROUP BY b.id,b.name_en ORDER BY 6 DESC;
$$;
GRANT EXECUTE ON FUNCTION public.claim_rate_by_brand() TO authenticated;

CREATE OR REPLACE FUNCTION public.claim_rate_by_category() RETURNS TABLE(category_id uuid,category_name text,claim_count bigint,units_claimed numeric,units_sold numeric,claim_rate_percent numeric) LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$
SELECT cat.id,cat.name_en,count(DISTINCT c.id),coalesce(sum(cl.quantity),0),coalesce((SELECT sum(ol.quantity) FROM public.order_lines ol JOIN public.orders o ON o.id=ol.order_id JOIN public.products pp ON pp.id=ol.product_id WHERE pp.category_id=cat.id AND o.status<>'CANCELLED'),0),CASE WHEN coalesce((SELECT sum(ol.quantity) FROM public.order_lines ol JOIN public.orders o ON o.id=ol.order_id JOIN public.products pp ON pp.id=ol.product_id WHERE pp.category_id=cat.id AND o.status<>'CANCELLED'),0)=0 THEN 0 ELSE round((sum(cl.quantity)/(SELECT sum(ol.quantity) FROM public.order_lines ol JOIN public.orders o ON o.id=ol.order_id JOIN public.products pp ON pp.id=ol.product_id WHERE pp.category_id=cat.id AND o.status<>'CANCELLED'))*100,2) END FROM public.claim_lines cl JOIN public.claims c ON c.id=cl.claim_id JOIN public.products p ON p.id=cl.product_id JOIN public.categories cat ON cat.id=p.category_id WHERE public.has_permission(auth.uid(),'claim.view') GROUP BY cat.id,cat.name_en ORDER BY 6 DESC;
$$;
GRANT EXECUTE ON FUNCTION public.claim_rate_by_category() TO authenticated;

CREATE OR REPLACE FUNCTION public.claim_rate_by_customer() RETURNS TABLE(customer_id uuid,business_name text,claim_count bigint,units_claimed numeric) LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$ SELECT c.customer_id,cu.business_name,count(DISTINCT c.id),coalesce(sum(cl.quantity),0) FROM public.claims c JOIN public.customers cu ON cu.id=c.customer_id JOIN public.claim_lines cl ON cl.claim_id=c.id WHERE public.has_permission(auth.uid(),'claim.view') GROUP BY c.customer_id,cu.business_name ORDER BY 3 DESC; $$;
GRANT EXECUTE ON FUNCTION public.claim_rate_by_customer() TO authenticated;

CREATE OR REPLACE FUNCTION public.claim_rate_by_delivery_run() RETURNS TABLE(run_id uuid,run_number text,claim_count bigint,units_claimed numeric) LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$ SELECT dr.id,dr.run_number,count(DISTINCT c.id),coalesce(sum(cl.quantity),0) FROM public.claims c JOIN public.claim_lines cl ON cl.claim_id=c.id JOIN public.delivery_stop_lines dsl ON dsl.id=c.source_delivery_stop_line_id JOIN public.delivery_stops ds ON ds.id=dsl.stop_id JOIN public.delivery_runs dr ON dr.id=ds.run_id WHERE public.has_permission(auth.uid(),'claim.view') GROUP BY dr.id,dr.run_number ORDER BY 3 DESC; $$;
GRANT EXECUTE ON FUNCTION public.claim_rate_by_delivery_run() TO authenticated;

CREATE OR REPLACE FUNCTION public.claim_cost_monthly() RETURNS TABLE(month text,credit_note_amount_pkr numeric,replacement_count bigint,claim_count bigint,revenue_pkr numeric,cost_percent numeric) LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$
WITH claims_by_month AS (SELECT date_trunc('month',c.created_at AT TIME ZONE 'Asia/Karachi') AS month_key,coalesce(sum(abs(le.amount_pkr)) FILTER (WHERE c.resolution_type='CREDIT_NOTE'),0) AS credit_amount,count(*) FILTER (WHERE c.resolution_type='REPLACEMENT') AS replacements,count(*) AS claims_count FROM public.claims c LEFT JOIN public.ledger_entries le ON le.id=c.credit_note_ledger_entry_id WHERE public.has_permission(auth.uid(),'claim.view') GROUP BY 1), revenue_by_month AS (SELECT date_trunc('month',o.placed_at AT TIME ZONE 'Asia/Karachi') AS month_key,sum(o.total_pkr) AS revenue FROM public.orders o WHERE o.status<>'CANCELLED' GROUP BY 1)
SELECT to_char(c.month_key,'YYYY-MM'),c.credit_amount,c.replacements,c.claims_count,coalesce(r.revenue,0),CASE WHEN coalesce(r.revenue,0)=0 THEN 0 ELSE round((c.credit_amount/r.revenue)*100,2) END FROM claims_by_month c LEFT JOIN revenue_by_month r USING(month_key) ORDER BY 1 DESC;
$$;
GRANT EXECUTE ON FUNCTION public.claim_cost_monthly() TO authenticated;
