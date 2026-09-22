# AKAI CRM Project Rules

**Project:** AKAI CRM — car care and automotive accessories distribution, Karachi, Pakistan  
**Portals:** Admin, Sales, Vendor  
**Supported languages:** English and Urdu  
**Status:** Governing repository document. Read this file before writing code.

These rules apply to **every task in this project**. They override any convenient shortcut. If a rule blocks the work, stop and ask. Do not work around it silently.

## Stack

The project stack is fixed and must not be substituted:

- Next.js 15 App Router + TypeScript.
- Supabase Postgres via Prisma.
- Supabase Auth.
- Tailwind CSS + shadcn/ui.
- next-intl with English (`en`) and Urdu (`ur`).
- Recharts.
- Anthropic Claude API.
- Vercel deployment.

If a different library or platform appears necessary, ask first and explain why.

## Security invariants

1. **Postgres Row Level Security is the security boundary.** Application checks are a convenience layer on top and never a substitute for RLS.
2. **Never use the service-role key for any query serving a user request.** It is for migrations, seeds, and system jobs only. If a query is awkward under RLS, fix the policy; do not bypass it.
3. **Never read permissions from JWT claims.** Query the permission tables. A stale JWT means revoked access still works, which defeats the permission system.
4. **Every server action and route handler starts with a permission check that throws before any work happens.**
5. **AI context is assembled by queries run as the current user under RLS.** Never assemble context with elevated access and filter it in the prompt. Prompt filtering is not a security boundary.
6. **Sensitive product and margin fields must be absent from API responses when unauthorized.** `Product.costPKR` and all margin figures must not be returned to users without `product.view_cost`; they must not merely be nulled client-side.
7. **No secret may exist in the repository or client bundle.** Use environment variables only.

## Data correctness

8. **Money is never a float.** Use Prisma `Decimal` and PostgreSQL `numeric(12,2)`. Never perform JavaScript number arithmetic on currency.
9. **Store all timestamps in UTC.** All business-day logic uses `Asia/Karachi`. Never use the server’s local timezone.
10. **`Customer.currentBalancePKR` and `Customer.loyaltyPointsBalance` are derived caches.** Exactly one service function may mutate each cache. Never write either cache from two paths.
11. **Any operation touching money or stock runs inside a database transaction.**
12. **Order lines store `unitPricePKR` at order time.** Nothing may recompute a historical price from the current price list.
13. **Phones are stored in E.164 format (`+92XXXXXXXXXX`).** They are displayed in the format `0XXX-XXXXXXX`.

## Performance

14. **Aggregate in SQL, never in JavaScript over fetched rows.** No dashboard may load a table into memory to sum it.
15. **Add an index when adding a query that filters or sorts on a column.** State which index was added and why.
16. **Performance target:** usable on 3G, initial JavaScript bundle under 200KB, and dashboards under two seconds at 50,000 orders.

## UI rules

17. Users are Karachi shopkeepers and field sales staff, many of whom are not comfortable with software. **Obvious beats clever every time.**
18. Use this palette only unless permission is obtained for another colour: navy `#16233F` for primary UI, red `#D6202C` for primary actions and alerts only, white backgrounds, slate `#64748B` for secondary text, and `#F1F5F9` for surfaces. No other colours without asking.
19. Use Inter for Latin text and **all numbers**. Use Noto Nastaliq Urdu for Urdu text.
20. Base font size is 16px; never use less than 14px. Touch targets must be at least 44×44px. Use no more than five primary navigation items. Menu nesting is limited to one level.
21. No decorative animation, gradients, or dark mode in v1.
22. Buttons must name their action: use “Place order”, not “Submit”. An action keeps the same word through the entire flow; a “Publish” button produces a “Published” toast.
23. Every list screen has search at the top and a real empty state that says what to do next. Never ship a blank list.
24. Errors must explain what happened and how to fix it. Never show stack traces to users.

## Urdu and RTL

25. **Vendor portal: zero hardcoded strings.** Every user-facing vendor string comes from translation files.
26. Locale `ur` sets `dir="rtl"` and mirrors the full layout: navigation, icons, back arrows, table column order, and carousel swipe direction. Do not mirror text only.
27. Numbers, prices, dates, phone numbers, and SKUs stay Western Arabic numerals reading LTR inside RTL text. Wrap them in `<bdi>` or set `unicode-bidi: isolate`. Check this every time a screen with numbers is touched.
28. Use genuine Urdu, not transliteration. Where Karachi traders normally use an English term—such as “invoice”, “order”, or “delivery”—keep the English term rather than forcing an obscure Urdu equivalent.

## Catalogue model

29. **Category, Brand, and Collection are three independent dimensions.** Brand cuts across categories. CASTA sells car care, alarms, locks, covers, microfibre, horns, and jump starters. Never nest Brand under Category.
30. **Every vendor-facing product query goes through `resolveVisibleProducts(customerId)`.** There are no exceptions: browse, search, autocomplete, direct URL, cart, quotes, banners, PDF export, AI context, and recommendations all use this resolver.

## AI feature rules

31. **AI output is a draft.** It fills form fields for a human to confirm. It never saves directly, sends a message directly, or places an order without explicit confirmation.
32. **Every AI feature degrades gracefully.** If the API is down or slow, the underlying feature still works. Catalogue search falls back to keyword search at three seconds.
33. **Every figure stated by AI must be traceable to a query result.** If the data is not present, AI must say so. Never let it estimate or infer a number about a customer.

## Working agreement

34. **Build only the phase explicitly given.** Do not build ahead or add features that were not requested. If something appears to be missing, list it at the end; do not build it.
35. When test output is requested, paste the **actual output**. Never assert that something passed without showing it.
36. Never edit a migration that has already been applied. Write a new migration.
37. Seed data must be idempotent and clearly marked as seed. Never create fake customers or products that could be mistaken for real records.
38. At the end of each phase, commit with a descriptive message, then give:
   - what was built;
   - test results;
   - anything stubbed or incomplete; and
   - anything decided that was not specified.
39. If blocked or uncertain, ask. A wrong assumption carried forward through three phases is more expensive than one question.
40. Keep `PROJECT_RULES.md` current. If a new rule is agreed, add it here.

## Decisions log

This section is append-only. Each entry records a choice that was not specified in the project instructions, with the date and reasoning.

### 2026-08-24 — Manual repository initialization

The repository was initialized manually at `/home/ubuntu/akai-crm` rather than using the available project scaffold. The user explicitly confirmed this approach because the available scaffold did not provide the mandatory Next.js 15 + Prisma + Supabase stack. This preserves the project’s fixed-stack rule and avoids silently substituting Vite, Express, Drizzle, or MySQL.

### 2026-08-24 — Governance files precede application features

This governance task is being completed before business features. The reasoning is to make the security, data correctness, localization, performance, and working-agreement constraints visible in the repository before application code is added.

### 2026-08-24 — Locale-prefixed routing with a single dynamic document root

The application uses `/[locale]/` as the single Next.js document root, with `en` and `ur` always present in the URL. This makes the `html` language and direction deterministic on the server and avoids client-side direction changes after hydration.

### 2026-08-24 — Public versus private Storage buckets

Product, banner, category, and brand imagery are public-read buckets because they are catalogue-facing assets. Claim photos and voice notes are private-read buckets because they may contain dealer or operational information. All uploads require authenticated storage policies, a user-id folder prefix, a 5MB limit, and an allowed content type.

### 2026-08-24 — Client-side image conversion target

ImageUploader converts accepted raster uploads to WebP after resizing the longest edge to 2,000 pixels. This reduces mobile upload size while keeping the database and Storage policy boundaries independent of image processing.

### 2026-08-24 — User authorization source of truth

The permission phase uses a dedicated `users` table keyed to `auth.users`, with one role per user as specified in the brief. The earlier foundation `profiles`/`portal_memberships` tables are retained for compatibility, but portal routing and permission evaluation use `users` → `roles` → `role_permissions` → `permissions`. This preserves the requested role model and avoids reading authorization from JWT claims.

### 2026-08-24 — Minimal owner-scoped security test models

Minimal `customers`, `orders`, `quotes`, `leads`, `activities`, `follow_ups`, `collections`, `claims`, `beat_visits`, products, and financial snapshot tables were added solely to make the requested RLS and sensitive-field authorization contracts concrete and testable. No business workflows or UI were added for them.

### 2026-08-24 — Application and database guard layering

The implementation intentionally duplicates authorization checks in three layers: RLS functions/policies, server `requirePermission` and role-policy helpers, and client `usePermissions`/`Can` UI guards. The client layer is explicitly cosmetic; database RLS remains authoritative.

### 2026-08-24 — Test (e) is a hard security invariant

Test (e) is enforced twice: the pure authorization engine throws when an actor lacks a permission they are attempting to grant, and the PostgreSQL `enforce_role_privilege_boundary` trigger rejects role-permission inserts and updates when the current user does not already hold the target permission. The test also asserts the database trigger contract, because a unit-only check would not protect direct database/API writes.

### 2026-08-24 — Business schema migration strategy

