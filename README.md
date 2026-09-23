# AKAI CRM — Backend (database)

AKAI CRM runs on **Supabase** (Postgres, Auth, Storage). The Frontend (Next.js) talks to Supabase directly and **Postgres Row Level Security is the access boundary**, so the real "backend" is the database: tables, RLS policies, and SQL functions. This repo holds all of that.

| Path | What it is |
|---|---|
| `supabase/migrations/` | The SQL migration chain (tables, RLS, functions). Apply in order. |
| `prisma/schema.prisma` | Reference schema. Refresh it with `prisma db pull` after migrations run. |
| `prisma/seed.ts` | Idempotent seed: permission catalogue and preset roles. No fake business data. |
| `scripts/seed-admin-benchmark.ts` | Load-test data. **Never run on production.** |
| `scripts/check-migrations.mjs` | Checks the migration chain before you push it. |
| `github-actions/cron-jobs.yml` | Scheduled jobs. They call the Frontend's `/api/cron/*` routes. **Move it to `.github/workflows/cron-jobs.yml` before your first push.** |
| `DATA.md`, `OPERATIONS.md`, `docs/` | Data handling, operations and deployment notes. |

## Reconstructed migrations (read this)

Six historical migrations were missing from the recovered source. They were **rebuilt** from the later migrations, the Prisma schema and the app code, then verified on a local Postgres 16 with a Supabase stub (full chain applies cleanly; admin login, vendor cart/order/quote/redemption, admin approval and all cron functions tested):

```
20250101000100_foundation.sql                 roles, permissions, role_permissions, "Portal"
20250101000500_catalogue_admin.sql            catalogue RPCs, image buckets, audit_logs compat
20250101000600_versioned_price_lists.sql      price-list versioning, carts, announcements
20250101000800_vendor_purchase_suggestions.sql
20250101000900_vendor_portal_workflows.sql    vendor cart/order/quote/reorder RPCs
20250101001000_vendor_payment_method.sql      BALANCE / CREDIT payment method
```

Bugs fixed in existing migrations so the chain runs: 0013 (anomaly alerts, brand names, approve/reject scope), 0014 (recovery summary), 0015, 0033 (scheme policy recursion), 0037/0038 (ambiguous variables), 0042, 0052 (beat_visits), 0053/0055 (`FOR UPDATE OF`).

Added:
- `20250101005800_seed_permissions_and_roles.sql`: 115 permissions, 8 preset roles, and `bootstrap_first_admin()`.
- `20250101005900_vendor_rewards_access.sql`: vendors can see active rewards and request redemptions.
- `20250101006000_function_privilege_hardening.sql`: **security fix.** Internal SECURITY DEFINER helpers were callable by any logged-in user. For example, `apply_loyalty_delta` could give a Vendor free points and `apply_customer_ledger_delta` could change any balance. They are now service-role or internal only. Also: `vendor_customer_for_user` no longer reveals other users' shops, and GLOBAL admins can record payments for unassigned customers.
- `20250101006100_vendor_product_visibility_rls.sql`: **security fix.** Vendors could read every product and image through the REST API, including hidden ones. Vendor-portal users now see only `resolve_visible_products` for their shop, plus products already on their own orders, quotes and carts.
- `20250101006200_price_list_editing.sql`: `create_price_list_draft`, `set_price_list_item`, `remove_price_list_item` for the Admin price-list screens.
- `20250101006300_user_onboarding.sql`: user onboarding. An Admin adds the person in CRM → Users (role, plus shop for a Vendor or agent code for a Sales Agent). The login is created in Supabase Auth with the same email. A trigger on `auth.users` (or `provision_invited_user()`) creates the CRM user, the `customer_users` link and the `sales_agents` row. No service-role key is used in the app.
- `20250101006500_import_customer_workbook.sql`: the real CUSTOMERDATAFORCRM.xlsx import. 206 customers (Haris 102, Daniyal 104) and 88 area codes. Idempotent. 21 possible duplicates are flagged for review and not merged. Customers are assigned automatically when a Sales Agent with agent code HARIS or DANIYAL is created.
- `20250101006400_catalogue_pdf_cache_access.sql`: **security fix.** The Vendor role has `pricelist.view`, so vendors could read every price-list row and every dealer's cached PDF. Both are now scoped to the vendor's own visible products and shop folder. Also adds `active_price_list_id()` for the 24-hour PDF cache.

If the original files ever turn up, compare them before replacing. Test on staging first.

## First admin login

1. `npx supabase db push` (see Setup).
2. Supabase Dashboard → **Authentication → Users → Add user → Create new user**. Enter an email and a strong password and tick **Auto Confirm User**.
3. Supabase Dashboard → **SQL Editor**, then run:
   ```sql
   select public.bootstrap_first_admin('admin@yourcompany.com', 'Your Name');
   ```
   This gives that user the Administrator role. It only works once, while no active admin exists.
4. Log in on the Frontend with that email and password.

## Adding more users (Sales Agents, Vendors, staff)

1. CRM → Admin → Users → **Create user**: email, name, role. For a Vendor, pick their shop. For a Sales Agent, add the agent code, e.g. HARIS.
2. Supabase → Authentication → Users → **Add user**: same email plus a password. Tick Auto Confirm.
3. The login links automatically. If the login existed first, the CRM links it as soon as the form is saved; **Link now** retries.

## Migration file naming

Supabase CLI needs unique, ordered versions: `20250101` + old 4-digit number + `00`. For example, `0012_sales_portal` becomes `20250101001200_sales_portal.sql`. `0032_5_…` becomes `…003250_…`, which keeps it between 0032 and 0033.

## Setup

```bash
pnpm install
cp .env.example .env        # fill in the Supabase values
npx supabase init           # first time only: creates supabase/config.toml, leaves the migrations alone
npx supabase login
pnpm db:link                # links to SUPABASE_PROJECT_REF
pnpm check                  # must say "complete"
pnpm db:push                # applies supabase/migrations to the linked project
# permissions + roles are seeded by migration 0058, no separate seed needed
```

Use a **staging** Supabase project first and a separate **production** project after that.

## Scheduled jobs

On DigitalOcean there is no Vercel Cron, so GitHub Actions runs the schedules. First move `github-actions/cron-jobs.yml` to `.github/workflows/cron-jobs.yml`, then add these repo secrets:

- `APP_URL`: the Frontend's public URL, e.g. `https://crm.example.com`
- `CRON_SECRET`: the same value as the Frontend's `CRON_SECRET`

`recovery-reminders` and `admin-reports` never had a schedule, so they are manual only for now (Actions › AKAI cron jobs › Run workflow). Add schedules once the business confirms the timing.
