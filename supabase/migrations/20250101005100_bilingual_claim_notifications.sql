-- AKAI CRM Phase 20 notification locale hardening. Additive only.
ALTER TABLE public.notifications ADD COLUMN IF NOT EXISTS body_en text;
ALTER TABLE public.notifications ADD COLUMN IF NOT EXISTS body_ur text;

CREATE OR REPLACE FUNCTION public.notify_claim_status_change() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE vendor_user record; status_label_en text:=replace(NEW.status::text,'_',' '); status_label_ur text:=CASE NEW.status::text WHEN 'SUBMITTED' THEN 'درج شدہ' WHEN 'UNDER_REVIEW' THEN 'جائزے میں' WHEN 'APPROVED' THEN 'منظور شدہ' WHEN 'REJECTED' THEN 'مسترد شدہ' WHEN 'RESOLVED' THEN 'حل شدہ' ELSE replace(NEW.status::text,'_',' ') END;
BEGIN
  IF TG_OP <> 'UPDATE' OR OLD.status IS NOT DISTINCT FROM NEW.status THEN RETURN NEW; END IF;
  FOR vendor_user IN SELECT cu.user_id FROM public.customer_users cu WHERE cu.customer_id=NEW.customer_id LOOP
    INSERT INTO public.notifications(user_id,type,title_en,title_ur,body,body_en,body_ur,link_url) VALUES(vendor_user.user_id,'CLAIM_STATUS','Claim status updated','دعویٰ کی حیثیت تبدیل ہو گئی','Claim '||NEW.claim_number||' is now '||status_label_en||'.','Claim '||NEW.claim_number||' is now '||status_label_en||'.','Claim '||NEW.claim_number||' اب '||status_label_ur||' ہے۔','/vendor/claims/'||NEW.id::text);
  END LOOP;
  RETURN NEW;
END; $$;