The business schema is delivered as new migration `0003_business_schema`. It upgrades only the temporary Phase 2 owner-scope tables where needed, preserves existing migration history, and creates the complete Phase 3 domain tables. No business seed records are created.

### 2026-08-24 — Physical cost isolation

`Product.costPKR` is represented logically through the normalized `product_costs` relation, and price-list cost is represented through `price_list_item_costs`. The vendor-facing security-invoker view and `resolve_visible_products(customerId)` projection omit both cost and margin columns entirely. This was chosen because PostgreSQL RLS protects rows, while a separate table/view makes unauthorized response omission structural rather than client-side.

### 2026-08-24 — Local migration validation

Because no Supabase project credentials are configured, the migration chain is validated against an isolated local PostgreSQL instance with minimal `auth` and `storage` stubs. The target Supabase project still requires a real deployment migration and authenticated integration run.

### 2026-08-25 — Catalogue dimensions and seed associations

The catalogue phase seeds exactly the 17 real brands and 17 real categories supplied by AKAI. Brand association notes are stored on categories as non-binding reference text because Brand, Category, and Collection are independent dimensions. `Back Care` carries an explicit confirmation warning rather than an invented interpretation.

### 2026-08-25 — Product cost and bulk-operation boundaries

The legacy product cost column is copied into the protected `product_costs` relation and then dropped from `products` in migration `0005_catalogue_admin`. Product create/update, CSV import, image replacement, and bulk price functions are permission-checked at the server and database boundaries. Bulk changes require a preview and explicit confirmation; price arithmetic remains in PostgreSQL numeric functions and every price update is audited.

### 2026-08-25 — Draft-only catalogue AI

Claude catalogue generation is an optional server action gated by `ai.generate_content`. Output fills editable product/category fields but never saves directly. Missing or unavailable AI configuration leaves the normal form usable.

## Known gaps

This section is maintained so stubbed or incomplete work remains visible rather than being forgotten.

- Remaining business features are intentionally not implemented: orders, CRM workflows, quotes, ledger, loyalty, analytics, and vendor commerce workflows remain out of scope for the completed catalogue phase. Catalogue administration is now implemented.
- Supabase project credentials, production URLs, Auth redirect configuration, and deployment configuration are not yet provided.
- The 0002 permission migration, 0003 business migration, and seed have not been applied to a live Supabase project in this sandbox; they were applied successfully to an isolated local PostgreSQL validation database.
- The seed includes exact permission keys and preset role permission assignments, but bilingual permission labels are currently generated from permission keys and should be reviewed with AKAI before the admin UI is built.
- Live RLS integration tests against Supabase are not runnable without a configured project; the committed tests are deterministic permission-engine regression tests plus migration-contract assertions. The database trigger itself still needs execution against the target Supabase project as part of deployment verification.
- Role mutation route handlers/server actions are not yet added; `requirePermission` and role-policy helpers are ready for the approved role-builder phase.
- Remaining order, CRM, quote, finance, loyalty, analytics, and vendor workflows are intentionally not implemented in this catalogue phase.
- The policy checker is implemented and must be retained and extended when new file types or generated directories are introduced.
- Private Storage preview cleanup and object-metadata persistence are not yet connected to a business record because business features are intentionally absent.

### 2026-08-24 — Workbook agent-name correction

The workbook’s first section marker `SALE AGENT: HARRIS` is treated as the real Sales Agent display name **Haris**, with `Harris` retained as a lookup alias for administrator-managed account records. The second section is **Daniyal**. No Hanif Sales Agent exists.

### 2026-08-24 — Internal-account rule correction

The earlier interpretation that two Hanif-named rows should be imported as internal accounts is superseded by the user’s correction. The importer now marks **no workbook rows** as internal accounts and does not invent an internal-account rule. All 206 workbook rows remain ordinary imported customers unless a later approved rule changes this.

- The previous local dry-run report that listed two Hanif internal accounts is obsolete and must not be used for production import decisions.

### 2026-08-24 — Real customer workbook import rules

The real workbook `CUSTOMERDATAFORCRM.xlsx` contains 206 customer rows: 102 under `SALE AGENT: HARRIS`, treated as the administrator-managed Sales Agent display name **Haris**, and 104 under `SALE AGENT: DANIYAL`, treated as **Daniyal**. The importer accepts `HARRIS`/`HARIS` as account lookup aliases but does not create accounts; Sales Agent users must already exist because all accounts are administrator-created.

All workbook rows are imported as ordinary customers with `status=ACTIVE`, `isInternalAccount=false`, `dataComplete=false`, and confirmed `customerType=OTHER`. Keyword classification is stored only in `customerTypeSuggestion` for human confirmation. No Hanif Sales Agent or internal-account exception is applied.

Area codes are seeded with the source abbreviation as the initial English name, Urdu name, and town because the workbook supplies no full names. Coordinates remain null until explicitly configured or captured. The Admin area screen is the controlled place to replace those placeholders.

The importer uses a SHA-256 workbook batch prefix plus source row as `importKey`. This makes a repeated import idempotent while preserving every source row and never auto-merging duplicate or near-duplicate shops. Near-duplicate flags use a conservative 90% normalized-name similarity threshold and remain manual-review work.

### 2026-08-24 — Enrichment queue behavior

Sales enrichment is permission-gated by `customer.enrich`, scoped to the current Sales Agent’s assigned incomplete customers, ordered by `area_code` and then `normalized_name`. The Save and next action updates the record through an RLS-protected Supabase query and redirects directly back to the next incomplete record. The Admin completion report uses SQL aggregation through `customer_enrichment_progress` and excludes internal accounts.

## Known gaps

- The real workbook import was executed successfully only against the isolated local PostgreSQL validation database. The target Supabase project still needs the 0004 migration, administrator-managed Haris/Daniyal accounts, and the import command run with production configuration.
- Area codes have placeholder names equal to their source abbreviations until an administrator fills the English and Urdu names. Latitude and longitude remain null by design.
- The enrichment screen is implemented, but no real customer has complete phone, contact-person, address, type-confirmation, or location data because those values were absent from the workbook.
- The importer report identified 17 duplicate-review records. They are flagged but not merged; the manual review workflow is not yet implemented.
- The workbook contains 88 distinct area-code abbreviations, including both `---` and `----`; they are imported as ordinary AreaCode values because the user explicitly removed the Hanif/internal-account rule.

- The production build reports first-load JavaScript of 207–209KB on the new Admin progress, Admin area, and Sales enrichment routes, above the 200KB target. The shared bundle remains 102KB; route-level lazy loading and further component splitting are deferred for performance hardening.

### 2026-08-25 — Versioned pricing phase

- **Decision:** Product.pricePKR remains only an activation-managed cache. All editable prices are stored in versioned price-list items, with audit rows and effective-date lookup.
- **Reasoning:** Imported prices change several times a year, and direct edits would corrupt historical margin analysis and create checkout races.
- **Decision:** Product CSV import is metadata-only; price-list CSV import targets only a DRAFT price list and requires preview before application.
- **Reasoning:** No bulk or product operation may mutate the active Product price cache directly.
- **Decision:** Price-list approval defaults to required and is configurable through the `price_list_approval_required` Settings key.
- **Reasoning:** A mis-keyed price update must require explicit review before activation.
- **Decision:** Scheduled activation runs through a Vercel Cron route protected by `CRON_SECRET`; activation refreshes Product.pricePKR and triggers English/Urdu PDF regeneration with approved `pdf-lib`.
- **Reasoning:** Vercel is the mandated deployment target, and `pdf-lib` is the approved lightweight deterministic PDF renderer for this phase.
- **Decision:** Price announcements are stored bilingually and queue WhatsApp/email MessageLog records with status `QUEUED`; this phase does not claim that an external message was sent.
- **Reasoning:** External provider delivery needs a separate configured integration and explicit human confirmation.

### Known gaps — Versioned pricing phase

- Migration and scheduled activation were validated against the isolated local PostgreSQL database, but not the target Supabase project because production credentials are not configured in this session.
- WhatsApp/email provider integration is not configured; announcements are saved and queueable but not externally sent.
- The automatic activation worker currently regenerates global English and Urdu catalogue PDFs. Customer-specific vendor PDF generation remains to be wired through `resolveVisibleProducts(customerId)` when vendor catalogue export is built.
- Product price history and optional product margin chart are implemented. Category/brand aggregate trend UI is deferred, although SQL trend functions are available.
- Cart refresh, price-change acknowledgement, and checkout blocking functions are implemented and locally regression-tested; the complete vendor checkout flow is deferred.
- Claude margin and announcement drafts gracefully return unavailable without `ANTHROPIC_API_KEY` and `ANTHROPIC_MODEL`; no live Claude call was made in this session.
- Recharts receives Decimal strings from the server; browser visual verification of the authenticated admin chart remains pending.

### 2026-08-25 — Direct price-cache trigger hardening

- **Decision:** The Product.pricePKR trigger treats a missing `app.price_list_activation` setting as `off` using `COALESCE`, so only the activation function’s transaction-scoped `on` flag can write the cache.
- **Reasoning:** PostgreSQL `NULL <> 'on'` evaluates to NULL and would otherwise allow a direct authenticated price edit to bypass the trigger.
- **Verification:** The isolated rollback-only SQL regression now proves direct Product.pricePKR mutation is rejected, order-line price mutation is rejected, held quote price mutation is rejected, and checkout remains blocked when cart price changes are unacknowledged.

