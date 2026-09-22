# Manus-local Phase 11 recovery verification

This document records the isolated local verification environment created for AKAI CRM Phase 11. It is not a production Supabase configuration and contains no real customer, product, or production secret.

## Local environment

PostgreSQL 16 was installed in the Manus sandbox. The isolated database is `akai_local`, reached through `127.0.0.1:5432` with a local-only test role. Temporary connection values were written outside the repository at `/tmp/akai-manus.env`.

The local database was synchronized from `prisma/schema.prisma`. Minimal compatibility schemas were added for `auth` and `storage`, including `auth.uid()` and the Storage table shapes required by the existing SQL. Local `authenticated` and `anon` roles were created only for RLS-compatible testing.

The test fixtures are explicitly local: `Haris Local`, `Daniyal Local`, `Admin Local`, `Haris Shop`, and `Daniyal Shop`. They are not production records and must not be imported into the user’s real Supabase project.

## Additive recovery corrections

After applying the current schema to the local database, actual SQL execution identified mismatches between the Phase 11 functions and the restored schema. These were corrected through new migrations only; earlier migrations were not edited.

| Migration | Purpose |
|---|---|
| `0016_recovery_summary_fix` | Corrects the Admin recovery ageing aggregate. |
| `0017_recovery_audit_fix` | Introduces a recovery audit helper and adapts collection/deposit functions. |
| `0018_recovery_audit_columns_fix` | Matches the actual `audit_logs` column names. |
| `0019_recovery_deposit_scope_fix` | Disambiguates the deposit agent variable. |
| `0020_recovery_deposit_id_fix` | Explicitly creates the cash-deposit UUID. |
| `0021_recovery_bounce_audit_fix` | Corrects cheque-bounce audit and notification identifiers. |

These migrations must be reviewed and applied in order after `0015_recovery_hardening` on a clean target database.

## Actual local evidence

Haris authenticated through the local claim-compatible session saw only `Haris Shop`; the Daniyal count was `0`. Daniyal saw only `Daniyal Shop`. Admin saw both customers.

Haris recorded a cash collection for `125.00` PKR and received receipt `AKAI-R-202609-0001`. The balance was `1000.00` before collection, remained `1000.00` after collection, and remained `1000.00` after deposit submission. Admin verification changed it to `875.00`.

The verified cash collection produced exactly one payment ledger row with amount `-125.00`, and the collection stored one `ledger_entry_id`. A second verification was rejected with `Deposit is outside your scope or is no longer pending.` A rollback-only second collection produced the next receipt `AKAI-R-202609-0002`.

The cheque flow was also executed. After deposit verification, the cheque was `DEPOSITED` with no ledger entry and the balance remained `875.00`. Explicit clearing changed the balance to `825.00` and created the payment ledger link. Bouncing the cleared cheque created a `+50.00` reversal and restored the balance to `875.00`. The cheque-related ledger count was `2` with net sum `0.00`.

## Static checks

```text
✓ tests/recovery-portal.test.ts (7 tests)
Test Files  1 passed (1)
Tests       7 passed (7)

> pnpm check
Process exited with code 0

> pnpm lint
Process exited with code

> pnpm check:policy
Repository policy check passed: no forbidden patterns found.

> pnpm db:validate
The schema at prisma/schema.prisma is valid 🚀

> pnpm build
✓ Compiled successfully in 21.5s
✓ Linting and checking validity of types
✓ Collecting page data
✓ Generating static pages (8/8)
+ First Load JS shared by all 102 kB
```

The full historical test suite still has three restore failures because the workspace lacks `prisma/migrations/0006_versioned_price_lists/migration.sql`, `app/api/vendor/catalogue-pdf/route.ts`, and `prisma/migrations/0009_vendor_portal_workflows/migration.sql`. This local verification does not repair those missing historical files.

## Handoff

For the user’s Supabase environment, replace the temporary local values with the project’s own `DATABASE_URL`, `DIRECT_URL`, `NEXT_PUBLIC_SUPABASE_URL`, publishable key, and server-only service-role value. The service-role value must never be committed or exposed to the browser. Before production use, apply the migrations on a backup/staging project first, run authenticated Supabase RLS UAT, configure Auth and Storage, and repeat the exact balance/ledger assertions against non-production fixtures.
