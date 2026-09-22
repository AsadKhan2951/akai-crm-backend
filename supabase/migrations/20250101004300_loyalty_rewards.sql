-- AKAI CRM Phase 19: loyalty, rewards and freebies.
-- Additive only. Applied migrations are never edited.
-- All balance changes go through apply_loyalty_delta().

ALTER TABLE public.loyalty_transactions ADD COLUMN IF NOT EXISTS idempotency_key text;
ALTER TABLE public.loyalty_transactions ADD COLUMN IF NOT EXISTS created_by_user_id uuid;
UPDATE public.loyalty_transactions SET idempotency_key = 'legacy:' || id::text WHERE idempotency_key IS NULL;
ALTER TABLE public.loyalty_transactions ALTER COLUMN idempotency_key SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS loyalty_transactions_idempotency_key_idx ON public.loyalty_transactions(idempotency_key);
CREATE INDEX IF NOT EXISTS loyalty_transactions_redemption_id_idx ON public.loyalty_transactions(redemption_id);
ALTER TABLE public.loyalty_transactions DROP CONSTRAINT IF EXISTS loyalty_transactions_points_nonzero_check;
ALTER TABLE public.loyalty_transactions ADD CONSTRAINT loyalty_transactions_points_nonzero_check CHECK (points <> 0);

ALTER TABLE public.redemptions ADD COLUMN IF NOT EXISTS rejected_reason text;
CREATE INDEX IF NOT EXISTS redemptions_reward_status_idx ON public.redemptions(reward_id, status, requested_at);
CREATE UNIQUE INDEX IF NOT EXISTS redemptions_one_pending_per_customer_reward_idx
  ON public.redemptions(customer_id, reward_id)
  WHERE status IN ('REQUESTED','APPROVED');

ALTER TABLE public.order_lines ADD COLUMN IF NOT EXISTS redemption_id uuid;
CREATE INDEX IF NOT EXISTS order_lines_redemption_id_idx ON public.order_lines(redemption_id);

ALTER TABLE public.customers DROP CONSTRAINT IF EXISTS customers_loyalty_points_nonnegative_check;
ALTER TABLE public.customers ADD CONSTRAINT customers_loyalty_points_nonnegative_check CHECK (loyalty_points_balance >= 0);

CREATE OR REPLACE FUNCTION public.guard_loyalty_balance_update()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
BEGIN
  IF NEW.loyalty_points_balance IS DISTINCT FROM OLD.loyalty_points_balance
     AND coalesce(current_setting('app.loyalty_balance_mutation', true), 'off') <> 'on' THEN
    RAISE EXCEPTION 'Customer loyalty balance can only be changed by the loyalty service.';
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS customers_loyalty_balance_guard ON public.customers;
CREATE TRIGGER customers_loyalty_balance_guard
BEFORE UPDATE OF loyalty_points_balance ON public.customers
FOR EACH ROW EXECUTE FUNCTION public.guard_loyalty_balance_update();