### 2026-08-25 — Vendor visibility and promotional banners

- **Decision:** Vendor visibility is resolved by one database-backed most-specific resolver. Precedence is vendor product, vendor brand, vendor category, category-brand pair, group product, group brand, group category, then group default. A product-level rule overrides a broader rule, and deny overrides allow only at the same specificity level by latest rule timestamp.
- **Reasoning:** Vendor-facing access must be consistent across browse, search, direct URLs, cart cleanup, quote context, banners, AI context, PDFs, and recommendations. The resolver is the single boundary rather than UI filtering.
- **Decision:** The default group is `Standard Dealers`, and only one VendorGroup may be default. New customers without an explicit group are assigned to that group by a database trigger.
- **Reasoning:** New dealer accounts need a deterministic safe catalogue default without duplicating assignment logic in application paths.
- **Decision:** Category-by-brand matrix cells are real independent pair rules rather than category-only rules. CASTA products can therefore be resolved independently in Car Care and Horns.
- **Reasoning:** Brand and Category are independent catalogue dimensions; a tree model would incorrectly constrain cross-category brands.
- **Decision:** Vendor-facing banners are resolved by active date window, audience, and the same product resolver for product/category/brand/collection links, with a hard database limit of five banners.
- **Reasoning:** Vendors must never see a banner that leads to a product they cannot access, and the carousel must remain lightweight and predictable.
- **Decision:** Banner image uploads use the existing uploader with a configurable 2MB limit; public catalogue imagery retains its existing 5MB policy. Banner impressions are debounced per browser session and clicks are recorded only after explicit interaction.
- **Reasoning:** Banner artwork is optimized for mobile delivery while event metrics avoid refresh inflation without inventing a user identity.
- **Decision:** Banner activation/deactivation is an explicit Admin action and scheduled windows remain enforced by the database resolver.
- **Reasoning:** A banner’s active flag must be controllable without bypassing start/end dates or audience rules.
- **Decision:** Vendor-scoped PDF generation accepts only rows returned by `resolveVisibleProducts(customerId)`; no global or elevated product query is used for vendor output.
- **Reasoning:** PDF export is another product surface and must not become a visibility bypass.
- **Decision:** Draft AI banner copy is bilingual, optional, and fills editable fields only. No AI output is saved or sent automatically.
- **Reasoning:** AI remains a drafting aid and external communication requires human confirmation.

### Known gaps — Vendor visibility and promotional banners

- The 0007 migration and vendor visibility tests were validated against the isolated local PostgreSQL database, not a live Supabase project.
- Vendor-specific external provider delivery is not configured; banner impressions/clicks are stored only when the current authenticated vendor can access the banner.
- The carousel evidence route and local artwork used for screenshot verification were temporary and have been removed. Retained evidence is stored under `docs/vendor-carousel-en.webp`, `docs/vendor-carousel-ur.webp`, and `docs/vendor-carousel-visual-findings.md`.
- The current visibility preview counts products through the controlled Admin preview function. Full authenticated Admin-to-vendor preview UAT remains pending against a real Supabase session.
- The local development build reports a non-fatal Next.js dev-tools issue badge in the browser chrome; this is not application UI and is not shipped as a product component.

### 2026-08-26 — Vendor purchase-history suggestion

- **Decision:** The visibility matrix purchase-history suggestion is generated by an RLS-backed SQL aggregate over non-cancelled order lines and returns at most two categories. It is dismissible and never applies a CatalogVisibilityRule automatically.
- **Reasoning:** The suggestion should help an Administrator identify a useful restriction without converting historical buying behavior into an unreviewed access change. SQL aggregation keeps the result traceable and avoids loading order rows into application memory.

### Known gaps — Vendor visibility suggestion

- The suggestion is implemented and contract-tested, but live authenticated execution against the target Supabase project remains pending because production credentials are not configured in this session.

### 2026-08-27 — Vendor portal workflow decisions

The Vendor portal uses explicit permission-first route checks in addition to RLS: `product.view` for home/catalogue/product pages, `order.create` for cart, `order.view` for order history, `quote.view` for quote pages, `loyalty.view` for points, and `ledger.view` for balance. A dedicated `loyalty.view` permission was added so viewing points is separate from reward administration and loyalty adjustments.

Vendor checkout presents `BALANCE` and `CREDIT` as explicit payment methods and persists the selected method through migration `0010_vendor_payment_method`. This records the dealer’s intended settlement path for internal approval/recovery workflows; it does not imply an external payment gateway.

Vendor totals, order placement, quote conversion, reorder, redemption, and price-review behavior remain transaction-backed in PostgreSQL. Vendor-facing product reads continue to use `resolveVisibleProducts(customerId)` and its dedicated surface gateways. AI search/reorder/quote assistance is draft-only, validated against the current visible set, and falls back to keyword search.

### 2026-08-27 — Vendor portal known gaps

Live Supabase Auth/RLS/UAT remains required; the current verification uses the isolated local PostgreSQL database. External payment processing and WhatsApp/email delivery are not connected. The Vendor AI control is a draft assistant rather than a persistent conversation history product. Some Vendor route bundles remain above the route-level 200KB target, while shared JavaScript remains within the previously measured budget.

### 2026-08-27 — Vendor portal PDF cache and flow verification
- **Decision:** Vendor catalogue PDFs are cached per customer, active price-list, and locale for 24 hours in the private `catalogue-pdfs` bucket. The cache is keyed by customer and price-list context and never bypasses `resolveVisibleProducts(customerId)`.
- **Reasoning:** Dealers frequently forward catalogues, while customer-scoped visibility and price-list context must remain isolated. A 24-hour cache avoids regenerating the same PDF on every download without making it global or stale across price-list activations.
- **Decision:** “Share on WhatsApp” opens a user-confirmed WhatsApp share intent containing a time-limited signed PDF URL; the system does not send the message automatically.
- **Reasoning:** Dealers commonly forward catalogues, but external communication must remain an explicit human action under the AI and messaging rules.
- **Decision:** Vendor checkout supports explicit Balance and Credit choices, persists the selected payment method, and shows approval/credit notices before the Place order action.
- **Reasoning:** The dealer must understand the settlement path and any head-office approval requirement before submission.
- **Decision:** Directional Vendor back controls use logical icons with RTL rotation rather than hardcoded left/right arrow characters. Western Arabic numerals remain isolated LTR in Urdu.
- **Reasoning:** Urdu must mirror the full layout, including directional controls, without corrupting SKU, price, quantity, date, or points reading order.
### Known gaps — Vendor portal finalization
- The final English and Urdu browser captures use temporary local fixture data and local artwork; the preview route and Playwright dependency were removed after capture. Production authenticated UAT remains required against real Vendor accounts.
- The vendor PDF cache and signed share URL are implemented in the application and represented in migration `0011_vendor_pdf_cache`, but the migration has not been applied to the target Supabase project in this session.
- External WhatsApp/email delivery is not connected. WhatsApp sharing opens a user-confirmed share intent; it does not send automatically.
- The route-level Vendor catalogue bundles remain above the 200KB target in some routes; shared first-load JavaScript remains approximately 103KB.
- The final local production build required stopping a verification-only development server and using a bounded Node heap because the sandbox was memory constrained; the build then completed successfully.

### 2026-08-27 — Vendor portal PDF cache and sharing

Vendor catalogue PDFs are cached per customer, active price list, and locale for 24 hours in the private `catalogue-pdfs` bucket. The cache is keyed by customer and price-list context and is populated only from `resolveVisibleProducts(customerId)`. This avoids repeated regeneration while preserving vendor-specific visibility and price context.

“Share on WhatsApp” opens a user-confirmed share intent containing a time-limited signed PDF URL. The application does not send a message automatically. This preserves the explicit-human-action rule for external communication.

The final Vendor flow evidence uses temporary local fixture data and artwork. The temporary preview route, capture script, and Playwright dependency are removed after capture; only the English/Urdu screenshots and findings document remain under `docs/`.

### Known gaps — Vendor portal finalization

Live authenticated Supabase UAT remains required. Migration `0011_vendor_pdf_cache` is validated against the isolated local PostgreSQL database but has not yet been applied to the target Supabase project. External payment processing and WhatsApp/email provider delivery remain unconfigured. Some Vendor route bundles remain above the 200KB route target while shared first-load JavaScript remains approximately 103KB.


### 2026-08-28 — Sales portal phase

