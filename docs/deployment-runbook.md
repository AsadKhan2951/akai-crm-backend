# AKAI CRM Deployment Runbook

## Purpose

This document describes the controlled path from the restored source workspace to staging, then production. It does not claim that a deployment has occurred. The current workspace has no Git metadata, no connected Vercel project, and no configured staging or production Supabase project.

## Environment separation

Use three application environments: local development, staging, and production. Staging and production must use different Supabase project URLs, database URLs, Auth users, Storage buckets, and provider credentials. A staging deployment must never point at production data. Configure environment variables in Vercel or the approved hosting dashboard; never commit real values.

| Variable group | Local | Staging | Production |
|---|---|---|---|
| Supabase URL and publishable key | Local project | Staging project | Production project |
| `DATABASE_URL` / `DIRECT_URL` | Local or test database | Staging database | Production database |
| Service-role key | Local system jobs only | Staging system jobs only | Production system jobs only |
| `NEXT_PUBLIC_APP_URL` | Local URL | Staging HTTPS URL | Custom HTTPS domain |
| Cron secret | Local test value | Unique staging value | Unique production value |
| Resend/Meta credentials | Mock or staging provider | Staging sender/assets | Approved production sender/assets |
| Claude/Sentry/VAPID | Optional local | Staging values | Production values |

## Source-control gate

Restore the real Git repository and verify the last known-good commit before connecting Vercel. Confirm the historical migration chain and Vendor PDF route are present from a real backup. Do not fabricate missing migrations. If a new repository is explicitly authorized, record that it cannot restore historical provenance and perform a full source review before deployment.

## Staging sequence

1. Connect the restored Git repository to a new Vercel project.
2. Create or select a dedicated Supabase staging project.
3. Configure staging Auth redirect URLs and email settings.
4. Configure Storage buckets and policies from the approved migration/setup plan.
5. Apply the complete migration chain with the direct database URL, after taking a staging backup.
6. Run the idempotent seed for permissions, preset roles, real catalogue seed data, and required settings.
7. Create controlled staging Admin, Haris, Daniyal, and Vendor accounts through the approved Auth process.
8. Run the real customer import only against staging data and verify 206 rows, 102 Haris, and 104 Daniyal.
9. Load and activate the first approved staging price list.
10. Execute the RLS matrix, raw sensitive-field response test, Auth flows, English/Urdu RTL flows, Recovery exact-once tests, message/webhook tests, PWA tests, and production build.
11. Perform a backup restore drill into an isolated staging recovery project.
12. Record all failures and fix them with additive migrations or code changes before production.

## Production change plan

Before production, approve a change window, take and verify the latest backup, confirm the exact Git commit, compare staging and production environment variable names, and confirm Auth redirect/custom-domain DNS readiness. Apply the complete migration chain using the direct connection. Run the normal seed only where idempotent and approved; do not run benchmark seed or create fake business records. Import the real workbook only after Haris and Daniyal accounts and agent IDs are verified. Load the real catalogue and activate the first price list after a second-person review.

## Production smoke test

Verify the public HTTPS domain, `/en`, `/ur`, login, password reset, role redirection, Admin dashboard, Sales Today, Vendor catalogue, cost-field omission for unauthorized users, vendor visibility isolation, order approval, quote acceptance, cash collection/deposit verification, receipt download, failed-message queue, WhatsApp signature rejection, notification bell, and offline indicator. Record actual timestamps and result evidence. Do not use a bypass account.

## Rollback

Application rollback uses the hosting provider’s last known-good deployment. Database rollback uses the approved backup/change procedure; applied Prisma migrations are never edited. If the issue touches money, stock, permissions, or RLS, freeze the affected writes, preserve the audit trail, and obtain an explicit incident owner before corrective SQL. A corrective migration must be additive and tested in staging first.

## Acceptance checklist

- [ ] Git history restored and remote access verified.
- [ ] Missing historical migrations and Vendor PDF route restored from source backup.
- [ ] Separate staging and production Supabase projects verified.
- [ ] Vercel development, preview/staging, and production environments configured.
- [ ] Environment variable names configured without secrets in Git.
- [ ] Auth redirect URLs and password-reset URL verified.
- [ ] Storage buckets, limits, content types, and RLS policies verified.
- [ ] Full migration chain applied successfully to staging.
- [ ] Staging RLS role matrix passed.
- [ ] Raw cost/margin response omission passed.
- [ ] English and Urdu browser UAT passed.
- [ ] Recovery exact-once ledger test passed.
- [ ] Message provider/webhook tests passed with real staging credentials.
- [ ] Backup and restore drill passed.
- [ ] Production backup verified before migration.
- [ ] Real customer import and agent assignment verified.
- [ ] First price list activated after approval.
- [ ] Custom domain and SSL verified.
- [ ] Monitoring and alert ownership documented.
- [ ] Final incomplete/stubbed/load-risk list delivered.
