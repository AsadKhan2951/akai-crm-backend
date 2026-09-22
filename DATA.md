# AKAI CRM Data Handling

This document describes the data categories that AKAI CRM is designed to store, the systems that process them, the roles that may access them, and the current retention and deletion boundaries. It is an implementation handover document, not a legal privacy notice. The final business retention periods and the production privacy notice must be approved by AKAI before live data is loaded.

## Stored data

| Data category | Examples | Primary storage | Access boundary |
|---|---|---|---|
| User and access data | Name, email, phone, preferred locale, active status, role, permissions, login timestamps | Supabase Auth and Supabase Postgres `users`, `roles`, `permissions`, `role_permissions` | Authenticated users see only the fields allowed by their role; permission tables are queried rather than read from JWT claims |
| Customer business data | Shop name, normalized name, phone numbers, WhatsApp number, contact person, address, area, customer type, assigned Sales Agent | Supabase Postgres `customers`, `customer_users`, `area_codes` | RLS limits Sales users to assigned scope and Vendors to their linked customer; Admin access is permission-controlled |
| Commercial and financial data | Orders, quotes, order-line prices, balances, collections, deposits, ledger entries, loyalty transactions | Supabase Postgres business tables | RLS and permission checks; cost and margin fields are not selected for users without the relevant permission |
| Operational activity data | Calls, visits, optional geolocation, follow-ups, notes, delivery and receipt records | Supabase Postgres activities, follow-ups, recovery and delivery tables | Current-user scope and role permissions; geolocation is captured only after an explicit user action |
| Uploaded files | Product images, banners, claim photos, collection documents, voice notes, generated receipts/catalogues | Supabase Storage buckets and related database paths | Bucket policies, authenticated writes, content/type/size validation, and scoped record access |
| Communications data | Email/WhatsApp message logs, inbound messages, delivery statuses, unsubscribe choices, notifications | Supabase Postgres messaging tables; provider systems receive only queued message payloads required for delivery | RLS, channel opt-out checks, signed webhook validation, and provider-specific permissions |
| AI data | User prompts, assistant responses, trace names, token usage and drafts | Supabase Postgres AI tables; Anthropic receives the provider request when configured | AI context is assembled under the current user’s RLS session; output is draft/read-only and never directly writes records |
| Offline device data | User-scoped read snapshots, pending activity/collection/order payloads, idempotency keys | Browser IndexedDB and user-scoped Cache Storage | Cleared on logout where the service worker is active; pending writes sync only through the permission-first API |

## Third parties

| Third party | Data received | Purpose | Current status |
|---|---|---|---|
| Supabase | Application data, Auth session data, Storage files | Database, RLS, authentication and file storage | Required production platform; project credentials are environment-only |
| Vercel | Application requests, deployment artifacts, runtime logs | Hosting and scheduled system jobs | Intended hosting platform; production project is not connected in this workspace |
| Meta WhatsApp Cloud API | Recipient phone, approved template parameters, outbound media, webhook events | WhatsApp delivery and inbound/status events | Adapter is implemented; credentials, template approval and public webhook registration remain deployment work |
| Resend | Recipient email, message content and delivery metadata | Transactional and campaign email | Adapter is implemented; credentials and verified sending domain remain deployment work |
| Anthropic Claude API | RLS-scoped AI context and user prompt needed for the selected draft/assistant request | AI drafts and assistant responses | Adapter is implemented; provider key is environment-only and absent from this workspace |
| Google | No data is sent by the current code unless a future approved Google Workspace or calendar connector is configured | Potential future calendar/report integration | No active Google connector is assumed by this codebase |

## Access and retention

Postgres RLS is the authoritative access boundary. Application permission checks improve user feedback but do not replace policies. Audit records are intended to be append-only and are visible only to users with `auditlog.view`. Financial snapshots and historical order-line prices are retained for audit correctness and are not recomputed from current prices.

The current implementation does not silently delete operational, financial, audit, message, or AI records on a timer. AKAI must approve retention periods for each category before production launch. Until those periods are approved, administrators should use the permission-controlled export and operational review paths rather than direct database deletion.

Browser offline caches are operational conveniences, not the system of record. The service worker scopes cache names by authenticated user id and removes the active user cache on logout. A device may still retain browser-managed data if the browser is terminated before the logout message is processed; users should use device/browser controls when a shared device requires full local-data removal.

## Export and deletion

Customer export and hard-delete are Phase 15 acceptance requirements. They must be implemented with explicit confirmation, permission checks, RLS-backed selection, an audit record, and a documented treatment of related orders, ledger entries, receipts, messages, and legal/audit records. No production deletion should be performed until AKAI approves the retention and legal policy.

## Backup and restore

Supabase point-in-time recovery, backup retention, restore ownership, and a restore drill must be configured in the production Supabase project. The restore procedure must include the migration chain, RLS policies, database functions, Storage bucket policies, Auth redirect settings, environment variables, and a post-restore access-control test. This workspace cannot claim that a hosted restore has been tested because no production Supabase project is connected.