- **Decision:** Sales CRM reads use SQL views/functions under the current authenticated Supabase session, with `accessible_agent_ids` and RLS as the scope boundary. Server `requirePermission` checks run before every Sales action and route.
- **Reasoning:** Sales Agents need Today, pipeline, customer, quote, and performance workflows without making application filtering a substitute for PostgreSQL RLS.
- **Decision:** The canonical `resolve_visible_products(customerId)` resolver accepts an additional scoped `order.create` Sales path for customer-picker-first order-on-behalf. Vendor self-service still requires `customer_users` membership, and all product output remains the resolver projection.
- **Reasoning:** A Sales Agent must see exactly the selected dealer’s Vendor catalogue while acting for that dealer; a direct Product query would create a visibility bypass.
- **Decision:** Lead import is preview-first and duplicate detection runs in a scoped SQL RPC against Leads and Customers by normalized phone/name. Rollback marks the batch rolled back and deletes only rows created by that batch.
- **Reasoning:** Import mistakes must be recoverable without auto-merging real shops or loading full tables into the browser.
- **Decision:** Callback and scheduled follow-ups entered through `datetime-local` are interpreted as Asia/Karachi local time and stored as UTC. Follow-up calendar UIDs are stable per row so rescheduling updates the same ICS event.
- **Reasoning:** Karachi field operations use local business time, while the database and API store UTC timestamps.
- **Decision:** Visit coordinates are captured only after an explicit Visit action and are shown to the user before save. GPS failure leaves the Visit saveable without coordinates; there is no continuous or background tracking.
- **Reasoning:** Location is operational evidence, not a passive surveillance feature, and must not block field notes.
- **Decision:** The first route view uses the stored customer coordinate set and a lightweight coordinate plot with distance-sorted nearby results rather than adding an external map library. Google Maps hand-off can be added only after a map provider surface is approved.
- **Reasoning:** The fixed stack contains no map library and the phase requires a lightweight 3G-safe route view; no unapproved dependency or key was introduced.
- **Decision:** Calendar subscription uses a revocable SHA-256 token URL and a `CalendarProvider` abstraction. The external calendar request is authenticated by the private token because calendar providers do not send the user’s Supabase session cookie.
- **Reasoning:** This supports authenticated per-agent ICS feeds without exposing another agent’s follow-ups. Token URLs must be treated like passwords.
- **Decision:** Sales quote pricing updates quoted line snapshots in one PostgreSQL transaction, sets validity, and creates in-app vendor notifications. WhatsApp/email buttons remain explicit human-opened links; no external message is claimed as sent.
- **Reasoning:** Historical quote prices must remain stable across price-list changes, while external delivery requires configured providers and human confirmation.
- **Decision:** Sales AI “Brief me” and “Draft follow-up” query current-user RLS data, return editable drafts only, and fall back to deterministic text when Claude is unavailable.
- **Reasoning:** AI cannot become a save/send/order path and must not invent customer figures.

### Known gaps — Sales portal phase

- Migration `0012_sales_portal` and the Sales workflows are validated by deterministic contract tests and the production build, but this sandbox currently has no local PostgreSQL cluster and no configured target Supabase project for live RLS execution.
- External WhatsApp/email notification delivery is not configured. Quote pricing creates in-app notifications and exposes explicit `wa.me`/`mailto` actions; it does not send automatically.
- The route view is a lightweight coordinate plot, not a provider-backed street map or turn-by-turn route planner. Stored coordinates and the nearby SQL function are ready for a later approved map integration.
- The ICS feed is token-authenticated and read-only. There is no external calendar write-back or provider-specific two-way sync yet.
- Sales order-on-behalf currently places a transactional order with the customer-scoped visible price snapshots. A full Sales-side cart review, stock reservation, and delivery scheduling UI remains outside this phase.
- AI scoring/ranking beyond the existing persisted Lead score/reason fields is not added. The Today list uses the requested SQL longest-since-activity fallback until the later ranking phase.
- Sales route-level bundles are above the 200KB route target on the Recharts performance route; shared first-load JavaScript remains approximately 103KB. Further lazy loading is deferred to performance hardening.

## Admin portal phase — decisions log

- **2026-08-28 — Additive migration 0013.** Admin dashboard, report, impersonation, anomaly, cache, and pending-invite structures were added in `0013_admin_portal`; applied migrations 0001–0012 were not edited.
- **2026-08-28 — SQL is the aggregation boundary.** Dashboard KPIs, chart series, Sales Team metrics, receivables ageing, permission-risk review, and analytics examples run through SQL functions/views. The UI does not sum fetched order or ledger rows.
- **2026-08-28 — Five-minute dashboard cache.** Cache rows are keyed by authenticated user and Karachi date range and are read/written through current-user RLS. No global cache is shared between users.
- **2026-08-28 — Safe Auth invite boundary.** The Admin three-step user wizard stores a pending invite record, but does not create an Auth account or use the service-role key during a user request. Auth invite delivery must be completed by an approved system-job or configured Auth integration.
- **2026-08-28 — Preview and impersonation are logged sessions.** Role preview and Vendor impersonation create short-lived, audited database sessions. Order placement and password changes are not implemented through these sessions.
- **2026-08-28 — Analytics whitelist.** Natural-language analytics routes only to parameterized read-only RPCs for supported questions. Destructive words are blocked, free-form SQL is never executed, and AI answers receive only current-user RLS results.
- **2026-08-28 — Scheduled work uses the system-job boundary.** Due report queueing and deterministic anomaly generation are callable only by the service role and are exposed through a cron-secret-protected system route.

## Admin portal known gaps

- The Admin user wizard ends at a clearly labeled pending invite. It does not send a password-setting email because that operation requires an approved Auth provisioning integration or system-job path.
- Report definitions and runs are stored and queued, but CSV/XLSX/PDF artifact generation and configurable recipient delivery still require the reporting worker and storage-delivery integration.
- The Admin order and quote lists are read-only in this phase apart from the approval queue; full status-change notification workflows and print/PDF detail exports remain incomplete.
- Live RLS execution and the 50,000-order dashboard benchmark require the target Supabase project or a compatible local Postgres instance with Supabase Auth stubs. The benchmark seed is opt-in and marks all records as `BENCHMARK` and internal.
- The Admin customer screen includes row-level reassignment and export; bulk vendor-group/status operations still need their dedicated transactional actions.
- Role preview and vendor impersonation create audited session records, but the full request-context switch/banner middleware and two-way provider session are not yet wired.
- The dashboard route uses Recharts and SQL aggregates; the 12-month chart, map, and assistant are functional surfaces, but route-level lazy loading and a provider-backed street map remain future optimization work.


### 2026-09-16 — Controlled restore and Phase 11 recovery completion attempt

The restored workspace was missing `messages/ur.json`, several essential foundation files, and Git metadata. The user authorized rebuilding required files. `messages/ur.json` was generated from the exact `messages/en.json` leaf-key tree in 26 controlled translation batches using the sandbox LLM proxy. The parity check reported 916 English leaf keys, 916 Urdu leaf keys, zero missing keys, zero extra keys, and 16 intentional identical values for proper nouns/technical terms. A human review report is stored at `docs/urdu-translation-review.md`; the generated Urdu must not be treated as native-speaker approved until reviewed.

Phase 11 adds the Sales recovery route at `/[locale]/sales/recovery`, the Admin recovery route at `/[locale]/admin/recovery`, a permission-first PDF receipt route at `/api/sales/recovery/receipt`, and the additive migrations `0014_payment_recovery` and `0015_recovery_hardening`. Money remains PostgreSQL numeric and receipt/ledger operations remain transactional. Receipt counters are locked per Karachi month, deposits lock selected collections and require exact Decimal totals, and the only collection-to-balance mutation is the ledger-delta call in deposit verification for cash/online or explicit cheque clearance. Cheque bounce creates a separate reversal entry and preserves the original payment collection ledger link.

Indexes added for Phase 11 cover payment collections by agent/status/collected time, customer/status/collected time, status/collected time, method/status, cheque number, cash deposits by agent/status/deposited time, deposit status/deposited time, deposit-to-collection lookup, recovery target month/agent, reminder queue status/schedule and customer/status, credit-risk customer/computed time, collection customer/status/amount, and reminder opt-out/dispute state. These support the recovery queue, cash-in-hand, deposit verification, cheque administration, reminder job, and risk history queries.

The reminder job only queues bilingual drafts after checking customer opt-out and open-dispute flags. It does not send messages; outbound delivery belongs to the Communications phase. Recovery AI produces a traceable risk draft and editable reminder draft only; it cannot save, send, alter credit limits, or clear a collection.

Known restore gaps remain: the full previous Git history and target Supabase database are unavailable in this workspace, so live RLS/money UAT and the exact-once database transaction could not be executed. Historical Phase 8–10 files and migrations are still incomplete in the restored filesystem, so the full legacy test suite cannot pass until the repository is restored. The generated Urdu catalogue requires native review. No commit can be created until `.git` is restored.


### 2026-09-16 — Manus-local recovery verification environment

The user authorized a Manus-owned local test environment so Phase 11 could be verified without using production credentials. PostgreSQL 16 was installed in the sandbox and an isolated `akai_local` database was created with a local-only `akai_test` role. Temporary connection values live outside the repository in `/tmp/akai-manus.env`; no real Supabase secret was added to the repository or client bundle. Minimal `auth` and `storage` compatibility schemas were created only for local testing.

The local database was synchronized from the current Prisma schema and populated only with clearly labelled local fixture records: Haris Local, Daniyal Local, Admin Local, Haris Shop, and Daniyal Shop. These are not production customer or product records. Local authenticated sessions use `request.jwt.claim.sub` only inside the isolated test database. RLS policies proved Haris sees only Haris Shop, Daniyal sees only Daniyal Shop, and Admin sees both.

