-- AKAI CRM Phase 21: Territory beat planning and journey execution.
-- Additive only. Applied migrations are never edited.

DO $$
BEGIN
  CREATE TYPE "BeatVisitStatus" AS ENUM ('PLANNED', 'VISITED', 'SKIPPED', 'RESCHEDULED');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS public.beats (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  agent_id uuid NOT NULL REFERENCES public.sales_agents(id) ON DELETE RESTRICT,
  day_of_week smallint NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  area_codes text[] NOT NULL DEFAULT '{}',
  target_frequency_days integer NOT NULL DEFAULT 30 CHECK (target_frequency_days > 0),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.beat_customers (
  beat_id uuid NOT NULL REFERENCES public.beats(id) ON DELETE CASCADE,
  customer_id uuid NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  sequence integer NOT NULL CHECK (sequence > 0),
  assigned_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (beat_id, customer_id)
);

CREATE TABLE IF NOT EXISTS public.beat_frequency_targets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  beat_id uuid NOT NULL REFERENCES public.beats(id) ON DELETE CASCADE,
  customer_type "CustomerType",
  vendor_group_id uuid REFERENCES public.vendor_groups(id) ON DELETE CASCADE,
  frequency_days integer NOT NULL CHECK (frequency_days > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT beat_frequency_target_scope_check CHECK (customer_type IS NOT NULL OR vendor_group_id IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS public.beat_visits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  beat_id uuid NOT NULL REFERENCES public.beats(id) ON DELETE CASCADE,
  agent_id uuid NOT NULL REFERENCES public.sales_agents(id) ON DELETE RESTRICT,
  customer_id uuid NOT NULL REFERENCES public.customers(id) ON DELETE RESTRICT,
  planned_date date NOT NULL,
  status "BeatVisitStatus" NOT NULL DEFAULT 'PLANNED',
  activity_id uuid REFERENCES public.activities(id) ON DELETE SET NULL,
  skip_reason text,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT beat_visit_skip_reason_check CHECK (status <> 'SKIPPED' OR length(trim(coalesce(skip_reason, ''))) > 0),
  CONSTRAINT beat_visit_completed_check CHECK (status NOT IN ('VISITED', 'SKIPPED') OR completed_at IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS beat_visits_one_customer_per_day_idx
  ON public.beat_visits (agent_id, customer_id, planned_date)
  WHERE status <> 'SKIPPED';
CREATE INDEX IF NOT EXISTS beats_agent_day_active_idx
  ON public.beats (agent_id, day_of_week, is_active);
CREATE INDEX IF NOT EXISTS beats_area_codes_gin_idx
  ON public.beats USING gin (area_codes);
CREATE INDEX IF NOT EXISTS beat_customers_customer_idx
  ON public.beat_customers (customer_id, beat_id);
CREATE INDEX IF NOT EXISTS beat_customers_sequence_idx
  ON public.beat_customers (beat_id, sequence);
CREATE INDEX IF NOT EXISTS beat_frequency_targets_scope_idx
  ON public.beat_frequency_targets (beat_id, customer_type, vendor_group_id);
CREATE INDEX IF NOT EXISTS beat_visits_agent_date_status_idx
  ON public.beat_visits (agent_id, planned_date, status);
CREATE INDEX IF NOT EXISTS beat_visits_beat_date_sequence_idx
  ON public.beat_visits (beat_id, planned_date, status, customer_id);
CREATE INDEX IF NOT EXISTS beat_visits_customer_date_idx
  ON public.beat_visits (customer_id, planned_date DESC);
CREATE UNIQUE INDEX IF NOT EXISTS beat_visits_activity_unique_idx
  ON public.beat_visits (activity_id)
  WHERE activity_id IS NOT NULL;

ALTER TABLE public.beats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.beat_customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.beat_frequency_targets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.beat_visits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS beats_select ON public.beats;
CREATE POLICY beats_select ON public.beats FOR SELECT TO authenticated USING (
  public.has_permission(auth.uid(), 'beat.view')
  AND agent_id IN (SELECT public.accessible_agent_ids(auth.uid()))
);
DROP POLICY IF EXISTS beats_manage ON public.beats;
CREATE POLICY beats_manage ON public.beats FOR ALL TO authenticated USING (
  public.has_permission(auth.uid(), 'beat.manage')
) WITH CHECK (public.has_permission(auth.uid(), 'beat.manage'));

DROP POLICY IF EXISTS beat_customers_select ON public.beat_customers;
CREATE POLICY beat_customers_select ON public.beat_customers FOR SELECT TO authenticated USING (
  public.has_permission(auth.uid(), 'beat.view')
  AND
  EXISTS (SELECT 1 FROM public.beats b WHERE b.id = beat_customers.beat_id)
  AND EXISTS (SELECT 1 FROM public.customers c WHERE c.id = beat_customers.customer_id)
);
DROP POLICY IF EXISTS beat_customers_manage ON public.beat_customers;
CREATE POLICY beat_customers_manage ON public.beat_customers FOR ALL TO authenticated USING (
  public.has_permission(auth.uid(), 'beat.manage')
) WITH CHECK (public.has_permission(auth.uid(), 'beat.manage'));

DROP POLICY IF EXISTS beat_frequency_targets_select ON public.beat_frequency_targets;
CREATE POLICY beat_frequency_targets_select ON public.beat_frequency_targets FOR SELECT TO authenticated USING (
  public.has_permission(auth.uid(), 'beat.view')
  AND
  EXISTS (SELECT 1 FROM public.beats b WHERE b.id = beat_frequency_targets.beat_id)
);
DROP POLICY IF EXISTS beat_frequency_targets_manage ON public.beat_frequency_targets;
CREATE POLICY beat_frequency_targets_manage ON public.beat_frequency_targets FOR ALL TO authenticated USING (
  public.has_permission(auth.uid(), 'beat.manage')
) WITH CHECK (public.has_permission(auth.uid(), 'beat.manage'));

DROP POLICY IF EXISTS beat_visits_select ON public.beat_visits;
CREATE POLICY beat_visits_select ON public.beat_visits FOR SELECT TO authenticated USING (
  public.has_permission(auth.uid(), 'beat.view')
  AND agent_id IN (SELECT public.accessible_agent_ids(auth.uid()))
);
DROP POLICY IF EXISTS beat_visits_update ON public.beat_visits;
CREATE POLICY beat_visits_update ON public.beat_visits FOR UPDATE TO authenticated USING (
  public.has_permission(auth.uid(), 'beat.visit')
  AND agent_id IN (SELECT public.accessible_agent_ids(auth.uid()))
) WITH CHECK (agent_id IN (SELECT public.accessible_agent_ids(auth.uid())));
DROP POLICY IF EXISTS beat_visits_manage_insert ON public.beat_visits;
CREATE POLICY beat_visits_manage_insert ON public.beat_visits FOR INSERT TO authenticated WITH CHECK (
  public.has_permission(auth.uid(), 'beat.manage')
);
DROP POLICY IF EXISTS beat_visits_agent_insert ON public.beat_visits;
CREATE POLICY beat_visits_agent_insert ON public.beat_visits FOR INSERT TO authenticated WITH CHECK (
  public.has_permission(auth.uid(), 'beat.visit')
  AND agent_id IN (SELECT public.accessible_agent_ids(auth.uid()))
);

CREATE OR REPLACE FUNCTION public.create_beat_from_areas(
  p_name text,
  p_agent_id uuid,
  p_day_of_week smallint,
  p_area_codes text[] DEFAULT '{}',
  p_target_frequency_days integer DEFAULT 30
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_beat_id uuid;
BEGIN
  IF NOT public.has_permission(auth.uid(), 'beat.manage') THEN
    RAISE EXCEPTION USING errcode = '42501', message = 'Beat management is not permitted.';
  END IF;
  IF p_name IS NULL OR length(trim(p_name)) < 2 THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'Enter a beat name.';
  END IF;
  IF p_day_of_week NOT BETWEEN 0 AND 6 THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'Choose a valid day of week.';
  END IF;
  IF p_target_frequency_days IS NULL OR p_target_frequency_days < 1 THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'Target frequency must be at least one day.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sales_agents sa WHERE sa.id = p_agent_id) THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'Sales Agent does not exist.';
  END IF;
  INSERT INTO public.beats(name, agent_id, day_of_week, area_codes, target_frequency_days)
  VALUES (trim(p_name), p_agent_id, p_day_of_week, coalesce(p_area_codes, '{}'), p_target_frequency_days)
  RETURNING id INTO v_beat_id;

  INSERT INTO public.beat_customers(beat_id, customer_id, sequence)
  SELECT v_beat_id, c.id,
         row_number() OVER (ORDER BY c.area_code, c.normalized_name, c.id)::integer
  FROM public.customers c
  WHERE c.assigned_agent_id = p_agent_id
    AND c.is_internal_account = false
    AND (coalesce(array_length(p_area_codes, 1), 0) = 0 OR c.area_code = ANY(p_area_codes))
  ON CONFLICT (beat_id, customer_id) DO NOTHING;
  RETURN v_beat_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.materialize_beat_visits(
  p_beat_id uuid,
  p_planned_date date DEFAULT (timezone('Asia/Karachi', now()))::date
)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_inserted integer;
  v_beat public.beats%ROWTYPE;
BEGIN
  IF NOT public.has_permission(auth.uid(), 'beat.manage') THEN
    RAISE EXCEPTION USING errcode = '42501', message = 'Beat management is not permitted.';
  END IF;
  SELECT * INTO v_beat FROM public.beats WHERE id = p_beat_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING errcode = '22023', message = 'Beat not found.'; END IF;
  IF NOT v_beat.is_active THEN RAISE EXCEPTION USING errcode = '22023', message = 'Cannot plan an inactive beat.'; END IF;

  INSERT INTO public.beat_visits(beat_id, agent_id, customer_id, planned_date, status)
  SELECT bc.beat_id, v_beat.agent_id, bc.customer_id, p_planned_date, 'PLANNED'
  FROM public.beat_customers bc
  JOIN public.customers c ON c.id = bc.customer_id
  WHERE bc.beat_id = p_beat_id
    AND NOT EXISTS (
      SELECT 1
      FROM public.beat_visits previous_visit
      WHERE previous_visit.customer_id = bc.customer_id
        AND previous_visit.status = 'VISITED'
        AND previous_visit.planned_date >= p_planned_date - COALESCE((
          SELECT min(target.frequency_days)
          FROM public.beat_frequency_targets target
          WHERE target.beat_id = p_beat_id
            AND (target.customer_type = c.customer_type OR target.vendor_group_id = c.vendor_group_id)
        ), v_beat.target_frequency_days)
    )
  ON CONFLICT (agent_id, customer_id, planned_date) WHERE (status <> 'SKIPPED') DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RETURN v_inserted;
END;
$$;

CREATE OR REPLACE FUNCTION public.sales_today_beat(
  p_planned_date date DEFAULT (timezone('Asia/Karachi', now()))::date
)
RETURNS TABLE (
  visit_id uuid,
  beat_id uuid,
  beat_name text,
  sequence integer,
  customer_id uuid,
  business_name text,
  area_code text,
  full_address text,
  primary_phone text,
  latitude numeric,
  longitude numeric,
  planned_date date,
  visit_status "BeatVisitStatus",
  skip_reason text,
  last_visit_at timestamptz,
  last_order_at timestamptz,
  outstanding_balance_pkr numeric,
  open_followups bigint
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE v_agent_id uuid;
BEGIN
  IF NOT public.has_permission(auth.uid(), 'beat.view') THEN
    RAISE EXCEPTION USING errcode = '42501', message = 'Beat viewing is not permitted.';
  END IF;
  SELECT sa.id INTO v_agent_id FROM public.sales_agents sa WHERE sa.user_id = auth.uid();
  RETURN QUERY
  SELECT bv.id, b.id, b.name, bc.sequence, c.id, c.business_name, c.area_code, c.full_address,
         c.primary_phone, c.latitude, c.longitude, bv.planned_date, bv.status, bv.skip_reason,
         (SELECT max(a.occurred_at) FROM public.activities a WHERE a.customer_id = c.id AND a.agent_id = v_agent_id AND a.type = 'VISIT'),
         (SELECT max(o.created_at) FROM public.orders o WHERE o.customer_id = c.id AND o.status <> 'CANCELLED'),
         CASE WHEN public.has_permission(auth.uid(), 'collection.view') THEN c.current_balance_pkr ELSE NULL END,
         (SELECT count(*) FROM public.follow_ups f WHERE f.customer_id = c.id AND f.agent_id = v_agent_id AND f.is_completed = false)
  FROM public.beat_visits bv
  JOIN public.beats b ON b.id = bv.beat_id
  JOIN public.beat_customers bc ON bc.beat_id = bv.beat_id AND bc.customer_id = bv.customer_id
  JOIN public.customers c ON c.id = bv.customer_id
  WHERE bv.agent_id = v_agent_id
    AND bv.planned_date = p_planned_date
  ORDER BY b.name, bc.sequence, c.business_name;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_beat_visit(
  p_visit_id uuid,
  p_status "BeatVisitStatus",
  p_disposition "ActivityDisposition" DEFAULT 'CONNECTED',
  p_notes text DEFAULT '',
  p_latitude numeric DEFAULT null,
  p_longitude numeric DEFAULT null,
  p_accuracy_meters numeric DEFAULT null,
  p_skip_reason text DEFAULT null
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_visit public.beat_visits%ROWTYPE;
  v_activity_id uuid;
  v_agent_id uuid;
BEGIN
  IF NOT public.has_permission(auth.uid(), 'beat.visit') THEN
    RAISE EXCEPTION USING errcode = '42501', message = 'Beat visit updates are not permitted.';
  END IF;
  SELECT sa.id INTO v_agent_id FROM public.sales_agents sa WHERE sa.user_id = auth.uid();
  SELECT * INTO v_visit FROM public.beat_visits WHERE id = p_visit_id AND agent_id = v_agent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING errcode = '42501', message = 'This beat visit is outside your scope.'; END IF;
  IF v_visit.status IN ('VISITED', 'SKIPPED') THEN
    RAISE EXCEPTION USING errcode = '23505', message = 'This beat visit has already been completed.';
  END IF;
  IF p_status = 'SKIPPED' THEN
    IF p_skip_reason IS NULL OR length(trim(p_skip_reason)) = 0 THEN
      RAISE EXCEPTION USING errcode = '22023', message = 'Give a reason before skipping a visit.';
    END IF;
    UPDATE public.beat_visits SET status = 'SKIPPED', skip_reason = trim(p_skip_reason), completed_at = now(), updated_at = now() WHERE id = p_visit_id;
    RETURN null;
  END IF;
  IF p_status <> 'VISITED' THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'Use a separate reschedule action for a missed visit.';
  END IF;
  v_activity_id := public.log_sales_activity(
    'VISIT', v_visit.customer_id, null, p_disposition, coalesce(p_notes, ''), now(),
    p_latitude, p_longitude, p_accuracy_meters, null, null, 'MEDIUM'
  );
  UPDATE public.beat_visits
  SET status = 'VISITED', activity_id = v_activity_id, completed_at = now(), updated_at = now()
  WHERE id = p_visit_id;
  RETURN v_activity_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.reschedule_beat_visit(
  p_visit_id uuid,
  p_new_date date,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE v_visit public.beat_visits%ROWTYPE; v_agent_id uuid;
BEGIN
  IF NOT public.has_permission(auth.uid(), 'beat.visit') THEN
    RAISE EXCEPTION USING errcode = '42501', message = 'Beat visit updates are not permitted.';
  END IF;
  IF p_new_date <= (timezone('Asia/Karachi', now()))::date THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'Choose a future beat date.';
  END IF;
  IF length(trim(coalesce(p_reason, ''))) = 0 THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'Give a reason before rescheduling.';
  END IF;
  SELECT sa.id INTO v_agent_id FROM public.sales_agents sa WHERE sa.user_id = auth.uid();
  SELECT * INTO v_visit FROM public.beat_visits WHERE id = p_visit_id AND agent_id = v_agent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING errcode = '42501', message = 'This beat visit is outside your scope.'; END IF;
  UPDATE public.beat_visits SET status = 'RESCHEDULED', skip_reason = trim(p_reason), updated_at = now() WHERE id = p_visit_id;
  INSERT INTO public.beat_visits(beat_id, agent_id, customer_id, planned_date, status, skip_reason)
  VALUES (v_visit.beat_id, v_visit.agent_id, v_visit.customer_id, p_new_date, 'RESCHEDULED', trim(p_reason))
  ON CONFLICT (agent_id, customer_id, planned_date) WHERE (status <> 'SKIPPED') DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION public.beat_coverage_summary()
RETURNS TABLE (agent_id uuid, agent_name text, assigned_customers bigint, on_a_beat bigint, not_on_a_beat bigint, coverage_percent numeric)
LANGUAGE sql SECURITY INVOKER SET search_path = public AS $$
  SELECT sa.id, u.full_name,
         count(c.id) FILTER (WHERE c.is_internal_account = false),
         count(c.id) FILTER (WHERE c.is_internal_account = false AND EXISTS (SELECT 1 FROM public.beat_customers bc JOIN public.beats b ON b.id = bc.beat_id WHERE bc.customer_id = c.id AND b.agent_id = sa.id AND b.is_active)),
         count(c.id) FILTER (WHERE c.is_internal_account = false AND NOT EXISTS (SELECT 1 FROM public.beat_customers bc JOIN public.beats b ON b.id = bc.beat_id WHERE bc.customer_id = c.id AND b.agent_id = sa.id AND b.is_active)),
         coalesce(round(100.0 * count(c.id) FILTER (WHERE c.is_internal_account = false AND EXISTS (SELECT 1 FROM public.beat_customers bc JOIN public.beats b ON b.id = bc.beat_id WHERE bc.customer_id = c.id AND b.agent_id = sa.id AND b.is_active)) / nullif(count(c.id) FILTER (WHERE c.is_internal_account = false), 0), 2), 0)
  FROM public.sales_agents sa JOIN public.users u ON u.id = sa.user_id LEFT JOIN public.customers c ON c.assigned_agent_id = sa.id
  WHERE public.has_permission(auth.uid(), 'beat.view') AND sa.id IN (SELECT public.accessible_agent_ids(auth.uid()))
  GROUP BY sa.id, u.full_name ORDER BY u.full_name;
$$;

CREATE OR REPLACE FUNCTION public.beat_adherence_summary(p_from date, p_to date)
RETURNS TABLE (beat_id uuid, beat_name text, agent_name text, planned bigint, visited bigint, productive bigint, adherence_percent numeric, productive_percent numeric)
LANGUAGE sql SECURITY INVOKER SET search_path = public AS $$
  SELECT b.id, b.name, u.full_name,
         count(bv.id), count(bv.id) FILTER (WHERE bv.status = 'VISITED'),
         count(bv.id) FILTER (WHERE bv.status = 'VISITED' AND EXISTS (SELECT 1 FROM public.activities a WHERE a.id = bv.activity_id AND a.disposition IN ('ORDER_PLACED', 'PAYMENT_COLLECTED', 'FOLLOW_UP_SCHEDULED'))),
         coalesce(round(100.0 * count(bv.id) FILTER (WHERE bv.status = 'VISITED') / nullif(count(bv.id), 0), 2), 0),
         coalesce(round(100.0 * count(bv.id) FILTER (WHERE bv.status = 'VISITED' AND EXISTS (SELECT 1 FROM public.activities a WHERE a.id = bv.activity_id AND a.disposition IN ('ORDER_PLACED', 'PAYMENT_COLLECTED', 'FOLLOW_UP_SCHEDULED'))) / nullif(count(bv.id), 0), 2), 0)
  FROM public.beat_visits bv JOIN public.beats b ON b.id = bv.beat_id JOIN public.sales_agents sa ON sa.id = bv.agent_id JOIN public.users u ON u.id = sa.user_id
  WHERE public.has_permission(auth.uid(), 'beat.view') AND bv.planned_date BETWEEN p_from AND p_to AND bv.agent_id IN (SELECT public.accessible_agent_ids(auth.uid()))
  GROUP BY b.id, b.name, u.full_name ORDER BY b.name;
$$;

CREATE OR REPLACE FUNCTION public.sales_beat_summary(
  p_planned_date date DEFAULT (timezone('Asia/Karachi', now()))::date
)
RETURNS TABLE (planned bigint, completed bigint, productive bigint, progress_percent numeric)
LANGUAGE sql SECURITY INVOKER SET search_path = public AS $$
  SELECT count(bv.id),
         count(bv.id) FILTER (WHERE bv.status IN ('VISITED', 'SKIPPED')),
         count(bv.id) FILTER (WHERE bv.status = 'VISITED' AND EXISTS (SELECT 1 FROM public.activities a WHERE a.id = bv.activity_id AND a.disposition IN ('ORDER_PLACED', 'PAYMENT_COLLECTED', 'FOLLOW_UP_SCHEDULED'))),
         coalesce(round(100.0 * count(bv.id) FILTER (WHERE bv.status IN ('VISITED', 'SKIPPED')) / nullif(count(bv.id), 0), 2), 0)
  FROM public.beat_visits bv
  WHERE public.has_permission(auth.uid(), 'beat.view')
    AND bv.agent_id IN (SELECT public.accessible_agent_ids(auth.uid()))
    AND bv.planned_date = p_planned_date;
$$;

CREATE OR REPLACE FUNCTION public.beat_off_beat_suggestions()
RETURNS TABLE (customer_id uuid, business_name text, area_code text, reason_code text, reason_text text, outstanding_balance_pkr numeric, last_order_at timestamptz)
LANGUAGE sql SECURITY INVOKER SET search_path = public AS $$
  SELECT c.id, c.business_name, c.area_code,
    CASE WHEN public.has_permission(auth.uid(), 'collection.view') AND c.current_balance_pkr > 0 THEN 'OVERDUE_BALANCE' WHEN max(o.placed_at) IS NULL OR max(o.placed_at) < now() - interval '60 days' THEN 'NO_ORDER_60_DAYS' ELSE 'OPEN_CLAIM' END,
    CASE WHEN public.has_permission(auth.uid(), 'collection.view') AND c.current_balance_pkr > 0 THEN 'Outstanding balance' WHEN max(o.placed_at) IS NULL OR max(o.placed_at) < now() - interval '60 days' THEN 'No order in 60 days' ELSE 'Open complaint' END,
    CASE WHEN public.has_permission(auth.uid(), 'collection.view') THEN c.current_balance_pkr ELSE NULL END, max(o.placed_at)
  FROM public.customers c
  LEFT JOIN public.orders o ON o.customer_id = c.id AND o.status <> 'CANCELLED'
  WHERE public.has_permission(auth.uid(), 'beat.view')
    AND c.is_internal_account = false
    AND c.assigned_agent_id IN (SELECT public.accessible_agent_ids(auth.uid()))
    AND NOT EXISTS (SELECT 1 FROM public.beat_customers bc JOIN public.beats b ON b.id = bc.beat_id WHERE bc.customer_id = c.id AND b.agent_id = c.assigned_agent_id AND b.is_active)
  GROUP BY c.id, c.business_name, c.area_code, c.current_balance_pkr
  HAVING (public.has_permission(auth.uid(), 'collection.view') AND c.current_balance_pkr > 0)
      OR max(o.placed_at) IS NULL
      OR max(o.placed_at) < now() - interval '60 days'
      OR EXISTS (SELECT 1 FROM public.claims cl WHERE cl.customer_id = c.id AND cl.status IN ('SUBMITTED', 'UNDER_REVIEW', 'APPROVED'))
  ORDER BY CASE WHEN public.has_permission(auth.uid(), 'collection.view') THEN c.current_balance_pkr ELSE NULL END DESC NULLS LAST, max(o.placed_at) NULLS FIRST, c.business_name LIMIT 100;
$$;

CREATE OR REPLACE FUNCTION public.beat_ai_evidence(
  p_planned_date date DEFAULT (timezone('Asia/Karachi', now()))::date
)
RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = public AS $$
  SELECT jsonb_build_object(
    'planned_date', p_planned_date,
    'stops', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.beat_name, x.sequence) FROM public.sales_today_beat(p_planned_date) x), '[]'::jsonb),
    'off_beat', coalesce((SELECT jsonb_agg(to_jsonb(y) ORDER BY y.outstanding_balance_pkr DESC, y.business_name) FROM public.beat_off_beat_suggestions() y), '[]'::jsonb)
  );
$$;

GRANT EXECUTE ON FUNCTION public.create_beat_from_areas(text, uuid, smallint, text[], integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.materialize_beat_visits(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sales_today_beat(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_beat_visit(uuid, "BeatVisitStatus", "ActivityDisposition", text, numeric, numeric, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reschedule_beat_visit(uuid, date, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.beat_coverage_summary() TO authenticated;
GRANT EXECUTE ON FUNCTION public.beat_adherence_summary(date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sales_beat_summary(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.beat_off_beat_suggestions() TO authenticated;
GRANT EXECUTE ON FUNCTION public.beat_ai_evidence(date) TO authenticated;

INSERT INTO public.permissions (id, key, module, label_en, label_ur, description, is_sensitive, display_order)
VALUES ('perm_beat_visit', 'beat.visit', 'BEATS', 'Complete beat visits', 'Beat visit مکمل کریں', 'Mark, skip, or reschedule assigned beat visits.', false, 65)
ON CONFLICT (key) DO NOTHING;
INSERT INTO public.permission_dependencies(permission_id, requires_permission_id)
SELECT p.id, v.id FROM public.permissions p CROSS JOIN public.permissions v WHERE p.key = 'beat.visit' AND v.key = 'beat.view'
ON CONFLICT DO NOTHING;

ALTER TABLE public.beats FORCE ROW LEVEL SECURITY;
ALTER TABLE public.beat_customers FORCE ROW LEVEL SECURITY;
ALTER TABLE public.beat_frequency_targets FORCE ROW LEVEL SECURITY;
ALTER TABLE public.beat_visits FORCE ROW LEVEL SECURITY;
COMMENT ON INDEX beats_agent_day_active_idx IS 'Supports active agent/day beat setup and daily beat queries.';
COMMENT ON INDEX beat_customers_sequence_idx IS 'Supports sequenced customer ordering within a beat.';
COMMENT ON INDEX beat_visits_agent_date_status_idx IS 'Supports Sales daily beat filtering by agent, business date, and status.';
COMMENT ON INDEX beat_visits_beat_date_sequence_idx IS 'Supports Admin beat and route ordering.';
COMMENT ON INDEX beat_visits_customer_date_idx IS 'Supports customer visit recency and adherence evidence.';
