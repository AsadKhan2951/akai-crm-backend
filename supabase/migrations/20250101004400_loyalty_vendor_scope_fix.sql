-- AKAI CRM Phase 19 corrective migration.
-- 0043 is applied and remains immutable. This adds a vendor_accounts fallback
-- without removing the existing customer_users compatibility linkage.

DROP POLICY IF EXISTS loyalty_transactions_loyalty_read ON public.loyalty_transactions;
CREATE POLICY loyalty_transactions_loyalty_read ON public.loyalty_transactions FOR SELECT TO authenticated
USING ((public.has_permission(auth.uid(),'loyalty.view') OR public.has_permission(auth.uid(),'customer.view')) AND EXISTS (
  SELECT 1 FROM public.customers c WHERE c.id=customer_id AND (public.role_scope(auth.uid())='GLOBAL' OR c.assigned_agent_id IN (SELECT public.accessible_agent_ids(auth.uid())) OR EXISTS (SELECT 1 FROM public.customer_users cu WHERE cu.customer_id=c.id AND cu.user_id=auth.uid()) OR EXISTS (SELECT 1 FROM public.vendor_accounts va WHERE va.customer_id=c.id AND va.user_id=auth.uid()))
));

DROP POLICY IF EXISTS redemptions_read_scoped ON public.redemptions;
CREATE POLICY redemptions_read_scoped ON public.redemptions FOR SELECT TO authenticated
USING ((public.has_permission(auth.uid(),'redemption.approve') OR public.has_permission(auth.uid(),'customer.view') OR public.has_permission(auth.uid(),'loyalty.view')) AND EXISTS (
  SELECT 1 FROM public.customers c WHERE c.id=customer_id AND (public.has_permission(auth.uid(),'redemption.approve') OR public.role_scope(auth.uid())='GLOBAL' OR c.assigned_agent_id IN (SELECT public.accessible_agent_ids(auth.uid())) OR EXISTS (SELECT 1 FROM public.customer_users cu WHERE cu.customer_id=c.id AND cu.user_id=auth.uid()) OR EXISTS (SELECT 1 FROM public.vendor_accounts va WHERE va.customer_id=c.id AND va.user_id=auth.uid()))
));

DROP POLICY IF EXISTS redemptions_vendor_request ON public.redemptions;
CREATE POLICY redemptions_vendor_request ON public.redemptions FOR INSERT TO authenticated
WITH CHECK (public.has_permission(auth.uid(),'redemption.request') AND status='REQUESTED' AND (EXISTS (SELECT 1 FROM public.customer_users cu WHERE cu.customer_id=customer_id AND cu.user_id=auth.uid()) OR EXISTS (SELECT 1 FROM public.vendor_accounts va WHERE va.customer_id=customer_id AND va.user_id=auth.uid())));

CREATE OR REPLACE FUNCTION public.request_loyalty_redemption(p_reward_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE customer_id_value uuid; reward_row record; redemption_id uuid; current_points integer;
BEGIN
  IF NOT public.has_permission(auth.uid(),'redemption.request') THEN RAISE EXCEPTION 'Redemption requests are not permitted.'; END IF;
  SELECT linked.customer_id INTO customer_id_value FROM (
    SELECT cu.customer_id FROM public.customer_users cu WHERE cu.user_id=auth.uid()
    UNION ALL
    SELECT va.customer_id FROM public.vendor_accounts va WHERE va.user_id=auth.uid()
  ) linked LIMIT 1;
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

CREATE INDEX IF NOT EXISTS vendor_accounts_user_customer_idx ON public.vendor_accounts(user_id, customer_id);