During real local SQL execution, schema mismatches were found and corrected through additive migrations rather than editing earlier files: `0016_recovery_summary_fix` fixes the Admin ageing aggregate, `0017_recovery_audit_fix` adapts recovery audit writes, `0018_recovery_audit_columns_fix` matches the actual audit column names, `0019_recovery_deposit_scope_fix` disambiguates the deposit agent variable, `0020_recovery_deposit_id_fix` supplies the cash-deposit UUID, and `0021_recovery_bounce_audit_fix` corrects cheque-bounce audit/notification IDs. These fixes are evidence from actual local execution and must be applied in order after `0015` on a clean target database.

The local E2E result proved: collection recording created receipt `AKAI-R-202609-0001`; balance stayed `1000.00` after recording and deposit submission; Admin verification changed it to `875.00`; exactly one `PAYMENT` ledger row existed with `-125.00`; a second verification was rejected because the deposit was no longer pending; Haris could not see or collect against Daniyal Shop; a rolled-back second collection generated `AKAI-R-202609-0002`; and cheque deposit/clear/bounce produced two balanced ledger entries (`-50.00` and `+50.00`) with final balance restored.

Known gaps: this is a local PostgreSQL/RLS-compatible verification, not the target Supabase Auth/Storage/Realtime environment. The local test sets authenticated claims directly and does not prove browser login, signed Storage upload, or hosted Supabase behavior. The full legacy suite remains blocked by missing restored historical files, and `.git` is still absent, so no commit can be created in this workspace.


### 2026-09-17 — Phase 12 Communications

Phase 12 uses `MessageLog` as the durable outbound queue. User-request paths insert `QUEUED` rows through the current-user Supabase session; only the cron-protected system-job worker claims and delivers them. The worker uses a database `FOR UPDATE SKIP LOCKED` claim function, retries at 30 seconds and five minutes, and marks the third failed attempt `FAILED`. This keeps provider latency and failure outside order, collection, and other user actions.

Email uses a Resend adapter and WhatsApp uses a Meta Cloud API adapter behind a shared provider contract. Provider credentials are environment-only. The official Meta documentation confirms that WhatsApp supports webhooks for inbound messages and outbound message statuses, and that duplicate deliveries can occur; therefore `message_webhook_events` is an append-only deduplication ledger keyed by provider and external event id. Invalid Meta signatures are rejected before payload processing. The official Resend documentation also describes at-least-once webhook delivery, but Resend delivery-event processing remains a later hardening item until a provider signing verification implementation is approved.

The communications migration is additive `0022_communications`. It adds queue metadata and indexes to `message_logs`, template approval records, campaign records, web-push subscriptions, webhook deduplication, unsubscribe preferences, and the `notification.view` permission. New query indexes are: `message_logs(status,next_attempt_at)` for due queue scans, `message_logs(status,locked_at)` for stale-lock recovery, `message_logs(thread_key,created_at)` for conversation ordering, template channel/active lookup, campaign creator/status lookup, push subscriptions by user/date, webhook events by provider/date, and unsubscribe preferences by channel.

Campaign segmentation is performed by RLS-scoped customer queries and excludes inactive/internal customers and channel-specific unsubscribe preferences before queue rows are created. Signed unsubscribe links are handled by a system endpoint because an email recipient has no Supabase session; the HMAC token is the endpoint’s authorization boundary and the endpoint can only create the matching customer/channel opt-out row. WhatsApp template approval status is stored separately from delivery status so the Admin UI can show Meta’s 24-hour customer-service-window rule explicitly.

Calls use a manual `CallProvider` abstraction and `tel:` links. A tracked call stores a short-lived session context; when the Sales Agent returns to the app, the call-log sheet appears automatically and writes an existing RLS-scoped Activity with duration. No telephony vendor is hardcoded.

Web Push uses the standards-defined `aes128gcm` encryption and VAPID signing implemented with Node’s built-in cryptography rather than adding an unapproved dependency. Resend/Svix verification is likewise implemented with the documented signed raw-body format and replay timestamp check. These choices keep the fixed stack unchanged and keep all provider credentials in environment variables.

## Phase 12 known gaps

- Resend and Meta credentials, verified sending domains, Meta template approval, webhook registration, and production callback URLs are not configured in this sandbox. Missing provider configuration is intentionally recorded as a visible queue failure rather than hidden.
- The Web Push subscription, RFC 8291 payload encryption, RFC 8292 VAPID authorization, per-subscription delivery ledger, retry path, and stale-subscription cleanup are implemented. Delivery still requires VAPID environment variables and browser subscriptions in the target environment.
- Resend/Svix signature verification and email delivery-status processing are implemented at `/api/webhooks/resend`; actual Resend webhook delivery still requires a configured public URL and webhook secret.
- Campaign recipient data is paged in 500-record batches without the previous 10,000-record action cap. VendorAccount-linked recipient users’ existing `preferredLocale` is resolved per message, with an operator-selected fallback for customers without a linked account.
- The current restored repository still lacks historical `0006`, `0009`, and vendor PDF files, has no Git metadata, and cannot provide a permanent deployment or complete legacy-suite pass until the real repository history is restored. These gaps were not fabricated or silently reconstructed in Phase 12.
- Authenticated browser UAT, real provider delivery, webhook replay/deduplication against Meta, call-return behavior on physical Android devices, and Vercel Cron execution remain deployment/staging verification work.
- Migration `0023_communications_hardening` adds the per-notification/per-subscription push delivery ledger and `customers(customer_type,status)` index for campaign segmentation. Both migrations remain additive and must be applied in order.


### 2026-09-17 — Phase 13A Shared AI engine

The shared AI engine uses a permission-first `/api/ai/chat` route and a server-only Anthropic fetch with SSE streaming. Context is assembled through the current user’s Supabase session, not a service-role client. Vendor product context is obtained only through `resolveVisibleProducts(customerId)`. The assistant receives evidence plus trace names and is instructed to refuse unsupported figures and all writes. The user and assistant messages are stored under the existing RLS-protected `AiConversation` and `AiMessage` models; usage is reconciled through database functions rather than client-provided totals.

The additive migrations `0024_ai_engine_foundation`, `0025_ai_function_hardening`, and `0026_ai_budget_defaults` reserve estimated tokens atomically in `AiUsage`, enforce a per-user per-minute rate window, release or reconcile reservations, and use Asia/Karachi for the daily usage date. Defaults are 20,000 daily tokens and 10 requests per minute. Optional Settings values are bounded inside the database functions so a caller cannot raise their own limit by passing a larger value. `0025` fixes an SQL variable/column ambiguity discovered by actual local execution; `0026` fixes the existing local `ai_usage.id` default and no-row Settings fallback discovered by the next execution. This is why both corrective migrations are retained instead of changing `0024`.

Phase 13A intentionally does not add the floating widget or role-specific Sales/Admin/Vendor assistants yet. Those belong to later Phase 13 work after the shared engine and isolation boundary are accepted. Real Anthropic provider streaming, hosted Supabase browser sessions, and production token consumption remain environment-dependent.

## Phase 13A known gaps

- The central streaming engine and route are implemented, but no Anthropic key is present in the sandbox, so provider-quality and live-stream browser UAT are not claimed.
- The Phase 13A context foundation includes permission-gated customers, leads, orders, revenue, margin, and vendor visible catalogue evidence. Specialized Sales ranking, Vendor assistant workflows, Admin analysis tools, content-generation forms, and the floating widget remain for later Phase 13 scope.
- Local isolation was verified using the `authenticated` PostgreSQL role and request claims. The sandbox does not replace hosted Supabase Auth browser UAT.
- The existing restored repository still lacks historical `0006`, `0009`, and vendor PDF files, has no Git metadata, and cannot provide a complete legacy-suite pass or commit until the real repository history is restored.


### 2026-09-17 — Phase 13B–13F AI surfaces

The floating assistant is mounted once in `PortalShell` so Admin, Sales, and Vendor receive the same permission-gated UI and streaming protocol. The shared widget uses the generic `WIDGET` surface; Admin-specific analytics evidence is added only when the current database permission set contains both `ai.analytics` and `dashboard.view`. This avoids making the common chat button unusable for an authorised `ai.chat` user who does not have analytics permission.

Sales recommendations use a transparent deterministic score rather than an opaque AI ranking: contact gap, order gap, open follow-ups, and open quotes. The score and source names are returned with every recommendation so the agent can understand why a customer was suggested. This choice avoids unsupported customer inference and keeps the assistant useful when Claude is unavailable.

Vendor catalogue search always resolves the visible product set first. Semantic Claude search may select only IDs from that returned set; a three-second timeout or invalid provider response falls back to keyword search. Content generation is a draft form and route only. A price-change announcement requires a price-list ID, and its evidence is loaded by the current user under RLS before Claude is called. The form never saves, publishes, sends, or queues the draft.

Migration `0027_ai_role_surfaces` adds indexes for the new recommendation and catalogue filters/sorts: `follow_ups(is_completed,due_at,customer_id)`, `quotes(status,created_at,customer_id)`, and `products(is_active,name_en)`. These indexes were added because the new routes filter or order on those columns.

