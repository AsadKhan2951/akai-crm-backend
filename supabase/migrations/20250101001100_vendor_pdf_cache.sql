-- AKAI CRM migration 0011: vendor-scoped catalogue PDF cache and share metadata.
-- This is additive and does not edit earlier migrations.

ALTER TABLE public.catalogue_pdfs
  ADD COLUMN IF NOT EXISTS cache_until timestamptz NOT NULL DEFAULT now();


CREATE INDEX IF NOT EXISTS catalogue_pdfs_vendor_cache_idx
  ON public.catalogue_pdfs (customer_id, price_list_id, locale, cache_until);

ALTER TABLE public.catalogue_pdfs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS catalogue_pdfs_vendor_read ON public.catalogue_pdfs;
CREATE POLICY catalogue_pdfs_vendor_read ON public.catalogue_pdfs
  FOR SELECT TO authenticated
  USING (
    customer_id IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.customer_users cu
      WHERE cu.customer_id = catalogue_pdfs.customer_id
        AND cu.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS catalogue_pdfs_vendor_insert ON public.catalogue_pdfs;
CREATE POLICY catalogue_pdfs_vendor_insert ON public.catalogue_pdfs
  FOR INSERT TO authenticated
  WITH CHECK (
    customer_id IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.customer_users cu
      WHERE cu.customer_id = catalogue_pdfs.customer_id
        AND cu.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS catalogue_pdfs_vendor_update ON public.catalogue_pdfs;
CREATE POLICY catalogue_pdfs_vendor_update ON public.catalogue_pdfs
  FOR UPDATE TO authenticated
  USING (
    customer_id IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.customer_users cu
      WHERE cu.customer_id = catalogue_pdfs.customer_id
        AND cu.user_id = auth.uid()
    )
  )
  WITH CHECK (
    customer_id IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.customer_users cu
      WHERE cu.customer_id = catalogue_pdfs.customer_id
        AND cu.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS catalogue_pdfs_authenticated_read ON storage.objects;
CREATE POLICY catalogue_pdfs_vendor_storage_read ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'catalogue-pdfs'
    AND EXISTS (
      SELECT 1
      FROM public.customer_users cu
      WHERE name LIKE 'vendors/' || cu.customer_id::text || '/%'
        AND cu.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS catalogue_pdfs_vendor_storage_insert ON storage.objects;
CREATE POLICY catalogue_pdfs_vendor_storage_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'catalogue-pdfs'
    AND EXISTS (
      SELECT 1
      FROM public.customer_users cu
      WHERE name LIKE 'vendors/' || cu.customer_id::text || '/%'
        AND cu.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS catalogue_pdfs_vendor_storage_update ON storage.objects;
CREATE POLICY catalogue_pdfs_vendor_storage_update ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'catalogue-pdfs'
    AND EXISTS (
      SELECT 1
      FROM public.customer_users cu
      WHERE name LIKE 'vendors/' || cu.customer_id::text || '/%'
        AND cu.user_id = auth.uid()
    )
  )
  WITH CHECK (
    bucket_id = 'catalogue-pdfs'
    AND EXISTS (
      SELECT 1
      FROM public.customer_users cu
      WHERE name LIKE 'vendors/' || cu.customer_id::text || '/%'
        AND cu.user_id = auth.uid()
    )
  );
