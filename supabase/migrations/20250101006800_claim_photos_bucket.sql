-- Claim photos.
-- The upload rule already allowed the claim-photos bucket, but the bucket itself was never
-- created, so dealers and agents could not attach photos (and damage claims need one).
-- Photos are private: the uploader can read their own files, and anyone who can see the
-- claim (claim_photos RLS) can read the photos stored on it. The app shows them with
-- short-lived signed URLs.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('claim-photos', 'claim-photos', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists claim_photos_read_scoped on storage.objects;
create policy claim_photos_read_scoped on storage.objects
  for select to authenticated
  using (
    bucket_id = 'claim-photos'
    and (
      (storage.foldername(name))[1] = (select auth.uid())::text
      or exists (select 1 from public.claim_photos p where p.url = storage.objects.name)
    )
  );

create index if not exists claim_photos_url_idx on public.claim_photos (url);

-- Sales agents and managers could raise claims (claim.create) but not open the claims page
-- (claim.view), so /sales/claims crashed for them. RLS still limits them to their own dealers.
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key = 'claim.view'
where r.name in ('Sales Agent', 'Sales Manager')
on conflict do nothing;