## Phase 13B–13F known gaps

- Anthropic credentials are intentionally absent from the sandbox. The widget, semantic search, and draft form therefore cannot claim live provider-quality or latency results; each has a deterministic fallback.
- The restored workspace contains only the available Vendor route/action files; historical Vendor catalogue pages and the Vendor PDF route remain missing and were not fabricated. The new AI catalogue endpoint is complete but cannot be wired into a missing historical page without restoring that page from the real repository.
- The Admin Communications draft form is integrated. Product, category, banner, and price-list screens can consume the same draft route when their missing historical UI is restored; no direct save path was added.
- Browser UAT with authenticated hosted Supabase sessions, Urdu visual mirroring, real Claude streaming, and production RLS remain deployment/staging verification work.
- The full legacy Vitest suite still has the previously documented missing-file failures for migrations `0006`, `0009`, and the Vendor PDF route. The new Phase 13 tests pass independently.


### 2026-09-17 — Phase 14 Mobile-first PWA and offline work

Phase 14 uses native App Router manifest routes and a hand-written service worker rather than adding Workbox or another unapproved library. The service worker keeps the existing push-notification behavior, caches static assets safely, and scopes API/navigation caches by the authenticated user id sent from the browser session. Logout deletes the active user cache. This is required because a shared device must never serve one user’s cached CRM page to another user.

Offline writes use IndexedDB in the browser and are replayed through `/api/pwa/sync`. The route checks `pwa.sync` before parsing or processing the body. Database migration `0028_pwa_offline_sync` adds `offline_sync_receipts` and `process_offline_operation`; migration `0029_pwa_offline_sync_rls` adds current-user RLS policies for the invoker function. The receipt primary key is the client-generated idempotency key, and each underlying activity, collection, or Sales order RPC remains responsible for its own existing RLS, transaction, visibility, and money rules. The `pwa.sync` permission is assigned to active Sales and Vendor roles by the migration and is also included in the idempotent seed.

New query/storage indexes: `offline_sync_receipts(user_id, created_at desc)` supports current-user receipt retention/inspection and future cleanup; the IndexedDB `userId` indexes support bounded per-user queue and read-cache scans. No JavaScript aggregation was added. Money remains a string/numeric payload and is converted only inside the existing PostgreSQL numeric RPC boundary.

The mobile bottom navigation has exactly five items for Sales and Vendor, with no new desktop primary-nav item. Install prompts are shown after the second authenticated visit, not on first load, to avoid interrupting first-use workflows. The Vendor manifest and navigation are added without fabricating missing historical Vendor catalogue/cart pages.

## Phase 14 known gaps

- Hosted Supabase Auth, RLS, Storage, and browser UAT are still pending because no production environment is configured in this workspace.
- Physical Android installation, Android back behavior, service-worker update behavior, and 3G field testing remain deployment/device verification work.
- The restored workspace still lacks historical Vendor catalogue/cart/order screens and the Vendor PDF route. Vendor navigation and a Vendor manifest exist, but Vendor line-item offline ordering is not enabled until the real historical cart/order contract is restored. No replacement business screen or guessed RPC was created.
- Full legacy tests remain blocked by the previously documented missing migrations `0006`, `0009`, and the Vendor PDF route. Phase 14 focused tests are separate and pass.
- `.git` metadata is still absent, so this workspace cannot create the required descriptive commit until repository history or an explicitly authorized new Git target is restored.


- Phase 14 local migration object verification passed, but an authenticated-role replay test hit the existing compatibility database limitation `permission denied for schema auth` from `auth.uid()`. No local grant or application bypass was added; replay/idempotency must be exercised against hosted Supabase Auth/RLS during staging UAT.


Final Phase 14 evidence: production build completed; focused PWA suite passed 5/5; TypeScript, ESLint, policy check, and Prisma validation completed successfully. Full `pnpm test` reported 46 passing tests in 8 suites and 3 suite-level failures from the pre-existing missing historical `0006`, `0009`, and Vendor PDF files. The workspace still reports `NO_GIT_METADATA`, so no descriptive commit was possible without restoring or explicitly initializing repository history.


### 2026-09-17 — Phase 15 security hardening slice

Phase 15 code-side hardening uses a PostgreSQL rate-limit function with hashed bucket keys rather than storing raw IP addresses. This avoids adding a new runtime dependency and keeps the counter atomic at the database boundary. Current AI routes, offline sync, and receipt PDF generation enforce the limiter after their permission check and before request work. Zod is used for strict validation on the high-risk JSON routes touched in this slice.

Security headers include CSP, HSTS, X-Frame-Options DENY, X-Content-Type-Options nosniff, Referrer-Policy, and a restrictive Permissions-Policy. Sentry is optional and DSN-gated; all server, client, and edge configurations disable default PII and remove users, headers, cookies, and request data before events are sent.

Migration `0031_security_audit_triggers` adds one generic database trigger function and protected-domain triggers for the required business tables. Existing role/permission audit triggers are replaced by the comprehensive mutation trigger in the new migration so inserts, updates, and deletes are covered without duplicate audit rows. Migration `0032_customer_hard_delete` refuses deletion for any customer with financial, order, quote, loyalty, activity, or follow-up history; inactive status is the safe alternative.

Image upload routes are split by permission and bucket so every route begins with its permission check before parsing a multipart request. Content signatures are checked and metadata chunks are stripped before Storage upload. No image upload path uses a service-role client.

## Phase 15 known gaps

The complete preset-role RLS matrix and cost-field raw-response test still require a real hosted Supabase Auth session and the restored historical migration chain. The local compatibility database currently raises `permission denied for schema auth` when an authenticated role invokes `auth.uid()`, so no local grant or RLS bypass was added. Supabase point-in-time recovery configuration and restore testing, complete Playwright journeys, production rate-limit verification, and final device/browser UAT remain deployment work. The full legacy Vitest suite retains the already documented failures for missing historical migrations `0006`, `0009`, and the Vendor PDF route. `.git` metadata remains absent, so no descriptive commit can be created in this workspace.


### 2026-09-18 — Phase 16 deployment and handover preparation

Phase 16 is being implemented as deployment preparation and handover documentation only until the user provides or authorizes Git/Vercel/Supabase access. `OPERATIONS.md` is the Admin runbook, `docs/deployment-runbook.md` is the environment/change-control checklist, and the four bilingual user guides cover Sales Agent and Vendor first use. A safe `pnpm check:deploy` command reports readiness without reading or printing secret values. It intentionally fails closed when Git metadata, the complete historical migration chain, or the Vendor PDF route is absent.

The deployment plan requires separate staging and production Supabase projects and separate Vercel environment values. Staging must never point at production data. Production seeding is limited to the real customer workbook, real catalogue, real user accounts, and the approved first price list; benchmark seed data is never production seed data. Applied migrations remain immutable and any correction must be a new migration.

## Phase 16 known gaps

No deployment was attempted. Git metadata/remotes, Vercel project access, staging/production Supabase projects, custom domain, hosted Auth/RLS/Storage UAT, backup restore drill, production provider delivery, and production seed are unavailable in this workspace. Historical migration files `0006_versioned_price_lists`, `0009_vendor_portal_workflows`, and `app/api/vendor/catalogue-pdf/route.ts` remain missing and must be recovered from real source history; they were not fabricated. User-guide screenshots currently reference the retained local Vendor evidence and require authenticated staging screenshots before final handover. `.git` remains absent, so the required descriptive commit cannot be created here.


### 2026-09-18 — Phase 17 Trade Schemes

Trade Schemes use independent additive tables: `schemes`, `scheme_tiers`, `scheme_audiences`, and `scheme_applications`. Scope is represented by `scope_type` plus a text UUID array because a scheme can target multiple products, categories, brands, or collections without inventing a category tree. Audience matching is explicit for all vendors, vendor groups, or selected customers. New filtered/sorted columns have indexes: active schedule/priority, audience schedule, scheme tiers, audience foreign keys, applications by customer/order/scheme, and order lines by scheme application.

Free scheme goods are zero-price order lines linked to `scheme_applications`; their retail value is recorded as the benefit cost, but they do not earn loyalty points. Non-stackable schemes select the deterministic lowest-priority-number eligible scheme; stackable schemes can apply together. Budget exhaustion and per-vendor cap exhaustion skip a benefit atomically. The SQL application function uses the current user's RLS-visible catalogue resolver for the free product and does not use the service role. Vendor and Sales order wrappers preserve the existing historical price snapshot functions and apply benefits in the same transaction.

Scheme schedules are entered as `datetime-local` Asia/Karachi values and converted to UTC by `karachiLocalToUtcIso`. The database stores UTC timestamptz values. Admin scheme-copy AI is draft-only and requires a scheme ID so evidence is loaded under current-user RLS; it cannot activate or save a scheme.

## Phase 17 known gaps

