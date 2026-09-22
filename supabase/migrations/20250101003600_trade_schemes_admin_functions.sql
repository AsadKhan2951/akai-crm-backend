-- AKAI CRM Phase 17 Admin scheme builder functions.
-- Scheme configuration with budget fields is saved atomically; no partial tier rows.

CREATE OR REPLACE FUNCTION public.create_trade_scheme(p_payload jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public
AS $$
DECLARE
  actor uuid := auth.uid();
  scheme_id uuid;
  tier jsonb;
  audience jsonb;
BEGIN
  IF NOT public.has_permission(actor, 'scheme.create') THEN
    RAISE EXCEPTION 'scheme.create permission is required';
  END IF;
  IF nullif(trim(p_payload->>'nameEn'), '') IS NULL OR nullif(trim(p_payload->>'nameUr'), '') IS NULL THEN
    RAISE EXCEPTION 'English and Urdu scheme names are required';
  END IF;
  IF (p_payload->>'startsAt')::timestamptz >= (p_payload->>'endsAt')::timestamptz THEN
    RAISE EXCEPTION 'Scheme end time must be after start time';
  END IF;
  INSERT INTO public.schemes (
    name_en, name_ur, description_en, description_ur, scheme_type, scope_type, scope_ids,
    audience_type, priority, is_stackable, starts_at, ends_at, budget_pkr,
    max_redemptions_per_vendor, terms_en, terms_ur, banner_image_url, created_by_user_id
  ) VALUES (
    trim(p_payload->>'nameEn'), trim(p_payload->>'nameUr'), nullif(trim(p_payload->>'descriptionEn'), ''), nullif(trim(p_payload->>'descriptionUr'), ''),
    (p_payload->>'schemeType')::"SchemeType", (p_payload->>'scopeType')::"SchemeScopeType",
    ARRAY(SELECT jsonb_array_elements_text(coalesce(p_payload->'scopeIds', '[]'::jsonb))),
    (p_payload->>'audienceType')::"SchemeAudienceType", coalesce((p_payload->>'priority')::integer, 100),
    coalesce((p_payload->>'isStackable')::boolean, false), (p_payload->>'startsAt')::timestamptz,
    (p_payload->>'endsAt')::timestamptz, nullif(p_payload->>'budgetPKR', '')::numeric(12,2),
    nullif(p_payload->>'maxRedemptionsPerVendor', '')::integer, trim(p_payload->>'termsEn'), trim(p_payload->>'termsUr'),
    nullif(trim(p_payload->>'bannerImageUrl'), ''), actor
  ) RETURNING id INTO scheme_id;

  FOR tier IN SELECT * FROM jsonb_array_elements(coalesce(p_payload->'tiers', '[]'::jsonb)) LOOP
    INSERT INTO public.scheme_tiers (scheme_id, min_quantity, min_value_pkr, free_product_id, free_quantity, discount_percent, discount_amount_pkr, display_order)
    VALUES (
      scheme_id, nullif(tier->>'minQuantity', '')::numeric(12,3), nullif(tier->>'minValuePKR', '')::numeric(12,2),
      nullif(tier->>'freeProductId', '')::uuid, nullif(tier->>'freeQuantity', '')::numeric(12,3),
      nullif(tier->>'discountPercent', '')::numeric(5,2), nullif(tier->>'discountAmountPKR', '')::numeric(12,2),
      coalesce((tier->>'displayOrder')::integer, 0)
    );
  END LOOP;

  FOR audience IN SELECT * FROM jsonb_array_elements(coalesce(p_payload->'audiences', '[]'::jsonb)) LOOP
    INSERT INTO public.scheme_audiences (scheme_id, vendor_group_id, customer_id)
    VALUES (scheme_id, nullif(audience->>'vendorGroupId', '')::uuid, nullif(audience->>'customerId', '')::uuid);
  END LOOP;
  RETURN scheme_id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_trade_scheme(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_trade_scheme(jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.activate_trade_scheme(p_scheme_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public
AS $$
BEGIN
  IF NOT public.has_permission(auth.uid(), 'scheme.activate') THEN
    RAISE EXCEPTION 'scheme.activate permission is required';
  END IF;
  UPDATE public.schemes SET is_active = true WHERE id = p_scheme_id AND ends_at > starts_at;
  RETURN FOUND;
END;
$$;
REVOKE ALL ON FUNCTION public.activate_trade_scheme(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.activate_trade_scheme(uuid) TO authenticated;
