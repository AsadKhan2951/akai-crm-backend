-- Vendors must be able to see active rewards and request a redemption.
-- rewards only had manager policies, so the vendor-side FOR UPDATE lookup
-- inside request_loyalty_redemption always failed. The function derives the
-- customer from auth.uid() and checks redemption.request itself, so it is
-- safe to run it with definer rights.
drop policy if exists rewards_vendor_read on public.rewards;
create policy rewards_vendor_read on public.rewards for select to authenticated
  using (
    is_active
    and (starts_at is null or starts_at <= now())
    and (ends_at is null or ends_at >= now())
    and (public.has_permission(auth.uid(), 'redemption.request') or public.has_permission(auth.uid(), 'loyalty.view'))
  );

alter function public.request_loyalty_redemption(uuid) security definer;
alter function public.request_loyalty_redemption(uuid) set search_path = public;
revoke all on function public.request_loyalty_redemption(uuid) from public, anon;
grant execute on function public.request_loyalty_redemption(uuid) to authenticated;