- Hosted Supabase Auth/RLS acceptance is still required. The local compatibility database cannot exercise `auth.uid()` for an authenticated role, so no grant or bypass was added.
- The restored workspace is missing the historical `0006` and `0009` migrations and Vendor catalogue PDF route. The scheme wrappers call the real historical order/quote functions by name and therefore require those files/functions to be restored before staging migration and checkout UAT. They were not fabricated.
- Vendor Offers and Sales scheme panels are complete. The restored historical Vendor catalogue/cart screen is absent, so the preview API exists and checkout actions are wired to the scheme-aware RPC, but no replacement cart UI was invented.
- Phase 17 focused tests and build passed locally. Real stock decrement, free-item line insertion, exact-once application, budget exhaustion, and loyalty ledger behavior must be exercised with hosted Supabase fixtures after the historical migration chain is restored.
- No real customer, product, vendor, or scheme seed data was added. Git metadata remains absent, so no descriptive commit is possible until repository history is restored or a new Git target is explicitly authorized.


### 2026-09-18 — Phase 18 Delivery, dispatch, and POD

Phase 18 uses additive delivery tables and SQL transaction functions. COD is explicit in the Admin run payload; it is never inferred from `PaymentMethod.BALANCE` or `PaymentMethod.CREDIT`, because those are settlement paths rather than a COD flag. A tokenized driver submission creates a Phase 11 `PaymentCollection` with status `COLLECTED`; it does not mutate `Customer.currentBalancePKR` directly. Existing Admin deposit/verification functions remain the only balance-moving boundary.

Driver links contain a random raw token only in the returned URL; the database stores a SHA-256 hash, current Asia/Karachi `valid_on`, expiry, and revocation state. Driver reads and writes are token-scoped through `SECURITY DEFINER` functions with no service-role query in the request path. Admin actions still begin with `requirePermission` before parsing or database work. Driver GPS is captured only after an explicit tap.

Picking completion is the explicit transition into `OrderStatus.PICKED`; delivery-run creation refuses orders in any other status. This prevents an unpicked confirmed order from being dispatched accidentally.

Indexes added for Phase 18: picking-list status/creator and product lookups; delivery-run date/status, driver/date, and creator; delivery-stop run sequence, run/order, order/status, customer/status, and run/status/sequence; stop-line order-line; and token run/date/revocation/expiry. These support the new list filters, route ordering, stop completion, and token validation queries.

## Phase 18 known gaps

- Production Storage upload for signature/photo proof is not complete. The local code bounds data-URL proof payloads in the request and stores them in proof fields; before production, use the existing authenticated Storage upload boundary and store object paths instead.
- Hosted Supabase Auth/RLS/Storage, real driver-device UAT, barcode scanning, map-provider integration, and production COD reconciliation remain pending.
- The restored workspace still lacks historical migrations `0006`, `0009`, and the Vendor PDF route. They were not fabricated.
- `.git` metadata remains absent, so the required descriptive commit cannot be created in this workspace.


### 2026-09-18 — Phase 19 Loyalty, rewards, and freebies

Loyalty balance mutation has one database service boundary: `apply_loyalty_delta()`. A trigger rejects direct `Customer.loyalty_points_balance` updates unless that service has set its transaction-local mutation flag. The service locks the customer row, rejects negative resulting balances, writes an idempotent transaction record, and is the only path used for delivered-order earning, cancellation reversal, redemption deductions, and manual adjustments. Free trade-scheme order lines remain excluded from earning. Delivered-order earning and later cancellation reversal use deterministic idempotency keys tied to the order.

Vendor redemption requests are inserted only when the current user is linked through `customer_users` and has `redemption.request`. Admin approval and rejection require `redemption.approve`; approval requires a nominated eligible order for discount and free-product rewards, deducts points once, and inserts free items at zero price within the same transaction. Direct loyalty transaction writes were removed from RLS; reads remain customer-scope aware. Reward catalogue reads are active-date and permission scoped for Vendors, while Admin reward management remains permission scoped.

Phase 19 indexes: `loyalty_transactions(idempotency_key)` and `(redemption_id)` support exact-once and redemption history lookups; `redemptions(reward_id,status,requested_at)` and the partial pending unique index support approval queues and duplicate-request prevention; `order_lines(redemption_id)` supports reward traceability; `customers(loyalty_points_balance)` partial positive index supports liability aggregation; `orders(customer_id,status,delivered_at)` supports delivered-order reconciliation; and `products(is_active,loyalty_points_per_unit)` supports loyalty-rate selection. SQL aggregation is used for liability and popularity summaries; no dashboard sums fetched rows in JavaScript.

## Phase 19 known gaps

- Hosted Supabase Auth/RLS/Storage UAT and real Vendor/Admin redemption journeys remain pending; the local compatibility database cannot fully exercise authenticated `auth.uid()` policy behavior.
- The Admin approval form currently accepts a nominated order UUID manually. A customer/order picker should be added with the restored historical order screens rather than inventing a second order query path.
- Gift rewards are approval-recorded but do not yet have a separate fulfilment/warehouse workflow. Discount and free-product redemption paths are transactional.
- The full legacy suite still has the pre-existing missing-file failures for migrations `0006`, `0009`, and the Vendor PDF route. Those files were not fabricated. `.git` metadata remains absent, so the required descriptive commit cannot be created here.

Phase 19 final evidence: focused loyalty suite 6/6 passed; TypeScript, ESLint, policy scan, security scan, Prisma validation, production build, migration object checks, and rollback-only delivered earning/reversal smoke test completed. Full available suite: 76 tests passed, 3 pre-existing suite-level failures.


Phase 19 correction: migration `0043_loyalty_rewards` remains immutable. Migration `0044_loyalty_vendor_scope_fix` adds the canonical `vendor_accounts` fallback to loyalty/redemption RLS and resolves the vendor customer through `customer_users` or `vendor_accounts`; it also adds `vendor_accounts(user_id, customer_id)` because that composite lookup is used by redemption requests. No applied migration was edited for this correction.


Phase 19 liability decision: percentage rewards do not have a fixed PKR value without an order total. The liability summary therefore excludes percentage-only conversion and aggregates only absolute discount and free-product evidence traceable to active reward data. Migration `0045_loyalty_liability_basis_fix` records this correction; no unsupported AI or dashboard estimate is permitted.


### 2026-09-18 — Phase 20 Returns, Claims, and Warranty

Claims use the existing customer-ledger mutation boundary for credit notes and lock product stock before replacement resolution. A short-supply claim is created from a delivery-stop line only once, using the source line as the idempotency key. Claim approval is intentionally distinct from claim review: the replacement `review_claim` function checks `claim.approve` for approval and `claim.review` for review/rejection, even if the caller invokes the RPC directly.

Warranty expiry reminders and claim-SLA breach alerts are system-job operations protected by `CRON_SECRET`; they use the service-role client only inside `lib/admin/` and never in a user request. Claim analytics are SQL aggregates. Claim AI is evidence-first and draft-only: all evidence is loaded through current-user RLS or SECURITY INVOKER evidence functions, and the returned draft is never persisted automatically.

New Phase 20 indexes cover claim/customer/status queues, claim lines and photos, warranty expiry and serial lookup, replacement/credit-note linkage, and delivery-stop-line source linkage. The local compatibility database accepted migrations `0047`, `0048`, and `0049`. The initial `0046` migration is applied once in order; re-running it after the claim status notification trigger exists is not supported because its legacy enum-alter block conflicts with that trigger. No applied migration was edited after it was accepted; later corrections use new migrations.

## Phase 20 known gaps

Hosted Supabase Auth/RLS/Storage UAT, real Storage photo upload wiring, real claim/order/warranty fixtures, browser Urdu/RTL UAT, provider delivery, and full historical test restoration remain pending. The claim form currently accepts authenticated-upload URLs rather than implementing a second upload path. The restored workspace still lacks historical migrations `0006`, `0009`, and the Vendor PDF route. `.git` metadata remains absent, so no descriptive commit can be created until repository history or an explicitly authorized Git target is restored.


Phase 20 review correction: Admin queue counts and dealer-history context are SQL aggregates (`claim_sla_summary()` and `claim_review_context()`), not JavaScript sums over fetched claims. Migration `0050_claim_review_context` adds the current-user-scoped review context function. Uploaded claim photo URLs are displayed as links for the reviewer; the form does not invent a second upload implementation and continues to use the authenticated upload boundary when connected.


Phase 20 notification correction: migration `0051_bilingual_claim_notifications` adds optional `body_en`/`body_ur` fields and the Bell selects the body using the active locale. Claim status, warranty expiry, and claim-SLA notification paths now provide bilingual body content; older notifications continue to use the legacy `body` fallback.


Phase 20 decisions not specified: SLA business days exclude Saturday and Sunday but do not apply a public-holiday calendar because no holiday source was specified; the existing `settings.claim_photo_required` JSON setting controls the default damage-photo requirement, defaulting to required for `DAMAGED`; the first UI slice accepts authenticated Storage URLs rather than adding a parallel upload flow; and percentage/AI claim cost figures are not estimated when a traceable absolute ledger amount is absent.


### 2026-09-18 — Phase 21 Territory beats and field journey execution