CREATE OR REPLACE FUNCTION public.apply_loyalty_delta(
  p_customer_id uuid,
  p_points integer,
  p_reason text,
  p_order_id uuid DEFAULT NULL,
  p_redemption_id uuid DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL,
  p_created_by_user_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE transaction_id uuid; current_balance integer; key_value text;
BEGIN
  IF p_points = 0 OR nullif(trim(p_reason), '') IS NULL THEN RAISE EXCEPTION 'A non-zero loyalty delta and reason are required.'; END IF;
  key_value := coalesce(nullif(trim(p_idempotency_key), ''), 'loyalty:' || gen_random_uuid()::text);
  SELECT id INTO transaction_id FROM public.loyalty_transactions WHERE idempotency_key = key_value;
  IF transaction_id IS NOT NULL THEN RETURN transaction_id; END IF;
  SELECT loyalty_points_balance INTO current_balance FROM public.customers WHERE id = p_customer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Customer was not found.'; END IF;
  IF current_balance + p_points < 0 THEN RAISE EXCEPTION 'This loyalty change would make the customer balance negative.'; END IF;
  PERFORM set_config('app.loyalty_balance_mutation', 'on', true);
  UPDATE public.customers SET loyalty_points_balance = current_balance + p_points, updated_at = now() WHERE id = p_customer_id;
  INSERT INTO public.loyalty_transactions(id,customer_id,order_id,redemption_id,points,reason,idempotency_key,created_by_user_id)
  VALUES(gen_random_uuid(),p_customer_id,p_order_id,p_redemption_id,p_points,trim(p_reason),key_value,p_created_by_user_id)
  RETURNING id INTO transaction_id;
  RETURN transaction_id;
END; $$;
REVOKE ALL ON FUNCTION public.apply_loyalty_delta(uuid,integer,text,uuid,uuid,text,uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.calculate_order_loyalty_points(p_order_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT coalesce(sum(floor(ol.quantity * coalesce(nullif(p.loyalty_points_per_unit,0), s.global_rate)))::integer, 0)
  FROM public.order_lines ol
  JOIN public.products p ON p.id = ol.product_id
  CROSS JOIN LATERAL (SELECT coalesce((SELECT (value_json->>'points_per_unit')::integer FROM public.settings WHERE key='loyalty_points_per_unit'),0) AS global_rate) s
  WHERE ol.order_id = p_order_id AND NOT ol.is_free_item;
$$;
REVOKE ALL ON FUNCTION public.calculate_order_loyalty_points(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.calculate_order_loyalty_points(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.accrue_order_loyalty(p_order_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE order_customer uuid; points_value integer; transaction_id uuid;
BEGIN
  SELECT customer_id INTO order_customer FROM public.orders WHERE id=p_order_id AND status='DELIVERED' FOR UPDATE;
  IF NOT FOUND THEN RETURN 0; END IF;
  points_value := public.calculate_order_loyalty_points(p_order_id);
  IF points_value <= 0 THEN RETURN 0; END IF;
  SELECT public.apply_loyalty_delta(order_customer,points_value,'ORDER_DELIVERED',p_order_id,NULL,'order:'||p_order_id::text||':delivered',NULL) INTO transaction_id;
  UPDATE public.orders SET points_earned=points_value WHERE id=p_order_id;
  RETURN points_value;
END; $$;
REVOKE ALL ON FUNCTION public.accrue_order_loyalty(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.reverse_order_loyalty(p_order_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE order_customer uuid; earned_points integer; transaction_id uuid;
BEGIN
  SELECT customer_id INTO order_customer FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 0; END IF;
  SELECT points INTO earned_points FROM public.loyalty_transactions WHERE idempotency_key='order:'||p_order_id::text||':delivered';
  IF earned_points IS NULL OR earned_points <= 0 THEN RETURN 0; END IF;
  SELECT public.apply_loyalty_delta(order_customer,-earned_points,'ORDER_DELIVERED_REVERSED',p_order_id,NULL,'order:'||p_order_id::text||':reversed',NULL) INTO transaction_id;
  UPDATE public.orders SET points_earned=0 WHERE id=p_order_id;
  RETURN earned_points;
END; $$;
REVOKE ALL ON FUNCTION public.reverse_order_loyalty(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.orders_loyalty_status_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status AND NEW.status='DELIVERED' THEN PERFORM public.accrue_order_loyalty(NEW.id); END IF;
  IF OLD.status IS DISTINCT FROM NEW.status AND OLD.status='DELIVERED' AND NEW.status='CANCELLED' THEN PERFORM public.reverse_order_loyalty(NEW.id); END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS orders_loyalty_status_trigger ON public.orders;
CREATE TRIGGER orders_loyalty_status_trigger AFTER UPDATE OF status ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.orders_loyalty_status_trigger();

DROP POLICY IF EXISTS loyalty_transactions_business_manage ON public.loyalty_transactions;
DROP POLICY IF EXISTS loyalty_transactions_business_read ON public.loyalty_transactions;
DROP POLICY IF EXISTS loyalty_transactions_loyalty_read ON public.loyalty_transactions;
CREATE POLICY loyalty_transactions_loyalty_read ON public.loyalty_transactions FOR SELECT TO authenticated
USING ((public.has_permission(auth.uid(),'loyalty.view') OR public.has_permission(auth.uid(),'customer.view')) AND EXISTS (
  SELECT 1 FROM public.customers c WHERE c.id=customer_id AND (public.role_scope(auth.uid())='GLOBAL' OR c.assigned_agent_id IN (SELECT public.accessible_agent_ids(auth.uid())) OR EXISTS (SELECT 1 FROM public.customer_users cu WHERE cu.customer_id=c.id AND cu.user_id=auth.uid()))
));

DROP POLICY IF EXISTS rewards_business_read ON public.rewards;
DROP POLICY IF EXISTS rewards_business_manage ON public.rewards;
DROP POLICY IF EXISTS rewards_admin_manage ON public.rewards;
DROP POLICY IF EXISTS rewards_vendor_read ON public.rewards;
CREATE POLICY rewards_admin_manage ON public.rewards FOR ALL TO authenticated
USING (public.has_permission(auth.uid(),'reward.manage')) WITH CHECK (public.has_permission(auth.uid(),'reward.manage'));
CREATE POLICY rewards_vendor_read ON public.rewards FOR SELECT TO authenticated
USING (public.has_permission(auth.uid(),'loyalty.view') AND is_active AND (starts_at IS NULL OR starts_at <= now()) AND (ends_at IS NULL OR ends_at >= now()));

DROP POLICY IF EXISTS redemptions_business_read ON public.redemptions;
DROP POLICY IF EXISTS redemptions_business_manage ON public.redemptions;
DROP POLICY IF EXISTS redemptions_read_scoped ON public.redemptions;
DROP POLICY IF EXISTS redemptions_vendor_request ON public.redemptions;
DROP POLICY IF EXISTS redemptions_admin_update ON public.redemptions;
CREATE POLICY redemptions_read_scoped ON public.redemptions FOR SELECT TO authenticated
USING ((public.has_permission(auth.uid(),'redemption.approve') OR public.has_permission(auth.uid(),'customer.view') OR public.has_permission(auth.uid(),'loyalty.view')) AND EXISTS (
  SELECT 1 FROM public.customers c WHERE c.id=customer_id AND (public.has_permission(auth.uid(),'redemption.approve') OR public.role_scope(auth.uid())='GLOBAL' OR c.assigned_agent_id IN (SELECT public.accessible_agent_ids(auth.uid())) OR EXISTS (SELECT 1 FROM public.customer_users cu WHERE cu.customer_id=c.id AND cu.user_id=auth.uid()))
));
CREATE POLICY redemptions_vendor_request ON public.redemptions FOR INSERT TO authenticated
WITH CHECK (public.has_permission(auth.uid(),'redemption.request') AND status='REQUESTED' AND EXISTS (SELECT 1 FROM public.customer_users cu WHERE cu.customer_id=customer_id AND cu.user_id=auth.uid()));
CREATE POLICY redemptions_admin_update ON public.redemptions FOR UPDATE TO authenticated
USING (public.has_permission(auth.uid(),'redemption.approve')) WITH CHECK (public.has_permission(auth.uid(),'redemption.approve'));

CREATE OR REPLACE FUNCTION public.create_reward(p_payload jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE reward_id uuid := gen_random_uuid();
BEGIN
  IF NOT public.has_permission(auth.uid(),'reward.manage') THEN RAISE EXCEPTION 'Reward management is not permitted.'; END IF;
  IF nullif(trim(p_payload->>'nameEn'),'') IS NULL OR nullif(trim(p_payload->>'nameUr'),'') IS NULL OR coalesce((p_payload->>'pointsCost')::integer,0) <= 0 THEN RAISE EXCEPTION 'English name, Urdu name, and positive points cost are required.'; END IF;
  INSERT INTO public.rewards(id,name_en,name_ur,description_en,description_ur,image_url,reward_type,points_cost,discount_value_pkr,discount_percent,free_product_id,free_product_quantity,stock_limit,is_active,starts_at,ends_at)
  VALUES(reward_id,trim(p_payload->>'nameEn'),trim(p_payload->>'nameUr'),nullif(trim(p_payload->>'descriptionEn'),''),nullif(trim(p_payload->>'descriptionUr'),''),nullif(trim(p_payload->>'imageUrl'),''),(p_payload->>'rewardType')::public."RewardType",(p_payload->>'pointsCost')::integer,nullif(p_payload->>'discountValuePKR','')::numeric,nullif(p_payload->>'discountPercent','')::numeric,nullif(p_payload->>'freeProductId','')::uuid,nullif(p_payload->>'freeProductQuantity','')::numeric,nullif(p_payload->>'stockLimit','')::integer,coalesce((p_payload->>'isActive')::boolean,true),nullif(p_payload->>'startsAt','')::timestamptz,nullif(p_payload->>'endsAt','')::timestamptz);
  INSERT INTO public.audit_logs(user_id,action,entity_type,entity_id,changes_json) VALUES(auth.uid(),'CREATE_REWARD','REWARD',reward_id::text,p_payload);
  RETURN reward_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.create_reward(jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.request_loyalty_redemption(p_reward_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE customer_id_value uuid; reward_row record; redemption_id uuid; current_points integer;
BEGIN
  IF NOT public.has_permission(auth.uid(),'redemption.request') THEN RAISE EXCEPTION 'Redemption requests are not permitted.'; END IF;
  SELECT customer_id INTO customer_id_value FROM public.customer_users WHERE user_id=auth.uid() LIMIT 1;
  IF customer_id_value IS NULL THEN RAISE EXCEPTION 'No vendor customer account is linked to this user.'; END IF;
  SELECT * INTO reward_row FROM public.rewards WHERE id=p_reward_id AND is_active AND (starts_at IS NULL OR starts_at <= now()) AND (ends_at IS NULL OR ends_at >= now()) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'This reward is not currently available.'; END IF;
  IF reward_row.stock_limit IS NOT NULL AND reward_row.redeemed_count >= reward_row.stock_limit THEN RAISE EXCEPTION 'This reward is out of stock.'; END IF;
  SELECT loyalty_points_balance INTO current_points FROM public.customers WHERE id=customer_id_value FOR UPDATE;
  IF current_points < reward_row.points_cost THEN RAISE EXCEPTION 'You do not have enough points for this reward.'; END IF;
  IF EXISTS (SELECT 1 FROM public.redemptions WHERE customer_id=customer_id_value AND reward_id=p_reward_id AND status IN ('REQUESTED','APPROVED')) THEN RAISE EXCEPTION 'This reward already has a pending request.'; END IF;
  INSERT INTO public.redemptions(id,customer_id,reward_id,points_spent,status,requested_at) VALUES(gen_random_uuid(),customer_id_value,p_reward_id,reward_row.points_cost,'REQUESTED',now()) RETURNING id INTO redemption_id;
  INSERT INTO public.notifications(user_id,type,title_en,title_ur,body,link_url)
  SELECT DISTINCT u.id,'LOYALTY_REDEMPTION_REQUEST','Redemption requested','درخواستِ انعام','A vendor has requested a loyalty reward.','/en/admin/rewards'
  FROM public.users u JOIN public.roles r ON r.id=u.role_id JOIN public.role_permissions rp ON rp.role_id=r.id JOIN public.permissions p ON p.id=rp.permission_id
  WHERE u.is_active AND p.key='redemption.approve';
  INSERT INTO public.notifications(user_id,type,title_en,title_ur,body,link_url)
  SELECT sa.user_id,'LOYALTY_REDEMPTION_REQUEST','Redemption requested','درخواستِ انعام','Your customer has requested a loyalty reward.','/en/sales/customers/'||customer_id_value::text FROM public.customers c JOIN public.sales_agents sa ON sa.id=c.assigned_agent_id WHERE c.id=customer_id_value;
  RETURN redemption_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.request_loyalty_redemption(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.approve_loyalty_redemption(p_redemption_id uuid,p_order_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE redemption_row record; reward_row record; product_row record; discount_value numeric(12,2) := 0; free_quantity numeric(12,3); transaction_id uuid;
BEGIN
  IF NOT public.has_permission(auth.uid(),'redemption.approve') THEN RAISE EXCEPTION 'Redemption approval is not permitted.'; END IF;
  SELECT * INTO redemption_row FROM public.redemptions WHERE id=p_redemption_id AND status='REQUESTED' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'This redemption is no longer pending.'; END IF;
  SELECT * INTO reward_row FROM public.rewards WHERE id=redemption_row.reward_id FOR UPDATE;
  IF reward_row.stock_limit IS NOT NULL AND reward_row.redeemed_count >= reward_row.stock_limit THEN RAISE EXCEPTION 'This reward has reached its stock limit.'; END IF;
  IF reward_row.reward_type IN ('DISCOUNT_AMOUNT','DISCOUNT_PERCENT','FREE_PRODUCT') AND p_order_id IS NULL THEN RAISE EXCEPTION 'A nominated order is required for this reward.'; END IF;
  IF p_order_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.orders WHERE id=p_order_id AND customer_id=redemption_row.customer_id AND status NOT IN ('CANCELLED','DELIVERED')) THEN RAISE EXCEPTION 'The nominated order is not eligible.'; END IF;
  SELECT public.apply_loyalty_delta(redemption_row.customer_id,-redemption_row.points_spent,'REDEMPTION_APPROVED',p_order_id,p_redemption_id,'redemption:'||p_redemption_id::text,auth.uid()) INTO transaction_id;
  IF reward_row.reward_type='DISCOUNT_AMOUNT' THEN
    discount_value := coalesce(reward_row.discount_value_pkr,0);
    UPDATE public.orders SET points_redeemed=points_redeemed+redemption_row.points_spent,points_discount_pkr=points_discount_pkr+discount_value,discount_pkr=discount_pkr+discount_value,total_pkr=greatest(total_pkr-discount_value,0) WHERE id=p_order_id;
  ELSIF reward_row.reward_type='DISCOUNT_PERCENT' THEN
    SELECT round(total_pkr * coalesce(reward_row.discount_percent,0) / 100,2) INTO discount_value FROM public.orders WHERE id=p_order_id;
    UPDATE public.orders SET points_redeemed=points_redeemed+redemption_row.points_spent,points_discount_pkr=points_discount_pkr+discount_value,discount_pkr=discount_pkr+discount_value,total_pkr=greatest(total_pkr-discount_value,0) WHERE id=p_order_id;
  ELSIF reward_row.reward_type='FREE_PRODUCT' THEN
    free_quantity := coalesce(reward_row.free_product_quantity,1);
    SELECT id,price_pkr,stock_quantity INTO product_row FROM public.products WHERE id=reward_row.free_product_id AND is_active FOR UPDATE;
    IF NOT FOUND OR product_row.stock_quantity < free_quantity THEN RAISE EXCEPTION 'The free product is unavailable.'; END IF;
    UPDATE public.products SET stock_quantity=stock_quantity-free_quantity WHERE id=product_row.id;
    INSERT INTO public.order_lines(id,order_id,product_id,quantity,unit_price_pkr,line_total_pkr,is_free_item,redemption_id) VALUES(gen_random_uuid(),p_order_id,product_row.id,free_quantity,0,0,true,p_redemption_id);
  END IF;
  UPDATE public.rewards SET redeemed_count=redeemed_count+1 WHERE id=reward_row.id;
  UPDATE public.redemptions SET status='APPROVED',approved_by_user_id=auth.uid(),order_id=coalesce(p_order_id,order_id),fulfilled_at=CASE WHEN reward_row.reward_type IN ('DISCOUNT_AMOUNT','DISCOUNT_PERCENT','FREE_PRODUCT') THEN now() ELSE fulfilled_at END WHERE id=p_redemption_id;
  INSERT INTO public.notifications(user_id,type,title_en,title_ur,body,link_url) SELECT cu.user_id,'LOYALTY_REDEMPTION_APPROVED','Reward approved','انعام منظور ہو گیا','Your loyalty reward request was approved.','/en/vendor/points' FROM public.customer_users cu WHERE cu.customer_id=redemption_row.customer_id;
  RETURN p_redemption_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.approve_loyalty_redemption(uuid,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.reject_loyalty_redemption(p_redemption_id uuid,p_reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE redemption_row record;
BEGIN
  IF NOT public.has_permission(auth.uid(),'redemption.approve') THEN RAISE EXCEPTION 'Redemption approval is not permitted.'; END IF;
  IF nullif(trim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'A rejection reason is required.'; END IF;
  SELECT * INTO redemption_row FROM public.redemptions WHERE id=p_redemption_id AND status='REQUESTED' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'This redemption is no longer pending.'; END IF;
  UPDATE public.redemptions SET status='REJECTED',approved_by_user_id=auth.uid(),rejected_reason=trim(p_reason) WHERE id=p_redemption_id;
  INSERT INTO public.notifications(user_id,type,title_en,title_ur,body,link_url)
  SELECT cu.user_id,'LOYALTY_REDEMPTION_REJECTED','Reward request declined','Reward request مسترد','Your loyalty reward request was declined.','/en/vendor/points' FROM public.customer_users cu WHERE cu.customer_id=redemption_row.customer_id;
  RETURN p_redemption_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.reject_loyalty_redemption(uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.adjust_loyalty_points(p_customer_id uuid,p_delta integer,p_reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE transaction_id uuid;
BEGIN
  IF NOT public.has_permission(auth.uid(),'loyalty.adjust') THEN RAISE EXCEPTION 'Loyalty adjustment is not permitted.'; END IF;
  IF nullif(trim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'A reason is required for a manual adjustment.'; END IF;
  SELECT public.apply_loyalty_delta(p_customer_id,p_delta,'MANUAL_ADJUSTMENT: '||trim(p_reason),NULL,NULL,'manual:'||gen_random_uuid()::text,auth.uid()) INTO transaction_id;
  INSERT INTO public.audit_logs(user_id,action,entity_type,entity_id,changes_json) VALUES(auth.uid(),'LOYALTY_ADJUSTMENT','CUSTOMER',p_customer_id::text,jsonb_build_object('delta',p_delta,'reason',trim(p_reason),'transaction_id',transaction_id));
  RETURN transaction_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.adjust_loyalty_points(uuid,integer,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.loyalty_liability_summary()
RETURNS TABLE(customers_with_points bigint,total_points bigint,value_per_point_pkr numeric(12,4),estimated_liability_pkr numeric(12,2)) LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
WITH value_rates AS (
  SELECT greatest(coalesce(max(discount_value_pkr / nullif(points_cost,0)) FILTER (WHERE reward_type='DISCOUNT_AMOUNT'),0),coalesce(max((discount_percent/100) * 1) FILTER (WHERE reward_type='DISCOUNT_PERCENT'),0),coalesce(max((p.price_pkr * r.free_product_quantity) / nullif(r.points_cost,0)) FILTER (WHERE reward_type='FREE_PRODUCT'),0))::numeric(12,4) AS rate
  FROM public.rewards r LEFT JOIN public.products p ON p.id=r.free_product_id
  WHERE r.is_active AND (r.starts_at IS NULL OR r.starts_at<=now()) AND (r.ends_at IS NULL OR r.ends_at>=now())
), balances AS (SELECT count(*)::bigint customers_with_points,coalesce(sum(loyalty_points_balance),0)::bigint total_points FROM public.customers WHERE loyalty_points_balance>0 AND is_internal_account=false)
SELECT b.customers_with_points,b.total_points,v.rate,(b.total_points*v.rate)::numeric(12,2) FROM balances b CROSS JOIN value_rates v WHERE public.has_permission(auth.uid(),'dashboard.view');
$$;
GRANT EXECUTE ON FUNCTION public.loyalty_liability_summary() TO authenticated;

CREATE OR REPLACE FUNCTION public.reconcile_loyalty_balances()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE row_data record; mismatch_count integer := 0;
BEGIN
  FOR row_data IN SELECT c.id,c.loyalty_points_balance,coalesce(sum(lt.points),0)::integer transaction_total FROM public.customers c LEFT JOIN public.loyalty_transactions lt ON lt.customer_id=c.id WHERE NOT c.is_internal_account GROUP BY c.id,c.loyalty_points_balance HAVING c.loyalty_points_balance <> coalesce(sum(lt.points),0)::integer LOOP
    mismatch_count := mismatch_count + 1;
    INSERT INTO public.admin_anomaly_alerts(alert_type,entity_id,title,body,supporting_metrics_json,status) VALUES('LOYALTY_BALANCE_MISMATCH',row_data.id,'Loyalty balance mismatch','Customer loyalty balance does not match its transaction sum.',jsonb_build_object('cached_balance',row_data.loyalty_points_balance,'transaction_total',row_data.transaction_total),'OPEN');
  END LOOP;
  RETURN mismatch_count;
END; $$;
REVOKE ALL ON FUNCTION public.reconcile_loyalty_balances() FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.redemption_popularity()
RETURNS TABLE(reward_id uuid,reward_name_en text,reward_name_ur text,request_count bigint,approved_count bigint) LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
SELECT r.id,r.name_en,r.name_ur,count(red.id)::bigint,count(red.id) FILTER (WHERE red.status IN ('APPROVED','FULFILLED'))::bigint FROM public.rewards r LEFT JOIN public.redemptions red ON red.reward_id=r.id WHERE public.has_permission(auth.uid(),'reward.manage') GROUP BY r.id,r.name_en,r.name_ur ORDER BY count(red.id) DESC;
$$;
GRANT EXECUTE ON FUNCTION public.redemption_popularity() TO authenticated;

CREATE INDEX IF NOT EXISTS orders_customer_status_delivered_idx ON public.orders(customer_id,status,delivered_at);
CREATE INDEX IF NOT EXISTS products_loyalty_points_active_idx ON public.products(is_active,loyalty_points_per_unit);
CREATE INDEX IF NOT EXISTS customers_loyalty_positive_idx ON public.customers(loyalty_points_balance) WHERE loyalty_points_balance > 0;