Phase 21 uses four additive tables: `beats`, `beat_customers`, `beat_frequency_targets`, and `beat_visits`. Beat assignment is created from the Sales Agent and area-code inputs; customer assignment is materialized by SQL from the canonical `customers.assigned_agent_id` and excludes internal accounts. Customer-type and Vendor Group frequency targets are stored independently, and the visit materializer uses the most specific configured frequency evidence without recalculating money in application code.

Beat visits are date-only business records in `Asia/Karachi`; timestamps remain UTC. The daily Sales surface reads `sales_today_beat()` and `sales_beat_summary()` through RLS. Visit completion calls the existing activity RPC and is locked with `FOR UPDATE`; a completed visit cannot be completed again. Skips require a reason, and reschedules require a future Karachi business date and a reason. Location capture remains explicit and optional.

All new Beat tables have RLS. Beat reads are limited by `beat.view` and `accessible_agent_ids`; Admin mutations require `beat.manage`; Sales visit mutations require `beat.visit` and the current Agent scope. Financial balance evidence is returned by Beat SQL only when the current user holds `collection.view`, and the AI briefing uses only the resulting current-user evidence. The Beat briefing is draft-only, traceable, rate-limited, and falls back when the provider is unavailable.

Indexes added: `beats(agent_id, day_of_week, is_active)` for Agent/day planning, a GIN index on `beats.area_codes` for area filtering, `beat_customers(customer_id, beat_id)` for assignment lookups, `beat_customers(beat_id, sequence)` for route order, `beat_frequency_targets(beat_id, customer_type, vendor_group_id)` for target matching, `beat_visits(agent_id, planned_date, status)` for the Sales daily screen, `beat_visits(beat_id, planned_date, status, customer_id)` for Admin route ordering, `beat_visits(customer_id, planned_date)` for visit recency, and a unique partial activity index for one activity per visit.

## Phase 21 known gaps

Hosted Supabase Auth/RLS/Storage UAT, browser testing with real Haris/Daniyal sessions, map-provider deep-link testing, and production migration application remain pending. The current navigation uses a Google Maps directions link when coordinates exist; no paid map SDK was added. Beat creation, frequency targets, and visit execution are implemented, but a separate drag-and-drop route optimizer and public-holiday calendar were not requested and were not built. The restored workspace still lacks historical migrations `0006`, `0009`, and the Vendor PDF route, and `.git` metadata remains absent, so no descriptive commit can be created until repository history or an explicitly authorized Git target is restored.


### 2026-09-19 — Phase 22 WhatsApp ordering assistant

The WhatsApp assistant is a system-job webhook boundary: the signed Meta webhook performs event deduplication, then `lib/admin/whatsapp-assistant-system-job.ts` uses the system client only for inbound processing, queueing, and trusted transaction RPCs. It does not expose service-role credentials to a user request. Product lookup still calls the canonical `resolveVisibleProducts(customerId)` resolver, with the system client used only because Meta webhook processing is a system job. Unknown numbers are never given customer, price, order, balance, or catalogue data.

Orders require a session in `CONFIRMING` and an explicit confirmation message before `create_whatsapp_order` runs. The WhatsApp order function validates the phone/customer/assigned-agent linkage, rechecks visibility and stock inside the database transaction, snapshots current numeric prices into order lines, decrements stock, applies eligible Phase 17 schemes, and routes values above the numeric Admin ceiling to the agent. No JavaScript money arithmetic was added; prices and quantities cross into PostgreSQL numeric functions as strings/json values. The assistant never changes a customer, changes a price, cancels an order, or promises delivery.

The Admin kill switch and numeric order ceiling are permission-protected SQL boundaries. `whatsapp_sessions` has indexes on phone, customer/state, and state/expiry because webhook session lookup, staff conversation visibility, and expiry/state filtering use them. Existing signed webhook handling remains mandatory, and duplicate inbound event processing fails closed. Outside the Meta 24-hour window, assistant free-form responses are suppressed unless the approved `whatsapp_session_reopen` template exists.

### Phase 22 known gaps

Real Meta API credentials, approved template registration, production webhook registration, provider delivery, hosted Auth/RLS/Storage UAT, and real dealer fixtures are not available in the sandbox. The existing Sales full message inbox and Admin communications conversation list expose logged WhatsApp threads; a separate reply-composer screen was not added because it was not specified as a separate route and outbound sending remains the existing queued messaging boundary. The restored workspace still lacks historical migrations `0006`, `0009`, and the Vendor PDF route. `.git` metadata remains absent, so the required descriptive commit cannot be created until repository history or an explicitly authorised Git target is restored.


### 2026-09-20 — Phase 23 voice capture boundaries

- **Decision:** Voice audio is stored in a private `voice-notes` bucket with a current-user folder prefix, a 5MB limit, and an exact WebM/MP3/WAV/MP4 allowlist. Playback is always a short-lived signed URL issued only after database permission and RLS scope checks.
- **Reasoning:** Voice notes may contain private Urdu/Roman Urdu customer and field information. A public bucket, raw storage URL, or broad Storage policy would make the audio privacy boundary weaker than the CRM row boundary.
- **Decision:** Recording is hold-to-record/release-to-stop with a hard two-minute limit. Transcription and Claude extraction are asynchronous and produce draft evidence only; Activity and Claim attachment happens only after the human submits the existing form.
- **Reasoning:** Field users need a fast capture path, but AI must never create an activity, follow-up, claim, order, or customer mutation without explicit confirmation.
- **Decision:** Retention defaults to 12 months and is configurable by `settings.manage` from 1 through 120 months. Storage objects are removed before database rows are purged, and a failed object deletion leaves the database record for retry.
- **Reasoning:** The original audio is evidence and must not disappear accidentally, while retention must remain configurable for operational and privacy policy changes.
- **Decision:** Voice permissions are assigned by the Phase 23 migration only to Administrator, Sales Agent, Sales Manager, and Support Agent role names. The generic legacy Storage upload policy is replaced so voice audio has a separate exact MIME and size policy.
- **Reasoning:** Least privilege is preferable to granting voice capture/playback to every active Admin role, and the old shared policy did not express the private voice boundary.

### Known gaps — Phase 23 voice capture

- Hosted Supabase Auth/Storage RLS policy UAT, real microphone permission testing, IndexedDB Blob persistence on a physical phone, external transcription, Claude extraction, Vercel Cron, and provider failure/retry timing remain unverified until the user configures the target environment.
- The public driver-token delivery portal retains typed failure notes. Voice upload is not enabled there because the token route has no authenticated Storage identity; adding a service-role upload would violate the project security rules. An authenticated or ephemeral driver upload identity requires a future approved design.
- Voice is integrated into Sales Activity, Sales order-on-behalf notes, and Claim description drafting. The catalogue voice capture requested by the master phase is represented through the order-on-behalf catalogue surface; no separate vendor catalogue voice control was added because voice permissions are intentionally not granted to Vendor roles.
- No Git commit was created because the restored workspace still has no `.git` metadata. The Phase 23 migration was validated and rerun successfully against the isolated local fixture, not a hosted Supabase project.

- Final production build measured the shared First Load JS at 152KB, under the 200KB target, but the voice-enabled Sales Activity route at 252KB. Route-level lazy loading or recorder code splitting is still required for the strict per-screen performance target; no functionality was removed to hide this measurement.


### 2026-09-21 — Approved MongoDB/DigitalOcean migration

The user explicitly approved migrating the database from Supabase Postgres to a self-hosted MongoDB instance on DigitalOcean. Supabase Auth and Supabase Storage remain in use. The user also explicitly approved replacing PostgreSQL RLS with a documented MongoDB application authorization boundary consisting of deny-by-default repository queries, permission checks against MongoDB collections, scoped query gateways, MongoDB transactions for money/stock writes, indexes, audit logs, and cross-role leakage tests. This is a new migration phase; the original Postgres migrations remain historical reference material and are not executed by the MongoDB runtime.

The MongoDB runtime uses the official MongoDB Node driver. Prisma remains only as a compatibility generator for shared enum/Decimal imports and no longer owns domain queries or migrations. `scripts/mongodb-bootstrap.ts` creates collections and indexes idempotently, while `scripts/mongodb-seed.ts` creates only permission/role seed records and no fake customers or products. Production MongoDB must run as a replica set because transactional money and stock operations require transactions.


### Known gaps — MongoDB migration phase

- MongoDB parity is not complete. Only the core permission, activity, voice, and visible-catalogue RPC handlers have been ported in this migration slice. Unported historical PostgreSQL RPCs fail closed and require dedicated handlers/tests before production use.
- Full Vitest currently reports 136 passing tests and 1 failing test across 20 files. Three missing historical artifact failures remain documented: `0006_versioned_price_lists`, `0009_vendor_portal_workflows`, and `app/api/vendor/catalogue-pdf/route.ts`. The additional failure is the old sales migration contract expecting the former full relational Prisma schema; it must be replaced by Mongo-specific contract coverage rather than hidden.
- The MongoDB bootstrap and seed are code-complete but have not connected to a real DigitalOcean MongoDB replica set in this sandbox. No production data migration has been run.
- Self-hosted MongoDB operations remain pending: replica-set initialization, TLS/firewall configuration, backups, monitoring, restore drills, least-privilege database user, and authenticated browser UAT.
